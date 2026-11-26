use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use serde_json::json;
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{Mutex as AsyncMutex, Notify};
use url::form_urlencoded;

use vk_core::config::OAUTH_CONFIG_FILENAME;
use vk_core::error::VkError;
use vk_core::keychain::{InMemoryTokenStore, TokenStore};
use vk_core::longpoll::LongPollConfig;
use vk_core::models::{AuthState, VkEvent, VkEventListener};
use vk_core::storage::Storage;
use vk_core::VkClient;

#[derive(Debug, Clone)]
struct CapturedRequest {
    path: String,
    params: BTreeMap<String, String>,
}

enum MockReply {
    Immediate(u16, String),
    Hold(Duration, String),
}

struct MockVkServer {
    api_base_url: String,
    token_url: String,
    authorize_url: String,
    lp_url: String,
    token_queue: Arc<AsyncMutex<VecDeque<(u16, String)>>>,
    method_queue: Arc<AsyncMutex<VecDeque<(u16, String)>>>,
    lp_queue: Arc<AsyncMutex<VecDeque<MockReply>>>,
    requests: Arc<AsyncMutex<Vec<CapturedRequest>>>,
    handle: tokio::task::JoinHandle<()>,
}

impl Drop for MockVkServer {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

impl MockVkServer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");

        let token_queue = Arc::new(AsyncMutex::new(VecDeque::new()));
        let method_queue = Arc::new(AsyncMutex::new(VecDeque::new()));
        let lp_queue = Arc::new(AsyncMutex::new(VecDeque::new()));
        let requests = Arc::new(AsyncMutex::new(Vec::new()));

        let tq = Arc::clone(&token_queue);
        let mq = Arc::clone(&method_queue);
        let lq = Arc::clone(&lp_queue);
        let reqs = Arc::clone(&requests);

        let handle = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let tq = Arc::clone(&tq);
                let mq = Arc::clone(&mq);
                let lq = Arc::clone(&lq);
                let reqs = Arc::clone(&reqs);

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

                    let body = &buf[header_end..(header_end + content_length).min(buf.len())];
                    let mut params = BTreeMap::new();
                    for (k, v) in form_urlencoded::parse(query.as_bytes()) {
                        params.insert(k.into_owned(), v.into_owned());
                    }
                    for (k, v) in form_urlencoded::parse(body) {
                        params.insert(k.into_owned(), v.into_owned());
                    }

                    reqs.lock().await.push(CapturedRequest {
                        path: path.to_string(),
                        params,
                    });

                    let (status, resp_body) = if path == "/token" {
                        tq.lock()
                            .await
                            .pop_front()
                            .unwrap_or((500, r#"{"error":"unexpected_token_call"}"#.to_string()))
                    } else if path.starts_with("/method/") {
                        mq.lock()
                            .await
                            .pop_front()
                            .unwrap_or((500, r#"{"error":{"error_code":500,"error_msg":"unexpected_method_call"}}"#.to_string()))
                    } else if path == "/lp" {
                        let reply = lq.lock().await.pop_front();
                        match reply {
                            Some(MockReply::Immediate(s, b)) => (s, b),
                            Some(MockReply::Hold(dur, b)) => {
                                tokio::time::sleep(dur).await;
                                (200, b)
                            }
                            None => {
                                tokio::time::sleep(Duration::from_secs(30)).await;
                                (200, r#"{"ts":999,"updates":[]}"#.to_string())
                            }
                        }
                    } else {
                        (404, "not found".to_string())
                    };

                    let reason = match status {
                        200 => "OK",
                        401 => "Unauthorized",
                        _ => "Error",
                    };
                    let raw_http = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resp_body}",
                        resp_body.len()
                    );
                    let _ = socket.write_all(raw_http.as_bytes()).await;
                    let _ = socket.shutdown().await;
                });
            }
        });

        Self {
            api_base_url: format!("{base}/method/"),
            token_url: format!("{base}/token"),
            authorize_url: format!("{base}/authorize"),
            lp_url: format!("{base}/lp"),
            token_queue,
            method_queue,
            lp_queue,
            requests,
            handle,
        }
    }

    async fn requests(&self) -> Vec<CapturedRequest> {
        self.requests.lock().await.clone()
    }
}

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

fn make_client(dir: &TempDir, store: Arc<dyn TokenStore>, server: &MockVkServer) -> Arc<VkClient> {
    let lp_cfg = LongPollConfig {
        wait_secs: 25,
        mode: 2,
        request_timeout: Duration::from_secs(5),
        initial_backoff: Duration::from_millis(15),
        max_backoff: Duration::from_millis(60),
    };
    VkClient::new_with_deps_and_longpoll_config(
        dir.path(),
        store,
        &server.api_base_url,
        &server.token_url,
        &server.authorize_url,
        lp_cfg,
    )
    .unwrap()
}

#[tokio::test]
async fn test_vk_client_runtime_lifecycle_and_drop_safety() {
    let dir1 = TempDir::new().unwrap();
    let dir2 = TempDir::new().unwrap();
    let server = MockVkServer::start().await;

    // 1. Construct and drop inside #[tokio::test] (async context)
    let client_async = make_client(&dir1, Arc::new(InMemoryTokenStore::new()), &server);
    assert_eq!(client_async.restore_session().await, AuthState::LoggedOut);
    drop(client_async);

    // 2. Construct on a sync std::thread (no Tokio runtime, simulating Swift main thread),
    // send Arc<VkClient> into async runtime, use it, and drop inside tokio::spawn!
    let dir2_path = dir2.path().to_path_buf();
    let api_url = server.api_base_url.clone();
    let token_url = server.token_url.clone();
    let auth_url = server.authorize_url.clone();

    let client_from_sync = std::thread::spawn(move || {
        VkClient::new_with_deps(
            &dir2_path,
            Arc::new(InMemoryTokenStore::new()),
            api_url,
            token_url,
            auth_url,
        )
        .unwrap()
    })
    .join()
    .unwrap();

    let join = tokio::spawn(async move {
        let state = client_from_sync.restore_session().await;
        assert_eq!(state, AuthState::LoggedOut);
        drop(client_from_sync); // Must not panic even when dropping owned_runtime inside Tokio!
    });
    join.await.unwrap();
}

#[tokio::test]
async fn test_vk_client_password_2fa_restore_and_logout_lifecycle() {
    let dir = TempDir::new().unwrap();
    let store = Arc::new(InMemoryTokenStore::new());
    let server = MockVkServer::start().await;

    server.token_queue.lock().await.push_back((
        401,
        json!({
            "error": "need_validation",
            "validation_type": "2fa_sms",
            "phone_mask": "+7 *** *** ** 42",
            "validation_sid": "v_sid_1"
        })
        .to_string(),
    ));
    server.token_queue.lock().await.push_back((
        200,
        json!({
            "access_token": "tok_2fa_ok",
            "expires_in": 0,
            "user_id": 777
        })
        .to_string(),
    ));
    server.method_queue.lock().await.push_back((
        200,
        json!({
            "response": [{
                "id": 777,
                "first_name": "Pavel",
                "last_name": "Durov",
                "photo_200": "https://cdn/durov.jpg",
                "online": 1
            }]
        })
        .to_string(),
    ));

    let client = make_client(&dir, store.clone(), &server);
    assert_eq!(client.restore_session().await, AuthState::LoggedOut);

    // OAuth config read + update + authorize URL check
    let default_cfg = client.get_oauth_config();
    assert!(!default_cfg.client_id.is_empty());
    assert!(!default_cfg.client_secret.is_empty());

    client
        .set_oauth_config("998877".to_string(), "sec_custom".to_string())
        .unwrap();
    let updated_cfg = client.get_oauth_config();
    assert_eq!(updated_cfg.client_id, "998877");
    assert_eq!(updated_cfg.client_secret, "sec_custom");
    assert!(dir.path().join(OAUTH_CONFIG_FILENAME).exists());
    let auth_url = client.get_oauth_authorize_url();
    assert!(auth_url.contains("client_id=998877"));

    // 2FA challenge -> Authenticated
    let step1 = client
        .login_password("user@vk.com".into(), "pass".into(), None, None, None)
        .await
        .unwrap();
    assert_eq!(
        step1,
        AuthState::Needs2FA {
            validation_type: "2fa_sms".to_string(),
            phone_mask: "+7 *** *** ** 42".to_string(),
            redirect_uri: None,
        }
    );

    let step2 = client
        .login_password(
            "user@vk.com".into(),
            "pass".into(),
            Some("123456".into()),
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(step2, AuthState::Authenticated { user_id: 777 });
    assert_eq!(
        client.restore_session().await,
        AuthState::Authenticated { user_id: 777 }
    );

    // get_current_user fetches & caches user in SQLite
    let me = client.get_current_user().await.unwrap().unwrap();
    assert_eq!(me.id, 777);
    assert_eq!(me.first_name, "Pavel");
    assert!(me.online);

    let storage_check = Storage::open(dir.path()).unwrap();
    assert_eq!(storage_check.get_user(777).unwrap(), Some(me));
    drop(storage_check);

    // logout clears token store and SQLite
    client.logout().await.unwrap();
    assert_eq!(client.restore_session().await, AuthState::LoggedOut);
    assert_eq!(store.get_session().unwrap(), None);
    let storage_after = Storage::open(dir.path()).unwrap();
    assert_eq!(storage_after.get_user(777).unwrap(), None);
}

#[tokio::test]
async fn test_vk_client_redirect_login_and_unauthenticated_errors() {
    let dir = TempDir::new().unwrap();
    let store = Arc::new(InMemoryTokenStore::new());
    let server = MockVkServer::start().await;
    let client = make_client(&dir, store, &server);

    assert_eq!(client.get_current_user().await.unwrap(), None);
    assert!(matches!(
        client.get_conversations(0, 20).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.get_messages(10, 0, 20).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.send_message(10, "hi".into()).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.get_newsfeed(None).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.like_post(1, 2).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.unlike_post(1, 2).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.get_audio(0, 20).await.unwrap_err(),
        VkError::InvalidToken
    ));
    assert!(matches!(
        client.search_audio("rock".into()).await.unwrap_err(),
        VkError::InvalidToken
    ));

    // Redirect URL login succeeds and enables API calls
    let auth_state = client
        .login_with_redirect_url(
            "https://oauth.vk.com/blank.html#access_token=redir_tok_1&expires_in=0&user_id=501"
                .to_string(),
        )
        .await
        .unwrap();
    assert_eq!(auth_state, AuthState::Authenticated { user_id: 501 });

    server.method_queue.lock().await.push_back((
        200,
        json!({
            "response": [{
                "id": 501,
                "first_name": "Elena",
                "last_name": "K",
                "online": false
            }]
        })
        .to_string(),
    ));
    let user = client.get_current_user().await.unwrap().unwrap();
    assert_eq!(user.id, 501);
    assert_eq!(user.first_name, "Elena");
}

#[tokio::test]
async fn test_vk_client_cache_first_chats_and_send_message_write_through() {
    let dir = TempDir::new().unwrap();
    let store = Arc::new(InMemoryTokenStore::with_session("tok_chat", 42));
    let server = MockVkServer::start().await;

    server.method_queue.lock().await.push_back((
        200,
        json!({
            "response": {
                "items": [{
                    "conversation": {
                        "peer": {"id": 1001, "type": "user"},
                        "unread_count": 1
                    },
                    "last_message": {
                        "id": 10,
                        "from_id": 1001,
                        "peer_id": 1001,
                        "text": "Initial msg",
                        "date": 1700000100,
                        "out": 0,
                        "attachments": []
                    }
                }],
                "profiles": [{
                    "id": 1001,
                    "first_name": "Alice",
                    "last_name": "W",
                    "photo_200": "https://cdn/alice.jpg",
                    "online": 1
                }],
                "groups": []
            }
        })
        .to_string(),
    ));
    server.method_queue.lock().await.push_back((
        200,
        json!({
            "response": {
                "items": [{
                    "id": 10,
                    "peer_id": 1001,
                    "from_id": 1001,
                    "text": "Initial msg",
                    "date": 1700000100,
                    "out": 0,
                    "attachments": []
                }],
                "profiles": []
            }
        })
        .to_string(),
    ));
    server
        .method_queue
        .lock()
        .await
        .push_back((200, json!({"response": 99}).to_string()));

    let client = make_client(&dir, store, &server);

    // Cache starts empty
    assert!(client.get_cached_conversations(0, 20).unwrap().is_empty());
    assert!(client.get_cached_messages(1001, 0, 20).unwrap().is_empty());

    // Fetch from network populates cache
    let convs = client.get_conversations(0, 20).await.unwrap();
    assert_eq!(convs.len(), 1);
    assert_eq!(convs[0].title, "Alice W");

    let msgs = client.get_messages(1001, 0, 20).await.unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].id, 10);

    // Local validation on send_message before hitting network
    assert!(matches!(
        client.send_message(0, "hi".into()).await.unwrap_err(),
        VkError::InvalidInput { .. }
    ));
    assert!(matches!(
        client.send_message(1001, "   ".into()).await.unwrap_err(),
        VkError::InvalidInput { .. }
    ));

    // send_message writes through to both messages and conversations
    let sent = client
        .send_message(1001, "Hello back!".to_string())
        .await
        .unwrap();
    assert_eq!(sent.id, 99);
    assert_eq!(sent.from_id, 42);
    assert!(sent.is_out);
    assert_eq!(sent.text, "Hello back!");

    // Shut down mock server and verify cache-first reads continue to work offline
    drop(server);

    let cached_convs = client.get_cached_conversations(0, 20).unwrap();
    assert_eq!(cached_convs.len(), 1);
    assert_eq!(cached_convs[0].last_message_text, "Hello back!");
    assert_eq!(cached_convs[0].unread_count, 0);

    let cached_msgs = client.get_cached_messages(1001, 0, 20).unwrap();
    assert_eq!(cached_msgs.len(), 2);
    assert_eq!(cached_msgs[0].id, 99);
    assert_eq!(cached_msgs[1].id, 10);
}

#[tokio::test]
async fn test_vk_client_newsfeed_likes_audio_and_cache_management() {
    let dir = TempDir::new().unwrap();
    let store = Arc::new(InMemoryTokenStore::with_session("tok_media", 42));
    let server = MockVkServer::start().await;

    {
        let mut mq = server.method_queue.lock().await;
        mq.push_back((
            200,
            json!({
                "response": {
                    "items": [{
                        "type": "post",
                        "post_id": 10,
                        "source_id": 5,
                        "date": 1700001000,
                        "text": "Page 1",
                        "attachments": [],
                        "likes": {"count": 3, "user_likes": 0},
                        "comments": {"count": 1}
                    }],
                    "profiles": [{"id": 5, "first_name": "A", "last_name": "B"}],
                    "groups": [],
                    "next_from": "cursor_2"
                }
            })
            .to_string(),
        ));
        mq.push_back((
            200,
            json!({
                "response": {
                    "items": [{
                        "type": "post",
                        "post_id": 20,
                        "source_id": -8,
                        "date": 1700001100,
                        "text": "Page 2",
                        "attachments": [],
                        "likes": {"count": 7, "user_likes": 1},
                        "comments": {"count": 0}
                    }],
                    "profiles": [],
                    "groups": [{"id": 8, "name": "Group"}]
                }
            })
            .to_string(),
        ));
        mq.push_back((200, json!({"response": {"likes": 8}}).to_string()));
        mq.push_back((200, json!({"response": {"likes": 7}}).to_string()));
        mq.push_back((
            200,
            json!({
                "response": {
                    "count": 1,
                    "items": [{
                        "id": 300,
                        "owner_id": 42,
                        "artist": "LibArtist",
                        "title": "LibTrack",
                        "duration": 195,
                        "url": "https://cdn/lib.m3u8"
                    }]
                }
            })
            .to_string(),
        ));
        mq.push_back((
            200,
            json!({
                "response": {
                    "count": 1,
                    "items": [{
                        "id": 999,
                        "owner_id": 99,
                        "artist": "SearchArtist",
                        "title": "SearchTrack",
                        "duration": 200,
                        "url": "https://cdn/search.m3u8"
                    }]
                }
            })
            .to_string(),
        ));
    }

    let client = make_client(&dir, store, &server);

    let p1 = client.get_newsfeed(None).await.unwrap();
    assert_eq!(p1.next_from.as_deref(), Some("cursor_2"));
    assert_eq!(p1.items[0].post_id, 10);

    let p2 = client.get_newsfeed(p1.next_from).await.unwrap();
    assert_eq!(p2.next_from, None);
    assert_eq!(p2.items[0].post_id, 20);
    assert_eq!(p2.items[0].author_name, "Group");

    assert_eq!(client.like_post(-8, 20).await.unwrap(), 8);
    assert_eq!(client.unlike_post(-8, 20).await.unwrap(), 7);

    // Audio library caches, while search_audio does NOT overwrite library cache
    let lib_tracks = client.get_audio(0, 50).await.unwrap();
    assert_eq!(lib_tracks.len(), 1);
    assert_eq!(lib_tracks[0].id, 300);

    assert!(matches!(
        client.search_audio("   ".into()).await.unwrap_err(),
        VkError::InvalidInput { .. }
    ));
    let search_tracks = client.search_audio("SearchTrack".into()).await.unwrap();
    assert_eq!(search_tracks.len(), 1);
    assert_eq!(search_tracks[0].id, 999);

    let cached_audio = client.get_cached_audio(0, 50).unwrap();
    assert_eq!(cached_audio.len(), 1);
    assert_eq!(cached_audio[0].id, 300);

    assert!(client.get_cache_size_bytes().unwrap() > 0);
    client.clear_cache().unwrap();
    assert!(client.get_cached_audio(0, 50).unwrap().is_empty());

    let reqs = server.requests().await;
    assert_eq!(reqs[0].path, "/method/newsfeed.get");
    assert_eq!(reqs[1].path, "/method/newsfeed.get");
    assert_eq!(
        reqs[1].params.get("start_from").map(String::as_str),
        Some("cursor_2")
    );
}

#[tokio::test]
async fn test_vk_client_longpoll_events_and_sqlite_write_through() {
    // Part A: Subscribe BEFORE login, verify Long Poll starts on login and delivers events.
    let dir1 = TempDir::new().unwrap();
    let store1 = Arc::new(InMemoryTokenStore::new());
    let server1 = MockVkServer::start().await;

    server1.method_queue.lock().await.push_back((
        200,
        json!({
            "response": {
                "key": "lp_key_pre",
                "server": server1.lp_url,
                "ts": 1
            }
        })
        .to_string(),
    ));
    {
        let mut lq = server1.lp_queue.lock().await;
        lq.push_back(MockReply::Immediate(
            200,
            json!({
                "ts": 2,
                "updates": [
                    [4, 7001, 1, 555, 250, "Pre-subscribed LP", {"from": 555}]
                ]
            })
            .to_string(),
        ));
        lq.push_back(MockReply::Hold(
            Duration::from_secs(30),
            r#"{"ts":2,"updates":[]}"#.to_string(),
        ));
    }

    let client1 = make_client(&dir1, store1, &server1);
    let collector1 = Arc::new(EventCollector::new());
    client1.subscribe_events(collector1.clone()).await;
    client1
        .login_with_redirect_url(
            "https://oauth.vk.com/blank.html#access_token=lp_tok_1&expires_in=0&user_id=42"
                .to_string(),
        )
        .await
        .unwrap();

    let got_pre = collector1
        .wait_for(Duration::from_secs(5), |events| {
            events.iter().any(|e| matches!(
                e,
                VkEvent::NewMessage { message } if message.id == 7001
            ))
        })
        .await;
    assert!(got_pre, "Timed out waiting for pre-subscribed Long Poll event");
    assert!(collector1
        .snapshot()
        .contains(&VkEvent::ConnectionStatus { connected: true }));
    client1.logout().await.unwrap();

    // Part B: Subscribe AFTER login + get_conversations, verify SQLite write-through & ReadIncoming.
    let dir2 = TempDir::new().unwrap();
    let store2 = Arc::new(InMemoryTokenStore::new());
    let server2 = MockVkServer::start().await;
    {
        let mut mq = server2.method_queue.lock().await;
        mq.push_back((
            200,
            json!({
                "response": {
                    "items": [{
                        "conversation": {
                            "peer": {"id": 555, "type": "user"},
                            "unread_count": 0
                        },
                        "last_message": {
                            "id": 1,
                            "from_id": 555,
                            "peer_id": 555,
                            "text": "Hi",
                            "date": 100,
                            "out": 0,
                            "attachments": []
                        }
                    }],
                    "profiles": [{"id": 555, "first_name": "Peer", "last_name": "One"}],
                    "groups": []
                }
            })
            .to_string(),
        ));
        mq.push_back((
            200,
            json!({
                "response": {
                    "key": "lp_key_e2e",
                    "server": server2.lp_url,
                    "ts": 10
                }
            })
            .to_string(),
        ));
    }
    {
        let mut lq = server2.lp_queue.lock().await;
        lq.push_back(MockReply::Immediate(
            200,
            json!({
                "ts": 11,
                "updates": [
                    [4, 8001, 1, 555, 250, "Incoming LP", {"from": 555}],
                    [61, 555, 1]
                ]
            })
            .to_string(),
        ));
        lq.push_back(MockReply::Immediate(
            200,
            json!({
                "ts": 12,
                "updates": [
                    [6, 555, 8001]
                ]
            })
            .to_string(),
        ));
        lq.push_back(MockReply::Hold(
            Duration::from_secs(30),
            r#"{"ts":12,"updates":[]}"#.to_string(),
        ));
    }

    let client2 = make_client(&dir2, store2, &server2);
    let collector2 = Arc::new(EventCollector::new());

    client2
        .login_with_redirect_url(
            "https://oauth.vk.com/blank.html#access_token=lp_tok&expires_in=0&user_id=42"
                .to_string(),
        )
        .await
        .unwrap();

    // Populate conversation cache before starting Long Poll
    client2.get_conversations(0, 20).await.unwrap();

    // Subscribe AFTER login -> starts Long Poll and emits events
    client2.subscribe_events(collector2.clone()).await;

    let done = collector2
        .wait_for(Duration::from_secs(5), |events| {
            events
                .iter()
                .any(|e| matches!(e, VkEvent::ReadIncoming { peer_id: 555, msg_id: 8001 }))
        })
        .await;
    assert!(done, "Timed out waiting for Long Poll E2E events");

    let events = collector2.snapshot();
    assert!(events.contains(&VkEvent::ConnectionStatus { connected: true }));
    assert!(events.iter().any(|e| matches!(
        e,
        VkEvent::NewMessage { message } if message.id == 8001 && message.text == "Incoming LP"
    )));
    assert!(events
        .iter()
        .any(|e| matches!(e, VkEvent::Typing { peer_id: 555, user_id: 555 })));

    let cached_msgs = client2.get_cached_messages(555, 0, 20).unwrap();
    assert_eq!(cached_msgs.len(), 1);
    assert_eq!(cached_msgs[0].id, 8001);

    let cached_convs = client2.get_cached_conversations(0, 20).unwrap();
    assert_eq!(cached_convs[0].last_message_text, "Incoming LP");
    assert_eq!(cached_convs[0].unread_count, 0);

    // logout stops Long Poll cleanly and clears cache
    client2.logout().await.unwrap();
    assert!(client2.get_cached_messages(555, 0, 20).unwrap().is_empty());
    assert!(client2.get_cached_conversations(0, 20).unwrap().is_empty());
}
