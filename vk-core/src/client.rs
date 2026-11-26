use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::api::{VkApiClient, VK_USER_AGENT};
use crate::auth::AuthManager;
use crate::config;
use crate::error::VkError;
use crate::keychain::{KeychainStore, TokenStore};
use crate::longpoll::{LongPollConfig, LongPollHandle, LongPollWorker};
use crate::models::{
    AccountSummary, ArtistStat, Attachment, AudioPlaylist, AudioTrack, AuthState, BirthdayFriend,
    BotKeyboard, ChatMember, ChatStats, CommentItem, ConversationItem, FaveItem, FriendRequestItem,
    MessageItem, NewsfeedPage, NotificationItem, OAuthConfig, OwnerPage, OwnerSummary,
    ResolvedTarget, SnippetItem, StickerPack, StoryItem, UserPresence, UserProfile, VideoItem,
    VkEvent, VkEventListener,
};
use crate::storage::Storage;

#[derive(uniffi::Object)]
pub struct VkClient {
    data_dir: PathBuf,
    storage: Arc<Storage>,
    auth: Arc<AuthManager>,
    api: Arc<VkApiClient>,
    longpoll_http: reqwest::Client,
    longpoll_config: LongPollConfig,
    handle: tokio::runtime::Handle,
    owned_runtime: Option<tokio::runtime::Runtime>,
    listener: Arc<RwLock<Option<Arc<dyn VkEventListener>>>>,
    longpoll: Mutex<Option<LongPollHandle>>,
    longpoll_op_lock: tokio::sync::Mutex<()>,
}

impl Drop for VkClient {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.longpoll.lock() {
            if let Some(mut handle) = guard.take() {
                handle.abort();
            }
        }
        if let Some(rt) = self.owned_runtime.take() {
            if tokio::runtime::Handle::try_current().is_ok() {
                // Never drop a Tokio Runtime synchronously inside an active Tokio context.
                rt.shutdown_background();
            } else {
                rt.shutdown_timeout(Duration::from_millis(100));
            }
        }
    }
}

impl VkClient {
    pub fn new_with_deps(
        data_dir: &Path,
        token_store: Arc<dyn TokenStore>,
        api_base_url: impl Into<String>,
        oauth_token_url: impl Into<String>,
        oauth_authorize_url: impl Into<String>,
    ) -> Result<Arc<Self>, VkError> {
        Self::build_client(
            data_dir.to_path_buf(),
            token_store,
            api_base_url.into(),
            oauth_token_url.into(),
            oauth_authorize_url.into(),
            LongPollConfig::default(),
            true,
        )
    }

    pub fn new_with_deps_and_longpoll_config(
        data_dir: &Path,
        token_store: Arc<dyn TokenStore>,
        api_base_url: impl Into<String>,
        oauth_token_url: impl Into<String>,
        oauth_authorize_url: impl Into<String>,
        longpoll_config: LongPollConfig,
    ) -> Result<Arc<Self>, VkError> {
        Self::build_client(
            data_dir.to_path_buf(),
            token_store,
            api_base_url.into(),
            oauth_token_url.into(),
            oauth_authorize_url.into(),
            longpoll_config,
            true,
        )
    }

    fn build_client(
        data_dir: PathBuf,
        token_store: Arc<dyn TokenStore>,
        api_base_url: String,
        oauth_token_url: String,
        oauth_authorize_url: String,
        longpoll_config: LongPollConfig,
        no_proxy: bool,
    ) -> Result<Arc<Self>, VkError> {
        let (handle, owned_runtime) = init_runtime()?;
        let storage = Arc::new(Storage::open(&data_dir)?);
        let oauth_cfg = config::resolve_oauth_config(&data_dir);

        let mut http_builder = reqwest::Client::builder()
            .use_rustls_tls()
            .user_agent(VK_USER_AGENT)
            .timeout(Duration::from_secs(30));
        if no_proxy {
            http_builder = http_builder.no_proxy();
        }
        let http = http_builder.build().map_err(|err| VkError::Network {
            details: format!("Failed to build HTTP client: {err}"),
        })?;

        let mut lp_timeout = longpoll_config.request_timeout + Duration::from_secs(5);
        if lp_timeout < Duration::from_secs(40) {
            lp_timeout = Duration::from_secs(40);
        }
        let mut lp_http_builder = reqwest::Client::builder()
            .use_rustls_tls()
            .user_agent(VK_USER_AGENT)
            .timeout(lp_timeout);
        if no_proxy {
            lp_http_builder = lp_http_builder.no_proxy();
        }
        let longpoll_http = lp_http_builder.build().map_err(|err| VkError::Network {
            details: format!("Failed to build Long Poll HTTP client: {err}"),
        })?;

        let auth = Arc::new(AuthManager::new(
            http.clone(),
            token_store,
            oauth_cfg,
            oauth_token_url,
            oauth_authorize_url,
        ));
        let api = Arc::new(VkApiClient::with_client(http, api_base_url));

        Ok(Arc::new(Self {
            data_dir,
            storage,
            auth,
            api,
            longpoll_http,
            longpoll_config,
            handle,
            owned_runtime,
            listener: Arc::new(RwLock::new(None)),
            longpoll: Mutex::new(None),
            longpoll_op_lock: tokio::sync::Mutex::new(()),
        }))
    }

    fn require_session(&self) -> Result<(String, i64), VkError> {
        match self.auth.current_session()? {
            Some((token, user_id)) if !token.trim().is_empty() && user_id > 0 => {
                Ok((token, user_id))
            }
            _ => Err(VkError::InvalidToken),
        }
    }

    fn take_longpoll(&self) -> Option<LongPollHandle> {
        let mut guard = self
            .longpoll
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.take()
    }

    async fn stop_longpoll_locked(&self) {
        if let Some(handle) = self.take_longpoll() {
            handle.stop().await;
        }
    }

    async fn stop_longpoll_async(&self) {
        let _op_guard = self.longpoll_op_lock.lock().await;
        self.stop_longpoll_locked().await;
    }

    async fn start_longpoll_if_ready_locked(&self) {
        let has_listener = self
            .listener
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_some();
        if !has_listener {
            return;
        }

        let session = match self.auth.current_session() {
            Ok(Some((token, user_id))) if !token.trim().is_empty() && user_id > 0 => {
                (token, user_id)
            }
            _ => return,
        };

        let lp_handle = LongPollWorker::spawn(
            &self.handle,
            Arc::clone(&self.api),
            Arc::clone(&self.storage),
            self.longpoll_http.clone(),
            session.0,
            session.1,
            Arc::clone(&self.listener),
            self.longpoll_config.clone(),
        );

        let mut guard = self
            .longpoll
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard = Some(lp_handle);
    }

    async fn restart_longpoll_if_ready(&self) {
        let _op_guard = self.longpoll_op_lock.lock().await;
        self.stop_longpoll_locked().await;
        self.start_longpoll_if_ready_locked().await;
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl VkClient {
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Result<Arc<Self>, VkError> {
        let resolved_dir = config::resolve_data_dir(&data_dir)?;
        Self::build_client(
            resolved_dir,
            Arc::new(KeychainStore::default()),
            config::api_base_url(),
            config::oauth_token_url(),
            config::oauth_authorize_url(),
            LongPollConfig::default(),
            false,
        )
    }

    pub async fn restore_session(&self) -> AuthState {
        let state = self.auth.restore_session();
        if matches!(state, AuthState::Authenticated { .. }) {
            self.restart_longpoll_if_ready().await;
        }
        state
    }

    pub async fn login_password(
        &self,
        login: String,
        password: String,
        code_2fa: Option<String>,
        captcha_sid: Option<String>,
        captcha_key: Option<String>,
    ) -> Result<AuthState, VkError> {
        let state = self
            .auth
            .login_password(
                &login,
                &password,
                code_2fa.as_deref(),
                captcha_sid.as_deref(),
                captcha_key.as_deref(),
            )
            .await?;
        if matches!(state, AuthState::Authenticated { .. }) {
            self.restart_longpoll_if_ready().await;
        }
        Ok(state)
    }

    pub async fn login_with_redirect_url(&self, url: String) -> Result<AuthState, VkError> {
        let state = self.auth.login_with_redirect_url(&url)?;
        if matches!(state, AuthState::Authenticated { .. }) {
            self.restart_longpoll_if_ready().await;
        }
        Ok(state)
    }

    pub async fn request_2fa_sms(&self) -> Result<(), VkError> {
        self.auth.request_2fa_sms(self.api.base_url()).await
    }

    pub async fn login_with_token(&self, token_or_url: String) -> Result<AuthState, VkError> {
        let trimmed = token_or_url.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Token or redirect URL must not be empty".to_string(),
            });
        }
        if trimmed.contains("access_token=") {
            return self.login_with_redirect_url(trimmed.to_string()).await;
        }

        let user = self
            .api
            .get_current_user(trimmed)
            .await?
            .ok_or(VkError::InvalidToken)?;
        let state = self.auth.save_direct_token(trimmed, user.id)?;
        let _ = self.storage.upsert_users(&[user], unix_now());
        self.restart_longpoll_if_ready().await;
        Ok(state)
    }

    pub async fn logout(&self) -> Result<(), VkError> {
        self.stop_longpoll_async().await;
        self.auth.logout()?;
        self.storage.clear_all()?;
        Ok(())
    }

    pub async fn subscribe_events(&self, listener: Arc<dyn VkEventListener>) {
        let _op_guard = self.longpoll_op_lock.lock().await;
        {
            let mut guard = self
                .listener
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *guard = Some(Arc::clone(&listener));
        }

        let already_connected = {
            let guard = self
                .longpoll
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard.as_ref().map(|h| h.is_connected())
        };

        match already_connected {
            Some(true) => {
                let _ = self
                    .handle
                    .spawn_blocking(move || {
                        listener.on_event(VkEvent::ConnectionStatus { connected: true });
                    })
                    .await;
            }
            Some(false) => {
                // Worker is already running and will emit ConnectionStatus on state change.
            }
            None => {
                self.start_longpoll_if_ready_locked().await;
            }
        }
    }

    pub fn get_oauth_config(&self) -> OAuthConfig {
        self.auth.oauth_config()
    }

    pub fn set_oauth_config(&self, client_id: String, client_secret: String) -> Result<(), VkError> {
        let cfg = OAuthConfig {
            client_id: client_id.trim().to_string(),
            client_secret: client_secret.trim().to_string(),
        };
        config::save_oauth_config(&self.data_dir, &cfg)?;
        self.auth.set_oauth_config(cfg);
        Ok(())
    }

    pub fn get_oauth_authorize_url(&self) -> String {
        self.auth.authorize_url()
    }

    pub async fn get_current_user(&self) -> Result<Option<UserProfile>, VkError> {
        let Some((token, user_id)) = self.auth.current_session()? else {
            return Ok(None);
        };
        if token.trim().is_empty() || user_id <= 0 {
            return Ok(None);
        }

        let users = self.api.get_users(&token, &[user_id]).await?;
        let profile = users.into_iter().next();
        if let Some(ref user) = profile {
            self.storage
                .upsert_users(std::slice::from_ref(user), unix_now())?;
        }
        Ok(profile)
    }

    pub fn get_cached_conversations(
        &self,
        offset: u32,
        count: u32,
    ) -> Result<Vec<ConversationItem>, VkError> {
        self.storage.get_conversations(offset, count)
    }

    pub async fn get_conversations(
        &self,
        offset: u32,
        count: u32,
    ) -> Result<Vec<ConversationItem>, VkError> {
        let (token, _) = self.require_session()?;
        let page = self
            .api
            .get_conversations_with_profiles(&token, offset, count)
            .await?;
        if !page.profiles.is_empty() {
            self.storage.upsert_users(&page.profiles, unix_now())?;
        }
        self.storage.upsert_conversations(&page.items)?;
        Ok(page.items)
    }

    pub fn get_cached_messages(
        &self,
        peer_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        self.storage.get_messages(peer_id, offset, count)
    }

    pub async fn get_messages(
        &self,
        peer_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        let (token, _) = self.require_session()?;
        let page = self
            .api
            .get_history_with_profiles(&token, peer_id, offset, count)
            .await?;
        if !page.profiles.is_empty() {
            self.storage.upsert_users(&page.profiles, unix_now())?;
        }
        self.storage.upsert_messages(&page.items)?;
        Ok(page.items)
    }

    pub async fn get_conversation_keyboard(
        &self,
        peer_id: i64,
    ) -> Result<Option<BotKeyboard>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_conversation_keyboard(&token, peer_id).await
    }

    pub async fn send_message(&self, peer_id: i64, text: String) -> Result<MessageItem, VkError> {
        self.send_message_with_payload(peer_id, text, None).await
    }

    pub async fn send_message_with_payload(
        &self,
        peer_id: i64,
        text: String,
        payload: Option<String>,
    ) -> Result<MessageItem, VkError> {
        if peer_id == 0 {
            return Err(VkError::InvalidInput {
                details: "peer_id must not be zero".to_string(),
            });
        }
        if text.trim().is_empty() {
            return Err(VkError::InvalidInput {
                details: "Message text must not be empty".to_string(),
            });
        }

        let (token, user_id) = self.require_session()?;
        let msg_id = self
            .api
            .send_message_with_payload(&token, peer_id, &text, payload.as_deref())
            .await?;

        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text,
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };

        self.storage.upsert_messages(std::slice::from_ref(&msg))?;
        self.storage.update_conversation_on_new_message(&msg)?;
        Ok(msg)
    }

    pub async fn get_newsfeed(&self, start_from: Option<String>) -> Result<NewsfeedPage, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_newsfeed(&token, start_from.as_deref(), 20)
            .await
    }

    pub async fn get_owner_page(
        &self,
        owner_id: i64,
        wall_count: u32,
    ) -> Result<OwnerPage, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_owner_page(&token, owner_id, wall_count).await
    }

    pub async fn get_friends(&self, count: u32) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_friends(&token, count).await
    }

    pub async fn get_user_friends(
        &self,
        user_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_user_friends(&token, Some(user_id), count)
            .await
    }

    pub async fn get_followers(
        &self,
        user_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, self_id) = self.require_session()?;
        let target = if user_id == 0 { self_id } else { user_id };
        self.api.get_followers(&token, target, count).await
    }

    pub async fn get_group_members(
        &self,
        group_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_group_members(&token, group_id, count).await
    }

    pub async fn get_groups(&self, count: u32) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_groups(&token, count).await
    }

    pub async fn get_user_groups(
        &self,
        user_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_user_groups(&token, Some(user_id), count).await
    }

    pub async fn get_owner_photos(
        &self,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<String>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_owner_photos(&token, owner_id, count).await
    }

    pub async fn get_owner_audio(
        &self,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_owner_audio(&token, owner_id, count).await
    }

    pub async fn get_post_comments(
        &self,
        owner_id: i64,
        post_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<CommentItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_post_comments(&token, owner_id, post_id, offset, count)
            .await
    }

    pub async fn create_comment(
        &self,
        owner_id: i64,
        post_id: i64,
        message: String,
    ) -> Result<i64, VkError> {
        let trimmed = message.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Comment text must not be empty".to_string(),
            });
        }
        let (token, _) = self.require_session()?;
        self.api
            .create_comment(&token, owner_id, post_id, trimmed)
            .await
    }

    pub async fn create_post(&self, owner_id: i64, message: String) -> Result<i64, VkError> {
        let trimmed = message.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Post text must not be empty".to_string(),
            });
        }
        let (token, self_user_id) = self.require_session()?;
        let target_owner = if owner_id == 0 { self_user_id } else { owner_id };
        self.api.create_post(&token, target_owner, trimmed).await
    }

    pub async fn repost_post(
        &self,
        owner_id: i64,
        post_id: i64,
        message: Option<String>,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .repost_post(&token, owner_id, post_id, message.as_deref())
            .await
    }

    pub async fn add_friend(&self, user_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.add_friend(&token, user_id).await
    }

    pub async fn remove_friend(&self, user_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.remove_friend(&token, user_id).await
    }

    pub async fn join_group(&self, group_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.join_group(&token, group_id).await
    }

    pub async fn leave_group(&self, group_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.leave_group(&token, group_id).await
    }

    pub async fn get_notifications(&self, count: u32) -> Result<Vec<NotificationItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_notifications(&token, count).await
    }

    pub async fn get_videos(
        &self,
        owner_id: Option<i64>,
        count: u32,
    ) -> Result<Vec<VideoItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_videos(&token, owner_id, count).await
    }

    pub async fn search_videos(&self, query: String, count: u32) -> Result<Vec<VideoItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.search_videos(&token, query.trim(), count).await
    }

    pub async fn resolve_video(
        &self,
        owner_id: i64,
        video_id: i64,
        access_key: Option<String>,
    ) -> Result<VideoItem, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .resolve_video(&token, owner_id, video_id, access_key.as_deref())
            .await
    }

    pub async fn search_users(
        &self,
        query: String,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.search_users(&token, query.trim(), count).await
    }

    pub async fn search_groups(
        &self,
        query: String,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.search_groups(&token, query.trim(), count).await
    }

    pub async fn get_audio_playlists(
        &self,
        owner_id: Option<i64>,
        count: u32,
    ) -> Result<Vec<AudioPlaylist>, VkError> {
        let (token, self_user_id) = self.require_session()?;
        self.api
            .get_audio_playlists(&token, owner_id.unwrap_or(self_user_id), count)
            .await
    }

    pub async fn get_playlist_audio(
        &self,
        owner_id: i64,
        album_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_playlist_audio(&token, owner_id, album_id, count)
            .await
    }

    pub async fn send_message_with_options(
        &self,
        peer_id: i64,
        text: String,
        reply_to: Option<i64>,
        photo_path: Option<String>,
    ) -> Result<MessageItem, VkError> {
        let trimmed = text.trim();
        let has_photo = photo_path
            .as_deref()
            .map(str::trim)
            .is_some_and(|p| !p.is_empty());
        if trimmed.is_empty() && !has_photo {
            return Err(VkError::InvalidInput {
                details: "Message text or photo must not be empty".to_string(),
            });
        }

        let (token, user_id) = self.require_session()?;
        let attachment = if let Some(path_str) = photo_path.as_deref().map(str::trim).filter(|p| !p.is_empty()) {
            let path = std::path::Path::new(path_str);
            let bytes = std::fs::read(path).map_err(|err| VkError::InvalidInput {
                details: format!("Failed to read photo file {}: {err}", path.display()),
            })?;
            let filename = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("photo.jpg");
            Some(
                self.api
                    .upload_message_photo(&token, peer_id, bytes, filename)
                    .await?,
            )
        } else {
            None
        };

        let msg_id = self
            .api
            .send_message_with_options(&token, peer_id, trimmed, reply_to, attachment.as_deref())
            .await?;
        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text: trimmed.to_string(),
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };
        self.storage.upsert_messages(std::slice::from_ref(&msg))?;
        self.storage.update_conversation_on_new_message(&msg)?;
        Ok(msg)
    }

    pub async fn delete_message(&self, message_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.delete_message(&token, message_id).await
    }

    pub async fn edit_message(
        &self,
        peer_id: i64,
        message_id: i64,
        text: String,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .edit_message(&token, peer_id, message_id, text.trim())
            .await
    }

    pub async fn mark_as_read(&self, peer_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.mark_as_read(&token, peer_id).await?;
        let _ = self.storage.mark_conversation_read(peer_id);
        Ok(())
    }

    pub async fn like_post(&self, owner_id: i64, post_id: i64) -> Result<u32, VkError> {
        let (token, _) = self.require_session()?;
        self.api.like_post(&token, owner_id, post_id).await
    }

    pub async fn unlike_post(&self, owner_id: i64, post_id: i64) -> Result<u32, VkError> {
        let (token, _) = self.require_session()?;
        self.api.unlike_post(&token, owner_id, post_id).await
    }

    pub fn get_cached_audio(&self, offset: u32, count: u32) -> Result<Vec<AudioTrack>, VkError> {
        self.storage.get_audio_tracks(offset, count)
    }

    pub async fn get_audio(&self, offset: u32, count: u32) -> Result<Vec<AudioTrack>, VkError> {
        let (token, _) = self.require_session()?;
        let tracks = self.api.get_audio(&token, offset, count).await?;
        self.storage.upsert_audio_tracks(&tracks, offset)?;
        Ok(tracks)
    }

    pub async fn search_audio(&self, query: String) -> Result<Vec<AudioTrack>, VkError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Audio search query must not be empty".to_string(),
            });
        }
        let (token, _) = self.require_session()?;
        self.api.search_audio(&token, trimmed, 0, 50).await
    }

    pub fn clear_cache(&self) -> Result<(), VkError> {
        self.storage.clear_all()
    }

    pub fn get_cache_size_bytes(&self) -> Result<u64, VkError> {
        self.storage.cache_size_bytes()
    }

    // --- Drafts, Pins, History, Local Search, Prefs ---

    pub fn save_draft(&self, peer_id: i64, text: String) -> Result<(), VkError> {
        self.storage.save_draft(peer_id, &text, unix_now())
    }

    pub fn get_draft(&self, peer_id: i64) -> Result<String, VkError> {
        self.storage.get_draft(peer_id)
    }

    pub fn toggle_pin_conversation(&self, peer_id: i64) -> Result<bool, VkError> {
        self.storage.toggle_pin_conversation(peer_id, unix_now())
    }

    pub fn get_pinned_peers(&self) -> Result<Vec<i64>, VkError> {
        self.storage.get_pinned_peers()
    }

    pub fn record_track_play(&self, track: AudioTrack) -> Result<(), VkError> {
        self.storage.record_track_play(&track, unix_now())
    }

    pub fn get_listening_history(&self, limit: u32) -> Result<Vec<AudioTrack>, VkError> {
        self.storage.get_listening_history(limit)
    }

    pub fn search_cached_messages(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        self.storage.search_cached_messages(&query, limit)
    }

    pub fn set_pref(&self, key: String, value: String) -> Result<(), VkError> {
        self.storage.set_pref(&key, &value)
    }

    pub fn get_pref(&self, key: String) -> Result<Option<String>, VkError> {
        self.storage.get_pref(&key)
    }

    // --- Advanced Chats & Docs & Stickers & Presence ---

    pub async fn send_doc_message(
        &self,
        peer_id: i64,
        file_path: String,
        text: String,
        is_audio_message: bool,
    ) -> Result<MessageItem, VkError> {
        let path = std::path::Path::new(file_path.trim());
        let bytes = std::fs::read(path).map_err(|err| VkError::InvalidInput {
            details: format!("Failed to read file {}: {err}", path.display()),
        })?;
        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("file.bin");
        let (token, user_id) = self.require_session()?;
        let att = self
            .api
            .upload_message_doc(&token, peer_id, bytes, filename, is_audio_message)
            .await?;
        let msg_id = self
            .api
            .send_message_with_options(&token, peer_id, text.trim(), None, Some(&att))
            .await?;
        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text: text.trim().to_string(),
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };
        self.storage.upsert_messages(std::slice::from_ref(&msg))?;
        self.storage.update_conversation_on_new_message(&msg)?;
        Ok(msg)
    }

    pub async fn forward_messages(
        &self,
        peer_id: i64,
        message_ids: Vec<i64>,
        text: String,
    ) -> Result<MessageItem, VkError> {
        let (token, user_id) = self.require_session()?;
        let msg_id = self
            .api
            .forward_messages(&token, peer_id, &message_ids, text.trim())
            .await?;
        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text: text.trim().to_string(),
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };
        self.storage.upsert_messages(std::slice::from_ref(&msg))?;
        self.storage.update_conversation_on_new_message(&msg)?;
        Ok(msg)
    }

    pub async fn send_sticker(&self, peer_id: i64, sticker_id: i64) -> Result<MessageItem, VkError> {
        let (token, user_id) = self.require_session()?;
        let msg_id = self.api.send_sticker(&token, peer_id, sticker_id).await?;
        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text: String::new(),
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };
        self.storage.upsert_messages(std::slice::from_ref(&msg))?;
        Ok(msg)
    }

    pub async fn send_audio_message_attachment(
        &self,
        peer_id: i64,
        owner_id: i64,
        audio_id: i64,
        text: String,
    ) -> Result<MessageItem, VkError> {
        let (token, user_id) = self.require_session()?;
        let att = format!("audio{owner_id}_{audio_id}");
        let msg_id = self
            .api
            .send_message_with_options(&token, peer_id, text.trim(), None, Some(&att))
            .await?;
        let msg = MessageItem {
            id: msg_id,
            peer_id,
            from_id: user_id,
            text: text.trim().to_string(),
            date: unix_now(),
            is_out: true,
            attachments: Vec::new(),
        };
        Ok(msg)
    }

    pub async fn send_reaction(
        &self,
        peer_id: i64,
        message_id: i64,
        reaction_id: u32,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .send_reaction(&token, peer_id, message_id, reaction_id)
            .await
    }

    pub async fn search_messages(
        &self,
        peer_id: Option<i64>,
        query: String,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .search_messages(&token, peer_id, query.trim(), count)
            .await
    }

    pub async fn get_chat_members(&self, peer_id: i64) -> Result<Vec<ChatMember>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_chat_members(&token, peer_id).await
    }

    pub async fn set_chat_title(&self, peer_id: i64, title: String) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.set_chat_title(&token, peer_id, title.trim()).await
    }

    pub async fn pin_message(&self, peer_id: i64, message_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.pin_message(&token, peer_id, message_id).await
    }

    pub async fn get_user_presence(&self, user_id: i64) -> Result<UserPresence, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_user_presence(&token, user_id).await
    }

    pub fn export_chat_history(&self, peer_id: i64, dest_path: String) -> Result<u32, VkError> {
        let mut msgs = self.storage.get_messages(peer_id, 0, 5000)?;
        msgs.sort_by_key(|m| m.date);
        let mut lines = Vec::with_capacity(msgs.len());
        for m in &msgs {
            let dir = if m.is_out { "Вы" } else { "Собеседник" };
            let body = if m.text.is_empty() {
                "[Вложение]"
            } else {
                m.text.as_str()
            };
            lines.push(format!("[{}] {} ({}): {}", m.date, dir, m.from_id, body));
        }
        std::fs::write(&dest_path, lines.join("\n")).map_err(|err| VkError::Storage {
            details: format!("Failed to export chat to {dest_path}: {err}"),
        })?;
        Ok(msgs.len() as u32)
    }

    // --- Stories, Fave, Polls, Scheduled Posts, Audio, Cleanup ---

    pub async fn get_stories(&self) -> Result<Vec<StoryItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_stories(&token).await
    }

    pub async fn get_fave(&self, count: u32) -> Result<Vec<FaveItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_fave(&token, count).await
    }

    pub async fn fave_add_post(&self, owner_id: i64, post_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.fave_add_post(&token, owner_id, post_id).await
    }

    pub async fn fave_remove_post(&self, owner_id: i64, post_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.fave_remove_post(&token, owner_id, post_id).await
    }

    pub async fn vote_poll(
        &self,
        owner_id: i64,
        poll_id: i64,
        answer_id: i64,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .vote_poll(&token, owner_id, poll_id, answer_id)
            .await
    }

    pub async fn create_post_scheduled(
        &self,
        owner_id: i64,
        message: String,
        publish_date: Option<i64>,
    ) -> Result<i64, VkError> {
        let trimmed = message.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Post text must not be empty".to_string(),
            });
        }
        let (token, self_id) = self.require_session()?;
        let target = if owner_id == 0 { self_id } else { owner_id };
        self.api
            .create_post_scheduled(&token, target, trimmed, publish_date)
            .await
    }

    pub async fn add_audio(&self, owner_id: i64, audio_id: i64) -> Result<i64, VkError> {
        let (token, _) = self.require_session()?;
        self.api.add_audio(&token, owner_id, audio_id).await
    }

    pub async fn delete_audio(&self, owner_id: i64, audio_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.delete_audio(&token, owner_id, audio_id).await
    }

    pub async fn get_audio_recommendations(&self, count: u32) -> Result<Vec<AudioTrack>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_audio_recommendations(&token, count).await
    }

    pub async fn set_audio_broadcast(&self, owner_id: i64, audio_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .set_audio_broadcast(&token, owner_id, audio_id)
            .await
    }

    pub async fn get_inactive_friends(&self) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_inactive_friends(&token).await
    }

    pub async fn get_sticker_packs(&self) -> Result<Vec<StickerPack>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_sticker_packs(&token).await
    }

    pub async fn resolve_screen_name(&self, screen_name: String) -> Result<ResolvedTarget, VkError> {
        let (token, _) = self.require_session()?;
        self.api.resolve_screen_name(&token, &screen_name).await
    }

    pub async fn get_history_attachments(
        &self,
        peer_id: i64,
        media_type: String,
        count: u32,
    ) -> Result<Vec<Attachment>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_history_attachments(&token, peer_id, &media_type, count)
            .await
    }

    pub async fn create_post_with_photo(
        &self,
        owner_id: i64,
        message: String,
        photo_path: Option<String>,
        publish_date: Option<i64>,
    ) -> Result<i64, VkError> {
        let (token, self_id) = self.require_session()?;
        let target = if owner_id == 0 { self_id } else { owner_id };
        let photo_data = match photo_path.filter(|p| !p.trim().is_empty()) {
            Some(path) => {
                let bytes = std::fs::read(&path).map_err(|err| VkError::InvalidInput {
                    details: format!("Cannot read photo {path}: {err}"),
                })?;
                let fname = Path::new(&path)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("photo.jpg")
                    .to_string();
                Some((bytes, fname))
            }
            None => None,
        };
        self.api
            .create_post_with_photo(&token, target, message.trim(), photo_data, publish_date)
            .await
    }

    pub async fn reply_comment(
        &self,
        owner_id: i64,
        post_id: i64,
        reply_to_comment: Option<i64>,
        message: String,
    ) -> Result<i64, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .reply_comment(&token, owner_id, post_id, reply_to_comment, &message)
            .await
    }

    pub async fn like_comment(
        &self,
        owner_id: i64,
        comment_id: i64,
        add: bool,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .like_comment(&token, owner_id, comment_id, add)
            .await
    }

    pub async fn get_audio_lyrics(&self, owner_id: i64, audio_id: i64) -> Result<String, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_audio_lyrics(&token, owner_id, audio_id).await
    }

    pub async fn get_friends_birthdays(&self) -> Result<Vec<BirthdayFriend>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_friends_birthdays(&token).await
    }

    pub async fn get_album_photo_urls(
        &self,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<String>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_album_photo_urls(&token, owner_id, count).await
    }

    pub async fn create_playlist(&self, title: String) -> Result<i64, VkError> {
        let (token, self_id) = self.require_session()?;
        self.api.create_playlist(&token, self_id, &title).await
    }

    pub async fn delete_messages_batch(
        &self,
        peer_id: i64,
        message_ids: Vec<i64>,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .delete_messages_batch(&token, peer_id, &message_ids)
            .await
    }

    pub fn save_snippet(&self, title: String, text: String) -> Result<i64, VkError> {
        self.storage.save_snippet(&title, &text)
    }

    pub fn get_snippets(&self) -> Result<Vec<SnippetItem>, VkError> {
        self.storage.get_snippets()
    }

    pub fn delete_snippet(&self, id: i64) -> Result<(), VkError> {
        self.storage.delete_snippet(id)
    }

    pub fn set_contact_note(&self, peer_id: i64, note: String) -> Result<(), VkError> {
        self.storage.set_contact_note(peer_id, &note)
    }

    pub fn get_contact_note(&self, peer_id: i64) -> Result<String, VkError> {
        self.storage.get_contact_note(peer_id)
    }

    pub fn toggle_watch_online(&self, user_id: i64) -> Result<bool, VkError> {
        self.storage.toggle_watch_online(user_id)
    }

    pub fn get_watched_online(&self) -> Result<Vec<i64>, VkError> {
        self.storage.get_watched_online()
    }

    pub fn get_top_artists(&self, limit: u32) -> Result<Vec<ArtistStat>, VkError> {
        self.storage.get_top_artists(limit)
    }

    pub fn toggle_watch_wall(&self, owner_id: i64) -> Result<bool, VkError> {
        self.storage.toggle_watch_wall(owner_id)
    }

    pub fn get_watched_walls(&self) -> Result<Vec<i64>, VkError> {
        self.storage.get_watched_walls()
    }

    pub async fn add_to_playlist(
        &self,
        owner_id: i64,
        playlist_id: i64,
        audio_owner_id: i64,
        audio_id: i64,
    ) -> Result<(), VkError> {
        let (token, self_id) = self.require_session()?;
        let target_owner = if owner_id == 0 { self_id } else { owner_id };
        self.api
            .add_to_playlist(&token, target_owner, playlist_id, audio_owner_id, audio_id)
            .await
    }

    pub async fn get_banned(&self) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_banned(&token).await
    }

    pub async fn ban_user(&self, owner_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.ban_user(&token, owner_id).await
    }

    pub async fn unban_user(&self, owner_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.unban_user(&token, owner_id).await
    }

    pub async fn get_friend_requests(&self) -> Result<Vec<FriendRequestItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_friend_requests(&token).await
    }

    pub async fn accept_friend(&self, user_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.accept_friend(&token, user_id).await
    }

    pub async fn decline_friend(&self, user_id: i64) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.decline_friend(&token, user_id).await
    }

    pub async fn set_status(&self, text: String) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api.set_status(&token, &text).await
    }

    pub async fn get_media_comments(
        &self,
        is_video: bool,
        owner_id: i64,
        item_id: i64,
    ) -> Result<Vec<CommentItem>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_media_comments(&token, is_video, owner_id, item_id)
            .await
    }

    pub async fn create_media_comment(
        &self,
        is_video: bool,
        owner_id: i64,
        item_id: i64,
        message: String,
    ) -> Result<i64, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .create_media_comment(&token, is_video, owner_id, item_id, &message)
            .await
    }

    pub fn save_account_metadata(&self, user_id: i64, name: String, avatar_url: Option<String>) -> Result<(), VkError> {
        self.storage.upsert_saved_account(user_id, &name, avatar_url.as_deref())
    }

    pub fn get_saved_accounts(&self) -> Result<Vec<AccountSummary>, VkError> {
        let ids = self.auth.list_account_ids()?;
        let stored = self.storage.get_saved_accounts()?;
        let mut out = Vec::new();
        for id in ids {
            if let Some(found) = stored.iter().find(|a| a.user_id == id) {
                out.push(found.clone());
            } else {
                out.push(AccountSummary {
                    user_id: id,
                    name: format!("id{id}"),
                    avatar_url: None,
                });
            }
        }
        Ok(out)
    }

    pub async fn switch_account(&self, user_id: i64) -> Result<AuthState, VkError> {
        if let Some((token, _)) = self.auth.switch_account(user_id)? {
            return self.login_with_token(token).await;
        }
        Ok(AuthState::LoggedOut)
    }

    pub fn remove_saved_account(&self, user_id: i64) -> Result<(), VkError> {
        self.auth.remove_account(user_id)?;
        self.storage.remove_saved_account(user_id)?;
        Ok(())
    }

    pub fn toggle_archive_conversation(&self, peer_id: i64) -> Result<bool, VkError> {
        self.storage.toggle_archive_conversation(peer_id)
    }

    pub fn get_archived_peers(&self) -> Result<Vec<i64>, VkError> {
        self.storage.get_archived_peers()
    }

    pub fn get_chat_stats(&self, peer_id: i64) -> Result<ChatStats, VkError> {
        self.storage.get_chat_stats(peer_id)
    }

    pub async fn ignore_newsfeed_item(
        &self,
        owner_id: i64,
        post_id: i64,
    ) -> Result<(), VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .ignore_newsfeed_item(&token, owner_id, post_id)
            .await
    }

    pub async fn get_fave_pages(&self) -> Result<Vec<OwnerSummary>, VkError> {
        let (token, _) = self.require_session()?;
        self.api.get_fave_pages(&token).await
    }

    pub async fn send_wall_to_peer(
        &self,
        peer_id: i64,
        owner_id: i64,
        post_id: i64,
    ) -> Result<i64, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .send_wall_to_peer(&token, peer_id, owner_id, post_id)
            .await
    }

    pub async fn get_similar_audio(
        &self,
        owner_id: i64,
        audio_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let (token, _) = self.require_session()?;
        self.api
            .get_similar_audio(&token, owner_id, audio_id, count)
            .await
    }
}

fn init_runtime() -> Result<(tokio::runtime::Handle, Option<tokio::runtime::Runtime>), VkError> {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => Ok((handle, None)),
        Err(_) => {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(2)
                .thread_name("vk-core-tokio")
                .build()
                .map_err(|err| VkError::Internal {
                    details: format!("Failed to create Tokio runtime: {err}"),
                })?;
            let handle = rt.handle().clone();
            Ok((handle, Some(rt)))
        }
    }
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}
