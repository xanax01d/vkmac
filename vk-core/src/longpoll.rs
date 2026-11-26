use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use serde::de::{self, Deserializer, Visitor};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::watch;
use url::Url;

use crate::api::VkApiClient;
use crate::error::VkError;
use crate::models::{Attachment, MessageItem, VkEvent, VkEventListener};
use crate::storage::Storage;

pub const DEFAULT_LP_WAIT_SECS: u64 = 25;
pub const DEFAULT_LP_MODE: u32 = 2;
pub const DEFAULT_LP_VERSION: u32 = 3;
pub const DEFAULT_LP_TIMEOUT_SECS: u64 = 35;
pub const DEFAULT_INITIAL_BACKOFF_SECS: u64 = 1;
pub const DEFAULT_MAX_BACKOFF_SECS: u64 = 30;

#[derive(Debug, Clone)]
pub struct LongPollConfig {
    pub wait_secs: u64,
    pub mode: u32,
    pub request_timeout: Duration,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for LongPollConfig {
    fn default() -> Self {
        Self {
            wait_secs: DEFAULT_LP_WAIT_SECS,
            mode: DEFAULT_LP_MODE,
            request_timeout: Duration::from_secs(DEFAULT_LP_TIMEOUT_SECS),
            initial_backoff: Duration::from_secs(DEFAULT_INITIAL_BACKOFF_SECS),
            max_backoff: Duration::from_secs(DEFAULT_MAX_BACKOFF_SECS),
        }
    }
}

pub struct LongPollHandle {
    shutdown_tx: watch::Sender<bool>,
    connected: Arc<AtomicBool>,
    join_handle: Option<tokio::task::JoinHandle<()>>,
}

impl LongPollHandle {
    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Acquire)
    }

    pub fn signal_stop(&self) {
        let _ = self.shutdown_tx.send(true);
    }

    pub(crate) fn abort(&mut self) {
        let _ = self.shutdown_tx.send(true);
        if let Some(handle) = self.join_handle.take() {
            handle.abort();
        }
    }

    pub async fn stop(mut self) {
        let _ = self.shutdown_tx.send(true);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.await;
        }
    }
}

impl Drop for LongPollHandle {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
    }
}

pub struct LongPollWorker;

impl LongPollWorker {
    #[allow(clippy::too_many_arguments)]
    pub fn spawn(
        runtime: &tokio::runtime::Handle,
        api: Arc<VkApiClient>,
        storage: Arc<Storage>,
        http: reqwest::Client,
        token: String,
        self_user_id: i64,
        listener: Arc<RwLock<Option<Arc<dyn VkEventListener>>>>,
        config: LongPollConfig,
    ) -> LongPollHandle {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let connected = Arc::new(AtomicBool::new(false));
        let connected_clone = Arc::clone(&connected);

        let join_handle = runtime.spawn(async move {
            run_loop(
                api,
                storage,
                http,
                token,
                self_user_id,
                listener,
                config,
                connected_clone,
                shutdown_rx,
            )
            .await;
        });

        LongPollHandle {
            shutdown_tx,
            connected,
            join_handle: Some(join_handle),
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_loop(
    api: Arc<VkApiClient>,
    storage: Arc<Storage>,
    http: reqwest::Client,
    token: String,
    self_user_id: i64,
    listener: Arc<RwLock<Option<Arc<dyn VkEventListener>>>>,
    config: LongPollConfig,
    connected_flag: Arc<AtomicBool>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let mut server_state: Option<(Url, String, u64)> = None;
    let mut preserve_ts: Option<u64> = None;
    let mut last_connected: Option<bool> = None;
    let mut backoff = config.initial_backoff;
    let mut consecutive_failed: u32 = 0;

    loop {
        if *shutdown_rx.borrow() {
            break;
        }

        if server_state.is_none() {
            let server_res = tokio::select! {
                biased;
                _ = wait_shutdown(&mut shutdown_rx) => break,
                res = api.get_long_poll_server(&token) => res,
            };

            match server_res {
                Ok(info) => match normalize_server_url(&info.server) {
                    Ok(base_url) => {
                        let ts = preserve_ts.take().unwrap_or(info.ts);
                        server_state = Some((base_url, info.key, ts));
                        emit_status(
                            &listener,
                            &connected_flag,
                            &mut last_connected,
                            true,
                            &mut shutdown_rx,
                        )
                        .await;
                    }
                    Err(err) => {
                        tracing::warn!(error = %err, "Invalid Long Poll server URL");
                        emit_status(
                            &listener,
                            &connected_flag,
                            &mut last_connected,
                            false,
                            &mut shutdown_rx,
                        )
                        .await;
                        if sleep_interruptible(backoff, &mut shutdown_rx).await {
                            break;
                        }
                        backoff = next_backoff(backoff, config.max_backoff);
                        continue;
                    }
                },
                Err(VkError::InvalidToken) => {
                    tracing::warn!("Long Poll stopping due to invalid/expired access token");
                    emit_status(
                        &listener,
                        &connected_flag,
                        &mut last_connected,
                        false,
                        &mut shutdown_rx,
                    )
                    .await;
                    break;
                }
                Err(err) => {
                    tracing::warn!(error = %err, "Failed to acquire Long Poll server");
                    emit_status(
                        &listener,
                        &connected_flag,
                        &mut last_connected,
                        false,
                        &mut shutdown_rx,
                    )
                    .await;
                    if sleep_interruptible(backoff, &mut shutdown_rx).await {
                        break;
                    }
                    backoff = next_backoff(backoff, config.max_backoff);
                    continue;
                }
            }
        }

        let Some((base_url, key, ts)) = server_state.as_ref() else {
            continue;
        };
        let poll_url = build_poll_url(base_url, key, *ts, &config);

        let poll_res = tokio::select! {
            biased;
            _ = wait_shutdown(&mut shutdown_rx) => break,
            res = fetch_poll(&http, poll_url, config.request_timeout) => res,
        };

        let resp = match poll_res {
            Ok(parsed) => parsed,
            Err(err) => {
                tracing::warn!(error = %err, "Long Poll a_check request failed");
                emit_status(
                    &listener,
                    &connected_flag,
                    &mut last_connected,
                    false,
                    &mut shutdown_rx,
                )
                .await;
                if sleep_interruptible(backoff, &mut shutdown_rx).await {
                    break;
                }
                backoff = next_backoff(backoff, config.max_backoff);
                continue;
            }
        };

        if let Some(failed_code) = resp.failed {
            match failed_code {
                1 => {
                    if let Some(new_ts) = resp.ts {
                        if let Some(state) = server_state.as_mut() {
                            state.2 = new_ts;
                        }
                    } else {
                        preserve_ts = None;
                        server_state = None;
                    }
                    backoff = config.initial_backoff;
                    consecutive_failed = 0;
                    emit_status(
                        &listener,
                        &connected_flag,
                        &mut last_connected,
                        true,
                        &mut shutdown_rx,
                    )
                    .await;
                }
                2 => {
                    preserve_ts = server_state.as_ref().map(|s| s.2);
                    server_state = None;
                    consecutive_failed = consecutive_failed.saturating_add(1);
                    if consecutive_failed >= 2 {
                        emit_status(
                            &listener,
                            &connected_flag,
                            &mut last_connected,
                            false,
                            &mut shutdown_rx,
                        )
                        .await;
                        if sleep_interruptible(backoff, &mut shutdown_rx).await {
                            break;
                        }
                        backoff = next_backoff(backoff, config.max_backoff);
                    }
                }
                _ => {
                    // failed: 3, 4, or unknown code -> re-fetch fresh { server, key, ts }
                    preserve_ts = None;
                    server_state = None;
                    consecutive_failed = consecutive_failed.saturating_add(1);
                    if consecutive_failed >= 2 {
                        emit_status(
                            &listener,
                            &connected_flag,
                            &mut last_connected,
                            false,
                            &mut shutdown_rx,
                        )
                        .await;
                        if sleep_interruptible(backoff, &mut shutdown_rx).await {
                            break;
                        }
                        backoff = next_backoff(backoff, config.max_backoff);
                    }
                }
            }
            continue;
        }

        if let Some(new_ts) = resp.ts {
            if let Some(state) = server_state.as_mut() {
                state.2 = new_ts;
            }
        }
        backoff = config.initial_backoff;
        consecutive_failed = 0;
        emit_status(
            &listener,
            &connected_flag,
            &mut last_connected,
            true,
            &mut shutdown_rx,
        )
        .await;

        for raw_update in resp.updates {
            if *shutdown_rx.borrow() {
                break;
            }
            let Some(arr) = raw_update.as_array() else {
                continue;
            };
            let Some(parsed) = parse_update(arr, self_user_id) else {
                continue;
            };

            let event = match parsed {
                ParsedUpdate::NewMessage(msg) => {
                    persist_new_message(Arc::clone(&storage), msg.clone()).await;
                    VkEvent::NewMessage { message: msg }
                }
                ParsedUpdate::MessageEdited(msg) => {
                    persist_edited_message(Arc::clone(&storage), msg.clone()).await;
                    VkEvent::MessageEdited { message: msg }
                }
                ParsedUpdate::ReadIncoming { peer_id, msg_id } => {
                    persist_read_incoming(Arc::clone(&storage), peer_id).await;
                    VkEvent::ReadIncoming { peer_id, msg_id }
                }
                ParsedUpdate::ReadOutgoing { peer_id, msg_id } => {
                    VkEvent::ReadOutgoing { peer_id, msg_id }
                }
                ParsedUpdate::Typing { peer_id, user_id } => VkEvent::Typing { peer_id, user_id },
            };

            emit_event(&listener, event, &mut shutdown_rx).await;
        }
    }

    connected_flag.store(false, Ordering::Release);
}

async fn fetch_poll(
    http: &reqwest::Client,
    poll_url: Url,
    timeout: Duration,
) -> Result<RawLongPollResponse, VkError> {
    let resp = http.get(poll_url).timeout(timeout).send().await?;
    let status = resp.status();
    let body = resp.text().await?;
    if !status.is_success() {
        let snippet: String = body.chars().take(200).collect();
        return Err(VkError::Network {
            details: format!("Long Poll HTTP {status}: {snippet}"),
        });
    }
    serde_json::from_str::<RawLongPollResponse>(&body).map_err(|err| VkError::Network {
        details: format!("Invalid Long Poll JSON: {err}"),
    })
}

async fn persist_new_message(storage: Arc<Storage>, msg: MessageItem) {
    let res = tokio::task::spawn_blocking(move || -> Result<(), VkError> {
        storage.upsert_messages(std::slice::from_ref(&msg))?;
        storage.update_conversation_on_new_message(&msg)?;
        Ok(())
    })
    .await;

    match res {
        Ok(Ok(())) => {}
        Ok(Err(err)) => tracing::warn!(error = %err, "Failed to persist Long Poll NewMessage"),
        Err(err) => tracing::warn!(error = %err, "Storage spawn_blocking panicked for NewMessage"),
    }
}

async fn persist_edited_message(storage: Arc<Storage>, msg: MessageItem) {
    let res = tokio::task::spawn_blocking(move || -> Result<(), VkError> {
        storage.upsert_messages(std::slice::from_ref(&msg))
    })
    .await;

    match res {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            tracing::warn!(error = %err, "Failed to persist Long Poll MessageEdited")
        }
        Err(err) => {
            tracing::warn!(error = %err, "Storage spawn_blocking panicked for MessageEdited")
        }
    }
}

async fn persist_read_incoming(storage: Arc<Storage>, peer_id: i64) {
    let res =
        tokio::task::spawn_blocking(move || storage.mark_conversation_read(peer_id)).await;

    match res {
        Ok(Ok(())) => {}
        Ok(Err(err)) => tracing::warn!(error = %err, "Failed to persist Long Poll ReadIncoming"),
        Err(err) => {
            tracing::warn!(error = %err, "Storage spawn_blocking panicked for ReadIncoming")
        }
    }
}

async fn emit_status(
    listener_slot: &Arc<RwLock<Option<Arc<dyn VkEventListener>>>>,
    connected_flag: &Arc<AtomicBool>,
    last_connected: &mut Option<bool>,
    connected: bool,
    shutdown_rx: &mut watch::Receiver<bool>,
) {
    connected_flag.store(connected, Ordering::Release);
    if *last_connected == Some(connected) {
        return;
    }
    *last_connected = Some(connected);
    emit_event(
        listener_slot,
        VkEvent::ConnectionStatus { connected },
        shutdown_rx,
    )
    .await;
}

async fn emit_event(
    listener_slot: &Arc<RwLock<Option<Arc<dyn VkEventListener>>>>,
    event: VkEvent,
    shutdown_rx: &mut watch::Receiver<bool>,
) {
    let listener_opt = {
        let guard = listener_slot.read().unwrap_or_else(|p| p.into_inner());
        guard.clone()
    };

    if let Some(listener) = listener_opt {
        let mut task = tokio::task::spawn_blocking(move || {
            listener.on_event(event);
        });
        tokio::select! {
            biased;
            _ = wait_shutdown(shutdown_rx) => {}
            res = &mut task => {
                if let Err(err) = res {
                    tracing::warn!(error = %err, "VkEventListener::on_event task failed");
                }
            }
        }
    }
}

async fn wait_shutdown(shutdown_rx: &mut watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    while shutdown_rx.changed().await.is_ok() {
        if *shutdown_rx.borrow() {
            return;
        }
    }
}

async fn sleep_interruptible(
    duration: Duration,
    shutdown_rx: &mut watch::Receiver<bool>,
) -> bool {
    tokio::select! {
        biased;
        _ = wait_shutdown(shutdown_rx) => true,
        _ = tokio::time::sleep(duration) => false,
    }
}

fn next_backoff(current: Duration, max: Duration) -> Duration {
    if current.is_zero() {
        return Duration::from_millis(10).min(max);
    }
    current.saturating_mul(2).min(max)
}

pub fn normalize_server_url(server: &str) -> Result<Url, VkError> {
    let trimmed = server.trim();
    if trimmed.is_empty() {
        return Err(VkError::InvalidInput {
            details: "Long Poll server URL must not be empty".to_string(),
        });
    }
    let lower = trimmed.to_ascii_lowercase();
    let normalized = if lower.starts_with("http://") || lower.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    Url::parse(&normalized).map_err(|err| VkError::Network {
        details: format!("Invalid Long Poll server URL '{normalized}': {err}"),
    })
}

pub fn build_poll_url(
    base_server_url: &Url,
    key: &str,
    ts: u64,
    config: &LongPollConfig,
) -> Url {
    let mut url = base_server_url.clone();
    url.query_pairs_mut()
        .clear()
        .append_pair("act", "a_check")
        .append_pair("key", key)
        .append_pair("ts", &ts.to_string())
        .append_pair("wait", &config.wait_secs.to_string())
        .append_pair("mode", &config.mode.to_string())
        .append_pair("version", &DEFAULT_LP_VERSION.to_string());
    url
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedUpdate {
    NewMessage(MessageItem),
    MessageEdited(MessageItem),
    ReadIncoming { peer_id: i64, msg_id: i64 },
    ReadOutgoing { peer_id: i64, msg_id: i64 },
    Typing { peer_id: i64, user_id: i64 },
}

pub fn parse_update(arr: &[Value], self_user_id: i64) -> Option<ParsedUpdate> {
    let code = value_as_i64(arr.first()?)?;
    match code {
        4 | 5 => {
            if arr.len() < 5 {
                return None;
            }
            let msg_id = value_as_i64(&arr[1])?;
            let flags = value_as_i64(&arr[2])?;
            let is_out = (flags & 2) != 0;
            let peer_id = value_as_i64(&arr[3])?;
            let date = value_as_i64(&arr[4])?;
            let raw_text = arr.get(5).and_then(|v| v.as_str()).unwrap_or("");
            let text = unescape_vk_text(raw_text);

            let mut merged: HashMap<String, Value> = HashMap::new();
            for extra in arr.get(6..).unwrap_or(&[]) {
                if let Some(obj) = extra.as_object() {
                    for (k, v) in obj {
                        merged.insert(k.clone(), v.clone());
                    }
                }
            }

            let from_id = merged.get("from").and_then(value_as_i64).unwrap_or({
                if is_out && self_user_id > 0 {
                    self_user_id
                } else if peer_id < 2_000_000_000 {
                    peer_id
                } else {
                    0
                }
            });

            let attachments = parse_lp_attachments(&merged);
            let item = MessageItem {
                id: msg_id,
                peer_id,
                from_id,
                text,
                date,
                is_out,
                attachments,
            };
            if code == 4 {
                Some(ParsedUpdate::NewMessage(item))
            } else {
                Some(ParsedUpdate::MessageEdited(item))
            }
        }
        6 => {
            if arr.len() < 3 {
                return None;
            }
            let peer_id = value_as_i64(&arr[1])?;
            let msg_id = value_as_i64(&arr[2])?;
            Some(ParsedUpdate::ReadIncoming { peer_id, msg_id })
        }
        7 => {
            if arr.len() < 3 {
                return None;
            }
            let peer_id = value_as_i64(&arr[1])?;
            let msg_id = value_as_i64(&arr[2])?;
            Some(ParsedUpdate::ReadOutgoing { peer_id, msg_id })
        }
        61 => {
            if arr.len() < 2 {
                return None;
            }
            let user_id = value_as_i64(&arr[1])?;
            Some(ParsedUpdate::Typing {
                peer_id: user_id,
                user_id,
            })
        }
        62 => {
            if arr.len() < 3 {
                return None;
            }
            let user_id = value_as_i64(&arr[1])?;
            let chat_id = value_as_i64(&arr[2])?;
            let peer_id = if chat_id >= 2_000_000_000 {
                chat_id
            } else {
                2_000_000_000_i64.saturating_add(chat_id)
            };
            Some(ParsedUpdate::Typing { peer_id, user_id })
        }
        _ => None,
    }
}

fn parse_lp_attachments(map: &HashMap<String, Value>) -> Vec<Attachment> {
    let mut attachments = Vec::new();
    for idx in 1..=20 {
        let type_key = format!("attach{idx}_type");
        let Some(kind_raw) = map.get(&type_key).and_then(|v| v.as_str()) else {
            continue;
        };
        let kind = kind_raw.trim().to_ascii_lowercase();
        if kind.is_empty() {
            continue;
        }

        let opt_str = |suffix: &str| -> Option<String> {
            let key = format!("attach{idx}_{suffix}");
            map.get(&key)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        };
        let opt_u32 = |suffix: &str| -> Option<u32> {
            let key = format!("attach{idx}_{suffix}");
            map.get(&key)
                .and_then(value_as_i64)
                .and_then(|n| u32::try_from(n).ok())
        };

        let att = match kind.as_str() {
            "photo" => Attachment::Photo {
                url: opt_str("url").unwrap_or_default(),
                width: opt_u32("width"),
                height: opt_u32("height"),
            },
            "audio" => Attachment::Audio {
                artist: opt_str("artist").unwrap_or_default(),
                title: opt_str("title").unwrap_or_else(|| "Audio".to_string()),
                duration_sec: opt_u32("duration").unwrap_or(0),
                url: opt_str("url"),
            },
            "doc" => Attachment::Document {
                title: opt_str("title").unwrap_or_else(|| "Document".to_string()),
                url: opt_str("url").unwrap_or_default(),
                ext: opt_str("ext").unwrap_or_default(),
            },
            "sticker" => {
                let raw_id = map
                    .get(&format!("attach{idx}"))
                    .and_then(|v| match v {
                        Value::String(s) => Some(s.trim().to_string()),
                        Value::Number(n) => Some(n.to_string()),
                        _ => None,
                    })
                    .filter(|s| !s.is_empty());
                let url = opt_str("url").unwrap_or_else(|| match raw_id {
                    Some(id) if id.chars().all(|c| c.is_ascii_digit()) => {
                        format!("https://vk.com/sticker/1-{id}-128")
                    }
                    _ => String::new(),
                });
                Attachment::Sticker { url }
            }
            "link" => Attachment::Link {
                title: opt_str("title").unwrap_or_else(|| "Link".to_string()),
                url: opt_str("url").unwrap_or_default(),
            },
            "audiomsg" | "audio_message" => Attachment::AudioMessage {
                url: opt_str("url")
                    .or_else(|| opt_str("link_mp3"))
                    .or_else(|| opt_str("link_ogg"))
                    .unwrap_or_default(),
                duration_sec: opt_u32("duration").unwrap_or(0),
                transcript: opt_str("transcript"),
            },
            _ => Attachment::Unknown { kind },
        };
        attachments.push(att);
    }
    attachments
}

fn unescape_vk_text(raw: &str) -> String {
    raw.replace("<br />", "\n")
        .replace("<br/>", "\n")
        .replace("<br>", "\n")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

fn value_as_i64(val: &Value) -> Option<i64> {
    match val {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

#[derive(Debug, Deserialize)]
struct RawLongPollResponse {
    #[serde(default, deserialize_with = "deserialize_opt_u64_from_int_or_str")]
    ts: Option<u64>,
    #[serde(default)]
    updates: Vec<Value>,
    failed: Option<u32>,
}

fn deserialize_opt_u64_from_int_or_str<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    struct OptU64Visitor;

    impl<'de> Visitor<'de> for OptU64Visitor {
        type Value = Option<u64>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("null, an unsigned integer, or a numeric string")
        }

        fn visit_none<E: de::Error>(self) -> Result<Option<u64>, E> {
            Ok(None)
        }

        fn visit_unit<E: de::Error>(self) -> Result<Option<u64>, E> {
            Ok(None)
        }

        fn visit_u64<E: de::Error>(self, v: u64) -> Result<Option<u64>, E> {
            Ok(Some(v))
        }

        fn visit_i64<E: de::Error>(self, v: i64) -> Result<Option<u64>, E> {
            u64::try_from(v)
                .map(Some)
                .map_err(|_| E::custom(format!("negative integer for ts: {v}")))
        }

        fn visit_str<E: de::Error>(self, v: &str) -> Result<Option<u64>, E> {
            let trimmed = v.trim();
            if trimmed.is_empty() {
                return Ok(None);
            }
            trimmed
                .parse::<u64>()
                .map(Some)
                .map_err(|err| E::custom(format!("invalid ts string '{v}': {err}")))
        }
    }

    deserializer.deserialize_any(OptU64Visitor)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex as StdMutex;
    use std::time::Instant;

    use serde_json::json;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::sync::Notify;

    use super::*;
    use crate::models::ConversationItem;

    struct EventCollector {
        events: StdMutex<Vec<VkEvent>>,
        notify: Notify,
    }

    impl EventCollector {
        fn new() -> Self {
            Self {
                events: StdMutex::new(Vec::new()),
                notify: Notify::new(),
            }
        }

        fn snapshot(&self) -> Vec<VkEvent> {
            self.events.lock().unwrap().clone()
        }

        async fn wait_for<F>(&self, timeout: Duration, mut pred: F) -> bool
        where
            F: FnMut(&[VkEvent]) -> bool,
        {
            let deadline = tokio::time::Instant::now() + timeout;
            loop {
                {
                    let guard = self.events.lock().unwrap();
                    if pred(&guard) {
                        return true;
                    }
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return false;
                }
                let _ = tokio::time::timeout(remaining, self.notify.notified()).await;
            }
        }
    }

    impl VkEventListener for EventCollector {
        fn on_event(&self, event: VkEvent) {
            self.events.lock().unwrap().push(event);
            self.notify.notify_waiters();
        }
    }

    enum MockLpReply {
        Immediate(u16, String),
        HoldUntilDropped(Duration),
    }

    struct MockLpServer {
        api_base_url: String,
        lp_url: String,
        api_queue: Arc<tokio::sync::Mutex<VecDeque<(u16, String)>>>,
        lp_queue: Arc<tokio::sync::Mutex<VecDeque<MockLpReply>>>,
        lp_queries: Arc<tokio::sync::Mutex<Vec<String>>>,
        handle: tokio::task::JoinHandle<()>,
    }

    impl Drop for MockLpServer {
        fn drop(&mut self) {
            self.handle.abort();
        }
    }

    impl MockLpServer {
        async fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let api_base_url = format!("http://127.0.0.1:{port}/method/");
            let lp_url = format!("http://127.0.0.1:{port}/lp");

            let api_queue = Arc::new(tokio::sync::Mutex::new(VecDeque::new()));
            let lp_queue = Arc::new(tokio::sync::Mutex::new(VecDeque::new()));
            let lp_queries = Arc::new(tokio::sync::Mutex::new(Vec::new()));

            let api_q = Arc::clone(&api_queue);
            let lp_q = Arc::clone(&lp_queue);
            let lp_queries_ref = Arc::clone(&lp_queries);

            let handle = tokio::spawn(async move {
                loop {
                    let Ok((mut socket, _)) = listener.accept().await else {
                        break;
                    };
                    let api_q = Arc::clone(&api_q);
                    let lp_q = Arc::clone(&lp_q);
                    let lp_queries_ref = Arc::clone(&lp_queries_ref);

                    tokio::spawn(async move {
                        let mut buf = Vec::new();
                        let mut tmp = [0u8; 4096];
                        let header_end = loop {
                            let n = match socket.read(&mut tmp).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => n,
                            };
                            buf.extend_from_slice(&tmp[..n]);
                            if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                                break pos + 4;
                            }
                        };

                        let headers_str = String::from_utf8_lossy(&buf[..header_end]).into_owned();
                        let req_line = headers_str.lines().next().unwrap_or("");
                        let target = req_line.split_whitespace().nth(1).unwrap_or("/");
                        let (path, query) = target.split_once('?').unwrap_or((target, ""));

                        let content_length = headers_str
                            .lines()
                            .find_map(|line| {
                                let (name, val) = line.split_once(':')?;
                                if name.trim().eq_ignore_ascii_case("content-length") {
                                    val.trim().parse::<usize>().ok()
                                } else {
                                    None
                                }
                            })
                            .unwrap_or(0);

                        while buf.len() < header_end + content_length {
                            let n = match socket.read(&mut tmp).await {
                                Ok(0) | Err(_) => break,
                                Ok(n) => n,
                            };
                            buf.extend_from_slice(&tmp[..n]);
                        }

                        let (status, body) = if path.starts_with("/method/") {
                            api_q
                                .lock()
                                .await
                                .pop_front()
                                .unwrap_or((500, "{}".to_string()))
                        } else if path == "/lp" {
                            lp_queries_ref.lock().await.push(query.to_string());
                            let next = lp_q.lock().await.pop_front();
                            match next {
                                Some(MockLpReply::Immediate(s, b)) => (s, b),
                                Some(MockLpReply::HoldUntilDropped(d)) => {
                                    tokio::time::sleep(d).await;
                                    (200, r#"{"ts":999,"updates":[]}"#.to_string())
                                }
                                None => {
                                    tokio::time::sleep(Duration::from_secs(30)).await;
                                    (200, r#"{"ts":999,"updates":[]}"#.to_string())
                                }
                            }
                        } else {
                            (404, "not found".to_string())
                        };

                        let raw_http = format!(
                            "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = socket.write_all(raw_http.as_bytes()).await;
                        let _ = socket.shutdown().await;
                    });
                }
            });

            Self {
                api_base_url,
                lp_url,
                api_queue,
                lp_queue,
                lp_queries,
                handle,
            }
        }
    }

    #[test]
    fn test_normalize_server_url_preserves_http_and_https_adds_https_when_missing() {
        assert_eq!(
            normalize_server_url("im.vk.com/nim123").unwrap().as_str(),
            "https://im.vk.com/nim123"
        );
        assert_eq!(
            normalize_server_url("http://127.0.0.1:8080/lp")
                .unwrap()
                .as_str(),
            "http://127.0.0.1:8080/lp"
        );
        assert_eq!(
            normalize_server_url("https://im.vk.com/nim456")
                .unwrap()
                .as_str(),
            "https://im.vk.com/nim456"
        );
        assert!(matches!(
            normalize_server_url("   ").unwrap_err(),
            VkError::InvalidInput { .. }
        ));
    }

    #[test]
    fn test_parse_updates_new_message_dm_and_group_chat_with_attachments_and_html_unescape() {
        // DM incoming with HTML entities and combined arr[6]
        let dm_arr = json!([
            4,
            1001,
            1,
            555,
            1700000100,
            "Hello &lt;world&gt;!<br>Line 2 &amp; &quot;quoted&quot; &#39;ok&#39;",
            {
                "attach1_type": "photo",
                "attach1_url": "https://cdn/p.jpg",
                "attach1_width": "800",
                "attach1_height": "600",
                "attach2_type": "audio",
                "attach2_artist": "Band",
                "attach2_title": "Song",
                "attach2_duration": 180,
                "attach2_url": "https://cdn/a.m3u8"
            }
        ]);
        let parsed_dm = parse_update(dm_arr.as_array().unwrap(), 42).unwrap();
        assert_eq!(
            parsed_dm,
            ParsedUpdate::NewMessage(MessageItem {
                id: 1001,
                peer_id: 555,
                from_id: 555,
                text: "Hello <world>!\nLine 2 & \"quoted\" 'ok'".to_string(),
                date: 1700000100,
                is_out: false,
                attachments: vec![
                    Attachment::Photo {
                        url: "https://cdn/p.jpg".to_string(),
                        width: Some(800),
                        height: Some(600),
                    },
                    Attachment::Audio {
                        artist: "Band".to_string(),
                        title: "Song".to_string(),
                        duration_sec: 180,
                        url: Some("https://cdn/a.m3u8".to_string()),
                    },
                ],
            })
        );

        // Outgoing group chat with split arr[6] ("from") and arr[7] (attachments)
        let group_arr = json!([
            4,
            1002,
            2,
            2000000009_i64,
            1700000200,
            "",
            {"from": "42"},
            {
                "attach1_type": "doc",
                "attach1_title": "notes.txt",
                "attach1_url": "https://cdn/notes.txt",
                "attach1_ext": "txt",
                "attach2_type": "sticker",
                "attach2": "900",
                "attach3_type": "link",
                "attach3_title": "Docs",
                "attach3_url": "https://example.com",
                "attach4_type": "poll"
            }
        ]);
        let parsed_group = parse_update(group_arr.as_array().unwrap(), 42).unwrap();
        assert_eq!(
            parsed_group,
            ParsedUpdate::NewMessage(MessageItem {
                id: 1002,
                peer_id: 2000000009,
                from_id: 42,
                text: String::new(),
                date: 1700000200,
                is_out: true,
                attachments: vec![
                    Attachment::Document {
                        title: "notes.txt".to_string(),
                        url: "https://cdn/notes.txt".to_string(),
                        ext: "txt".to_string(),
                    },
                    Attachment::Sticker {
                        url: "https://vk.com/sticker/1-900-128".to_string(),
                    },
                    Attachment::Link {
                        title: "Docs".to_string(),
                        url: "https://example.com".to_string(),
                    },
                    Attachment::Unknown {
                        kind: "poll".to_string(),
                    },
                ],
            })
        );
    }

    #[test]
    fn test_parse_updates_edited_read_and_typing_events() {
        let edited = json!([5, 1003, 2, 777, 1700000300, "Edited"]);
        assert_eq!(
            parse_update(edited.as_array().unwrap(), 42),
            Some(ParsedUpdate::MessageEdited(MessageItem {
                id: 1003,
                peer_id: 777,
                from_id: 42,
                text: "Edited".to_string(),
                date: 1700000300,
                is_out: true,
                attachments: vec![],
            }))
        );

        let read_in = json!([6, 777, 1003]);
        assert_eq!(
            parse_update(read_in.as_array().unwrap(), 42),
            Some(ParsedUpdate::ReadIncoming {
                peer_id: 777,
                msg_id: 1003
            })
        );

        let read_out = json!([7, 777, 1004]);
        assert_eq!(
            parse_update(read_out.as_array().unwrap(), 42),
            Some(ParsedUpdate::ReadOutgoing {
                peer_id: 777,
                msg_id: 1004
            })
        );

        let typing_dm = json!([61, 888, 1]);
        assert_eq!(
            parse_update(typing_dm.as_array().unwrap(), 42),
            Some(ParsedUpdate::Typing {
                peer_id: 888,
                user_id: 888
            })
        );

        let typing_chat = json!([62, 888, 15]);
        assert_eq!(
            parse_update(typing_chat.as_array().unwrap(), 42),
            Some(ParsedUpdate::Typing {
                peer_id: 2000000015,
                user_id: 888
            })
        );

        let ignored = json!([80, 3, 0]);
        assert_eq!(parse_update(ignored.as_array().unwrap(), 42), None);
    }

    #[tokio::test]
    async fn test_longpoll_worker_lifecycle_failed_codes_and_sqlite_persistence() {
        let server = MockLpServer::start().await;
        let storage = Arc::new(Storage::in_memory().unwrap());
        storage
            .upsert_conversations(&[ConversationItem {
                peer_id: 555,
                title: "Alice".to_string(),
                avatar_url: None,
                last_message_text: "old".to_string(),
                last_message_date: 100,
                unread_count: 0,
                is_muted: false,
            }])
            .unwrap();

        {
            let mut aq = server.api_queue.lock().await;
            // Initial getLongPollServer
            aq.push_back((
                200,
                json!({"response": {"key": "k1", "server": server.lp_url, "ts": 100}}).to_string(),
            ));
            // Re-fetch after failed: 2
            aq.push_back((
                200,
                json!({"response": {"key": "k2", "server": server.lp_url, "ts": 999}}).to_string(),
            ));
            // Re-fetch after failed: 3
            aq.push_back((
                200,
                json!({"response": {"key": "k3", "server": server.lp_url, "ts": 500}}).to_string(),
            ));
        }

        {
            let mut lq = server.lp_queue.lock().await;
            // 1) failed: 1 -> updates ts to 105
            lq.push_back(MockLpReply::Immediate(
                200,
                json!({"failed": 1, "ts": 105}).to_string(),
            ));
            // 2) failed: 2 -> re-fetches key k2, preserves ts=105
            lq.push_back(MockLpReply::Immediate(
                200,
                json!({"failed": 2}).to_string(),
            ));
            // 3) failed: 3 -> re-fetches key k3 AND resets ts to 500
            lq.push_back(MockLpReply::Immediate(
                200,
                json!({"failed": 3}).to_string(),
            ));
            // 4) Normal update batch: NewMessage + ReadIncoming
            lq.push_back(MockLpReply::Immediate(
                200,
                json!({
                    "ts": 501,
                    "updates": [
                        [4, 7001, 1, 555, 200, "Live LP message", {"from": 555}],
                        [6, 555, 7001]
                    ]
                })
                .to_string(),
            ));
            // 5) Hold until stop
            lq.push_back(MockLpReply::HoldUntilDropped(Duration::from_secs(30)));
        }

        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let api = Arc::new(VkApiClient::with_client(http.clone(), &server.api_base_url));
        let collector = Arc::new(EventCollector::new());
        let listener_slot: Arc<RwLock<Option<Arc<dyn VkEventListener>>>> =
            Arc::new(RwLock::new(Some(collector.clone())));

        let cfg = LongPollConfig {
            wait_secs: 25,
            mode: 2,
            request_timeout: Duration::from_secs(5),
            initial_backoff: Duration::from_millis(10),
            max_backoff: Duration::from_millis(40),
        };

        let lp_handle = LongPollWorker::spawn(
            &tokio::runtime::Handle::current(),
            api,
            Arc::clone(&storage),
            http,
            "tok_lp".to_string(),
            42,
            listener_slot,
            cfg,
        );

        let received = collector
            .wait_for(Duration::from_secs(5), |events| {
                events
                    .iter()
                    .any(|e| matches!(e, VkEvent::ReadIncoming { peer_id: 555, .. }))
            })
            .await;
        assert!(received, "Timed out waiting for Long Poll events");
        assert!(lp_handle.is_connected());

        lp_handle.stop().await;

        let events = collector.snapshot();
        assert_eq!(events[0], VkEvent::ConnectionStatus { connected: true });
        assert!(events.iter().any(|e| matches!(
            e,
            VkEvent::NewMessage { message } if message.id == 7001 && message.text == "Live LP message"
        )));
        assert!(events
            .iter()
            .any(|e| matches!(e, VkEvent::ReadIncoming { peer_id: 555, msg_id: 7001 })));

        let queries = server.lp_queries.lock().await.clone();
        assert!(queries[0].contains("key=k1") && queries[0].contains("ts=100"));
        assert!(queries[1].contains("key=k1") && queries[1].contains("ts=105"));
        assert!(queries[2].contains("key=k2") && queries[2].contains("ts=105"));
        assert!(queries[3].contains("key=k3") && queries[3].contains("ts=500"));

        let cached_msgs = storage.get_messages(555, 0, 10).unwrap();
        assert_eq!(cached_msgs.len(), 1);
        assert_eq!(cached_msgs[0].id, 7001);

        let cached_convs = storage.get_conversations(0, 10).unwrap();
        assert_eq!(cached_convs[0].last_message_text, "Live LP message");
        assert_eq!(cached_convs[0].unread_count, 0);
    }

    #[tokio::test]
    async fn test_longpoll_worker_backoff_deduplicated_status_and_fast_shutdown() {
        let server = MockLpServer::start().await;
        let storage = Arc::new(Storage::in_memory().unwrap());

        {
            let mut aq = server.api_queue.lock().await;
            // First two getLongPollServer attempts fail with 502 -> tests backoff & deduplicated false
            aq.push_back((502, "bad gateway".to_string()));
            aq.push_back((502, "bad gateway".to_string()));
            aq.push_back((
                200,
                json!({"response": {"key": "k_ok", "server": server.lp_url, "ts": 1}}).to_string(),
            ));
        }
        {
            let mut lq = server.lp_queue.lock().await;
            lq.push_back(MockLpReply::HoldUntilDropped(Duration::from_secs(25)));
        }

        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let api = Arc::new(VkApiClient::with_client(http.clone(), &server.api_base_url));
        let collector = Arc::new(EventCollector::new());
        let listener_slot: Arc<RwLock<Option<Arc<dyn VkEventListener>>>> =
            Arc::new(RwLock::new(Some(collector.clone())));

        let cfg = LongPollConfig {
            wait_secs: 25,
            mode: 2,
            request_timeout: Duration::from_secs(35),
            initial_backoff: Duration::from_millis(20),
            max_backoff: Duration::from_millis(80),
        };

        let lp_handle = LongPollWorker::spawn(
            &tokio::runtime::Handle::current(),
            api,
            storage,
            http,
            "tok".to_string(),
            42,
            listener_slot,
            cfg,
        );

        let ok = collector
            .wait_for(Duration::from_secs(5), |events| {
                events.contains(&VkEvent::ConnectionStatus { connected: true })
            })
            .await;
        assert!(ok, "Expected ConnectionStatus {{ connected: true }}");

        let events = collector.snapshot();
        assert_eq!(
            events,
            vec![
                VkEvent::ConnectionStatus { connected: false },
                VkEvent::ConnectionStatus { connected: true },
            ]
        );

        // Verify stop() cancels an active 25s poll in <200ms
        let t0 = Instant::now();
        lp_handle.stop().await;
        assert!(
            t0.elapsed() < Duration::from_millis(250),
            "LongPollHandle::stop took too long: {:?}",
            t0.elapsed()
        );
    }

    #[tokio::test]
    async fn test_longpoll_worker_stops_on_invalid_token() {
        let server = MockLpServer::start().await;
        let storage = Arc::new(Storage::in_memory().unwrap());

        server.api_queue.lock().await.push_back((
            200,
            json!({"error": {"error_code": 5, "error_msg": "Invalid token"}}).to_string(),
        ));

        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let api = Arc::new(VkApiClient::with_client(http.clone(), &server.api_base_url));
        let collector = Arc::new(EventCollector::new());
        let listener_slot: Arc<RwLock<Option<Arc<dyn VkEventListener>>>> =
            Arc::new(RwLock::new(Some(collector.clone())));

        let lp_handle = LongPollWorker::spawn(
            &tokio::runtime::Handle::current(),
            api,
            storage,
            http,
            "expired".to_string(),
            42,
            listener_slot,
            LongPollConfig::default(),
        );

        let saw_disconnected = collector
            .wait_for(Duration::from_secs(2), |events| {
                events.contains(&VkEvent::ConnectionStatus { connected: false })
            })
            .await;
        assert!(saw_disconnected);
        assert!(!lp_handle.is_connected());
        lp_handle.stop().await;
    }
}
