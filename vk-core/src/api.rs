use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::header::USER_AGENT;
use reqwest::StatusCode;
use serde::de::{self, Deserializer, Visitor};
use serde::Deserialize;

use crate::config::{api_base_url, DEFAULT_API_BASE_URL, VK_API_VERSION};
use crate::error::VkError;
use crate::models::{
    Attachment, AudioPlaylist, AudioTrack, BirthdayFriend, BotKeyboard, BotKeyboardButton,
    BotKeyboardRow, ChatMember, CommentItem, ConversationItem, FaveItem, FeedPost,
    FriendRequestItem, MessageItem, NewsfeedPage, NotificationItem, OwnerPage, OwnerSummary,
    PollAnswer, ResolvedTarget, StickerItem, StickerPack, StoryItem, UserPresence, UserProfile,
    VideoItem, VideoQualityOption,
};

pub const VK_USER_AGENT: &str =
    "VKAndroidApp/8.44-18440 (Android 13; SDK 33; arm64-v8a; Pixel 7; ru)";
pub const DEFAULT_RATE_LIMIT_MAX_REQUESTS: usize = 3;
pub const DEFAULT_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(1);

static RANDOM_ID_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug)]
pub struct RateLimiter {
    max_requests: usize,
    window: Duration,
    timestamps: tokio::sync::Mutex<VecDeque<tokio::time::Instant>>,
}

impl RateLimiter {
    pub fn new(max_requests: usize, window: Duration) -> Self {
        assert!(max_requests > 0, "max_requests must be > 0");
        Self {
            max_requests,
            window,
            timestamps: tokio::sync::Mutex::new(VecDeque::with_capacity(max_requests)),
        }
    }

    pub async fn acquire(&self) {
        let mut guard = self.timestamps.lock().await;
        loop {
            let now = tokio::time::Instant::now();
            while let Some(&front) = guard.front() {
                if now.saturating_duration_since(front) >= self.window {
                    guard.pop_front();
                } else {
                    break;
                }
            }

            if guard.len() < self.max_requests {
                guard.push_back(now);
                return;
            }

            let earliest = *guard.front().expect("timestamps non-empty when full");
            let wake_at = earliest + self.window;
            tokio::time::sleep_until(wake_at).await;
        }
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new(DEFAULT_RATE_LIMIT_MAX_REQUESTS, DEFAULT_RATE_LIMIT_WINDOW)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationsPage {
    pub items: Vec<ConversationItem>,
    pub profiles: Vec<UserProfile>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagesPage {
    pub items: Vec<MessageItem>,
    pub profiles: Vec<UserProfile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LongPollServerInfo {
    pub key: String,
    pub server: String,
    #[serde(deserialize_with = "deserialize_u64_from_int_or_str")]
    pub ts: u64,
}

pub struct VkApiClient {
    http: reqwest::Client,
    base_url: String,
    rate_limiter: RateLimiter,
}

impl VkApiClient {
    pub fn new() -> Result<Self, VkError> {
        let http = default_http_client()?;
        Ok(Self::with_client(http, api_base_url()))
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Result<Self, VkError> {
        let http = default_http_client()?;
        Ok(Self::with_client(http, base_url))
    }

    pub fn with_client(http: reqwest::Client, base_url: impl Into<String>) -> Self {
        Self {
            http,
            base_url: normalize_base_url(&base_url.into()),
            rate_limiter: RateLimiter::default(),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub async fn get_users(
        &self,
        token: &str,
        user_ids: &[i64],
    ) -> Result<Vec<UserProfile>, VkError> {
        let mut params = vec![(
            "fields".to_string(),
            "photo_100,photo_200,online".to_string(),
        )];
        if !user_ids.is_empty() {
            let joined = user_ids
                .iter()
                .map(i64::to_string)
                .collect::<Vec<_>>()
                .join(",");
            params.push(("user_ids".to_string(), joined));
        }

        let raw: Vec<RawUser> = self.call_method("users.get", token, params).await?;
        Ok(raw.into_iter().map(RawUser::into_profile).collect())
    }

    pub async fn get_current_user(&self, token: &str) -> Result<Option<UserProfile>, VkError> {
        let users = self.get_users(token, &[]).await?;
        Ok(users.into_iter().next())
    }

    pub async fn get_conversations(
        &self,
        token: &str,
        offset: u32,
        count: u32,
    ) -> Result<Vec<ConversationItem>, VkError> {
        Ok(self
            .get_conversations_with_profiles(token, offset, count)
            .await?
            .items)
    }

    pub async fn get_conversations_with_profiles(
        &self,
        token: &str,
        offset: u32,
        count: u32,
    ) -> Result<ConversationsPage, VkError> {
        if count == 0 {
            return Ok(ConversationsPage {
                items: Vec::new(),
                profiles: Vec::new(),
            });
        }

        let clamped_count = count.clamp(1, 200);
        let params = vec![
            ("offset".to_string(), offset.to_string()),
            ("count".to_string(), clamped_count.to_string()),
            ("extended".to_string(), "1".to_string()),
            (
                "fields".to_string(),
                "photo_100,photo_200,online".to_string(),
            ),
        ];

        let raw: RawConversationsResponse = self
            .call_method("messages.getConversations", token, params)
            .await?;

        let profiles: Vec<UserProfile> =
            raw.profiles.into_iter().map(RawUser::into_profile).collect();
        let profile_map: HashMap<i64, &UserProfile> =
            profiles.iter().map(|u| (u.id, u)).collect();
        let group_map: HashMap<i64, RawGroup> =
            raw.groups.into_iter().map(|g| (g.id, g)).collect();

        let mut items = Vec::with_capacity(raw.items.len());
        for entry in raw.items {
            let conv = entry.conversation;
            let peer_id = conv.peer.id;
            let peer_kind = conv.peer.kind.as_deref().unwrap_or("");

            let (title, avatar_url) = if peer_id >= 2_000_000_000 || peer_kind == "chat" {
                let chat_title = conv
                    .chat_settings
                    .as_ref()
                    .and_then(|c| non_empty(c.title.clone()))
                    .unwrap_or_else(|| format!("Chat {}", peer_id.saturating_sub(2_000_000_000)));
                let chat_avatar = conv
                    .chat_settings
                    .as_ref()
                    .and_then(|c| c.photo.as_ref())
                    .and_then(RawPhotoSet::best_url);
                (chat_title, chat_avatar)
            } else if peer_id < 0 || peer_kind == "group" {
                let gid = peer_id.abs();
                if let Some(group) = group_map.get(&gid) {
                    let gname = non_empty(Some(group.name.clone()))
                        .unwrap_or_else(|| format!("Group {gid}"));
                    (gname, group.best_avatar())
                } else {
                    (format!("Group {gid}"), None)
                }
            } else if let Some(user) = profile_map.get(&peer_id) {
                let full_name = format!("{} {}", user.first_name, user.last_name)
                    .trim()
                    .to_string();
                let title = if full_name.is_empty() {
                    format!("User {peer_id}")
                } else {
                    full_name
                };
                (title, user.avatar_url.clone())
            } else {
                (format!("User {peer_id}"), None)
            };

            let is_muted = conv.push_settings.as_ref().is_some_and(|p| {
                p.disabled_forever
                    || p.no_sound
                    || matches!(p.disabled_until, Some(until) if until == -1 || until > 0)
            });

            let (last_message_text, last_message_date) = match entry.last_message {
                Some(last_msg) => {
                    let attachments: Vec<Attachment> = last_msg
                        .attachments
                        .into_iter()
                        .filter_map(parse_attachment)
                        .collect();
                    let preview = message_preview_from_parts(&last_msg.text, &attachments);
                    (preview, last_msg.date)
                }
                None => (String::new(), 0),
            };

            items.push(ConversationItem {
                peer_id,
                title,
                avatar_url,
                last_message_text,
                last_message_date,
                unread_count: conv.unread_count,
                is_muted,
            });
        }

        Ok(ConversationsPage { items, profiles })
    }

    pub async fn get_history(
        &self,
        token: &str,
        peer_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        Ok(self
            .get_history_with_profiles(token, peer_id, offset, count)
            .await?
            .items)
    }

    pub async fn get_conversation_keyboard(
        &self,
        token: &str,
        peer_id: i64,
    ) -> Result<Option<BotKeyboard>, VkError> {
        let params = vec![("peer_ids".to_string(), peer_id.to_string())];
        let raw: RawConversationsByIdResponse = self
            .call_method("messages.getConversationsById", token, params)
            .await?;
        Ok(raw
            .items
            .into_iter()
            .next()
            .and_then(|c| c.current_keyboard)
            .and_then(parse_bot_keyboard_data))
    }

    pub async fn get_history_with_profiles(
        &self,
        token: &str,
        peer_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<MessagesPage, VkError> {
        if count == 0 {
            return Ok(MessagesPage {
                items: Vec::new(),
                profiles: Vec::new(),
            });
        }

        let clamped_count = count.clamp(1, 200);
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("offset".to_string(), offset.to_string()),
            ("count".to_string(), clamped_count.to_string()),
            ("extended".to_string(), "1".to_string()),
            (
                "fields".to_string(),
                "photo_100,photo_200,online".to_string(),
            ),
        ];

        let raw: RawHistoryResponse = self
            .call_method("messages.getHistory", token, params)
            .await?;

        let profiles: Vec<UserProfile> =
            raw.profiles.into_iter().map(RawUser::into_profile).collect();
        let items = raw
            .items
            .into_iter()
            .map(|msg| {
                let mut attachments: Vec<Attachment> = msg
                    .attachments
                    .into_iter()
                    .filter_map(parse_attachment)
                    .collect();
                if let Some(reply) = msg.reply_message {
                    let preview = if !reply.text.trim().is_empty() {
                        reply.text
                    } else {
                        "[Вложение]".to_string()
                    };
                    attachments.insert(
                        0,
                        Attachment::Reply {
                            message_id: reply.id,
                            text: preview,
                        },
                    );
                }
                for fwd in msg.fwd_messages.into_iter().take(5) {
                    let from_name = if fwd.from_id > 0 {
                        format!("id{}", fwd.from_id)
                    } else {
                        format!("club{}", -fwd.from_id)
                    };
                    let text = if !fwd.text.trim().is_empty() {
                        fwd.text
                    } else {
                        "[Вложение]".to_string()
                    };
                    attachments.push(Attachment::Forwarded {
                        from_name,
                        text,
                        date: fwd.date,
                    });
                }
                if let Some(kb) = msg.keyboard.and_then(parse_bot_keyboard) {
                    attachments.push(kb);
                }
                MessageItem {
                    id: msg.id,
                    peer_id: msg.peer_id.unwrap_or(peer_id),
                    from_id: msg.from_id,
                    text: msg.text,
                    date: msg.date,
                    is_out: msg.out,
                    attachments,
                }
            })
            .collect();

        Ok(MessagesPage { items, profiles })
    }

    pub async fn send_message(
        &self,
        token: &str,
        peer_id: i64,
        text: &str,
    ) -> Result<i64, VkError> {
        self.send_message_with_payload(token, peer_id, text, None)
            .await
    }

    pub async fn send_message_with_payload(
        &self,
        token: &str,
        peer_id: i64,
        text: &str,
        payload: Option<&str>,
    ) -> Result<i64, VkError> {
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

        let random_id = next_random_id();
        let mut params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("message".to_string(), text.to_string()),
            ("random_id".to_string(), random_id.to_string()),
        ];
        if let Some(p) = payload {
            let trimmed = p.trim();
            if !trimmed.is_empty() {
                params.push(("payload".to_string(), trimmed.to_string()));
            }
        }

        self.call_method("messages.send", token, params).await
    }

    pub async fn get_newsfeed(
        &self,
        token: &str,
        start_from: Option<&str>,
        count: u32,
    ) -> Result<NewsfeedPage, VkError> {
        let clamped_count = count.clamp(1, 100);
        let mut params = vec![
            ("filters".to_string(), "post".to_string()),
            ("count".to_string(), clamped_count.to_string()),
        ];
        if let Some(start) = start_from.map(str::trim).filter(|s| !s.is_empty()) {
            params.push(("start_from".to_string(), start.to_string()));
        }

        let raw: RawNewsfeedResponse = self.call_method("newsfeed.get", token, params).await?;
        let posts = map_post_items(raw.items, raw.profiles, raw.groups);

        Ok(NewsfeedPage {
            items: posts,
            next_from: non_empty(raw.next_from),
        })
    }

    pub async fn get_owner_page(
        &self,
        token: &str,
        owner_id: i64,
        wall_count: u32,
    ) -> Result<OwnerPage, VkError> {
        if owner_id == 0 {
            return Err(VkError::InvalidInput {
                details: "owner_id must not be 0".to_string(),
            });
        }

        let clamped_wall = wall_count.clamp(1, 50);
        let wall_params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("count".to_string(), clamped_wall.to_string()),
            ("extended".to_string(), "1".to_string()),
        ];

        let (mut page, wall_res) = if owner_id > 0 {
            let user_params = vec![
                ("user_ids".to_string(), owner_id.to_string()),
                (
                    "fields".to_string(),
                    "photo_200,photo_max_orig,online,status,about,city,site,followers_count,counters,verified,screen_name,is_friend,can_post"
                        .to_string(),
                ),
            ];
            let (users, wall) = tokio::join!(
                self.call_method::<Vec<RawOwnerUser>>("users.get", token, user_params),
                self.call_method::<RawWallResponse>("wall.get", token, wall_params),
            );
            let users = users?;
            let user = users.into_iter().next().ok_or_else(|| VkError::ApiError {
                code: 113,
                message: format!("User {owner_id} not found"),
            })?;
            (user.into_owner_page(), wall)
        } else {
            let group_id = owner_id.abs();
            let group_params = vec![
                ("group_id".to_string(), group_id.to_string()),
                (
                    "fields".to_string(),
                    "photo_200,cover,status,description,members_count,city,site,verified,screen_name,is_member,can_post"
                        .to_string(),
                ),
            ];
            let (groups, wall) = tokio::join!(
                self.call_method::<RawGroupsByIdResponse>("groups.getById", token, group_params),
                self.call_method::<RawWallResponse>("wall.get", token, wall_params),
            );
            let group = groups?
                .into_vec()
                .into_iter()
                .next()
                .ok_or_else(|| VkError::ApiError {
                    code: 100,
                    message: format!("Group {group_id} not found"),
                })?;
            (group.into_owner_page(), wall)
        };

        // Closed/private walls may return API error 15/18/30; still return the profile/group header.
        if let Ok(raw_wall) = wall_res {
            page.wall_posts = map_post_items(raw_wall.items, raw_wall.profiles, raw_wall.groups);
        }

        Ok(page)
    }

    pub async fn get_friends(&self, token: &str, count: u32) -> Result<Vec<OwnerSummary>, VkError> {
        self.get_user_friends(token, None, count).await
    }

    pub async fn get_user_friends(
        &self,
        token: &str,
        user_id: Option<i64>,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let clamped = count.clamp(1, 500);
        let mut params = vec![
            ("order".to_string(), "hints".to_string()),
            ("count".to_string(), clamped.to_string()),
            (
                "fields".to_string(),
                "photo_200,online,status,verified,screen_name".to_string(),
            ),
        ];
        if let Some(uid) = user_id.filter(|&id| id > 0) {
            params.push(("user_id".to_string(), uid.to_string()));
        }
        let raw: RawFriendsListResponse = self.call_method("friends.get", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn get_followers(
        &self,
        token: &str,
        user_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let clamped = count.clamp(1, 500);
        let params = vec![
            ("user_id".to_string(), user_id.to_string()),
            ("count".to_string(), clamped.to_string()),
            (
                "fields".to_string(),
                "photo_200,online,status,verified,screen_name".to_string(),
            ),
        ];
        let raw: RawFriendsListResponse = self
            .call_method("users.getFollowers", token, params)
            .await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn get_group_members(
        &self,
        token: &str,
        group_id: i64,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let clamped = count.clamp(1, 500);
        let params = vec![
            ("group_id".to_string(), group_id.abs().to_string()),
            ("count".to_string(), clamped.to_string()),
            (
                "fields".to_string(),
                "photo_200,online,status,verified,screen_name".to_string(),
            ),
        ];
        let raw: RawFriendsListResponse = self
            .call_method("groups.getMembers", token, params)
            .await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn get_groups(&self, token: &str, count: u32) -> Result<Vec<OwnerSummary>, VkError> {
        self.get_user_groups(token, None, count).await
    }

    pub async fn get_user_groups(
        &self,
        token: &str,
        user_id: Option<i64>,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let clamped = count.clamp(1, 500);
        let mut params = vec![
            ("extended".to_string(), "1".to_string()),
            ("count".to_string(), clamped.to_string()),
            (
                "fields".to_string(),
                "photo_200,members_count,status,verified,screen_name".to_string(),
            ),
        ];
        if let Some(uid) = user_id.filter(|&id| id > 0) {
            params.push(("user_id".to_string(), uid.to_string()));
        }
        let raw: RawGroupsListResponse = self.call_method("groups.get", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerGroup::into_summary)
            .collect())
    }

    pub async fn get_owner_photos(
        &self,
        token: &str,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<String>, VkError> {
        let clamped = count.clamp(1, 200);
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("count".to_string(), clamped.to_string()),
            ("photo_sizes".to_string(), "1".to_string()),
        ];
        let raw: RawPhotosListResponse = self.call_method("photos.getAll", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .filter_map(|p| extract_max_photo(&p).0)
            .collect())
    }

    pub async fn get_owner_audio(
        &self,
        token: &str,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let clamped = count.clamp(1, 200);
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("count".to_string(), clamped.to_string()),
        ];
        let raw: RawAudioListResponse = self.call_method("audio.get", token, params).await?;
        Ok(raw.items.into_iter().map(RawAudio::into_track).collect())
    }

    pub async fn like_post(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
    ) -> Result<u32, VkError> {
        let params = vec![
            ("type".to_string(), "post".to_string()),
            ("owner_id".to_string(), owner_id.to_string()),
            ("item_id".to_string(), post_id.to_string()),
        ];
        let raw: RawLikesResponse = self.call_method("likes.add", token, params).await?;
        Ok(raw.likes)
    }

    pub async fn unlike_post(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
    ) -> Result<u32, VkError> {
        let params = vec![
            ("type".to_string(), "post".to_string()),
            ("owner_id".to_string(), owner_id.to_string()),
            ("item_id".to_string(), post_id.to_string()),
        ];
        let raw: RawLikesResponse = self.call_method("likes.delete", token, params).await?;
        Ok(raw.likes)
    }

    pub async fn get_post_comments(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
        offset: u32,
        count: u32,
    ) -> Result<Vec<CommentItem>, VkError> {
        let clamped = count.clamp(1, 100);
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("post_id".to_string(), post_id.to_string()),
            ("offset".to_string(), offset.to_string()),
            ("count".to_string(), clamped.to_string()),
            ("need_likes".to_string(), "1".to_string()),
            ("extended".to_string(), "1".to_string()),
        ];
        let raw: RawCommentsListResponse =
            self.call_method("wall.getComments", token, params).await?;
        let profiles: HashMap<i64, UserProfile> = raw
            .profiles
            .into_iter()
            .map(RawUser::into_profile)
            .map(|u| (u.id, u))
            .collect();
        let groups: HashMap<i64, RawGroup> = raw.groups.into_iter().map(|g| (g.id, g)).collect();

        Ok(raw
            .items
            .into_iter()
            .map(|c| {
                let (author_name, author_avatar) = resolve_author(c.from_id, &profiles, &groups);
                CommentItem {
                    id: c.id,
                    from_id: c.from_id,
                    author_name,
                    author_avatar,
                    date: c.date,
                    text: c.text,
                    likes_count: c.likes.as_ref().map_or(0, |l| l.count),
                    is_liked: c.likes.as_ref().is_some_and(|l| l.user_likes),
                }
            })
            .collect())
    }

    pub async fn create_comment(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
        message: &str,
    ) -> Result<i64, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("post_id".to_string(), post_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        let raw: RawCreateCommentResponse =
            self.call_method("wall.createComment", token, params).await?;
        Ok(raw.comment_id)
    }

    pub async fn create_post(
        &self,
        token: &str,
        owner_id: i64,
        message: &str,
    ) -> Result<i64, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        let raw: RawWallPostResponse = self.call_method("wall.post", token, params).await?;
        Ok(raw.post_id)
    }

    pub async fn repost_post(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
        message: Option<&str>,
    ) -> Result<(), VkError> {
        let mut params = vec![("object".to_string(), format!("wall{owner_id}_{post_id}"))];
        if let Some(msg) = message.map(str::trim).filter(|s| !s.is_empty()) {
            params.push(("message".to_string(), msg.to_string()));
        }
        let _: serde_json::Value = self.call_method("wall.repost", token, params).await?;
        Ok(())
    }

    pub async fn add_friend(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        let params = vec![("user_id".to_string(), user_id.to_string())];
        let _: serde_json::Value = self.call_method("friends.add", token, params).await?;
        Ok(())
    }

    pub async fn remove_friend(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        let params = vec![("user_id".to_string(), user_id.to_string())];
        let _: serde_json::Value = self.call_method("friends.delete", token, params).await?;
        Ok(())
    }

    pub async fn join_group(&self, token: &str, group_id: i64) -> Result<(), VkError> {
        let params = vec![("group_id".to_string(), group_id.abs().to_string())];
        let _: serde_json::Value = self.call_method("groups.join", token, params).await?;
        Ok(())
    }

    pub async fn leave_group(&self, token: &str, group_id: i64) -> Result<(), VkError> {
        let params = vec![("group_id".to_string(), group_id.abs().to_string())];
        let _: serde_json::Value = self.call_method("groups.leave", token, params).await?;
        Ok(())
    }

    pub async fn get_notifications(
        &self,
        token: &str,
        count: u32,
    ) -> Result<Vec<NotificationItem>, VkError> {
        let params = vec![("count".to_string(), count.clamp(1, 100).to_string())];
        let raw: RawNotificationsResponse =
            self.call_method("notifications.get", token, params).await?;
        let profiles: HashMap<i64, UserProfile> = raw
            .profiles
            .into_iter()
            .map(RawUser::into_profile)
            .map(|u| (u.id, u))
            .collect();
        let groups: HashMap<i64, RawGroup> = raw.groups.into_iter().map(|g| (g.id, g)).collect();

        let mut items = Vec::with_capacity(raw.items.len());
        for n in raw.items {
            let kind = n.extract_kind();
            let date = n.extract_date();
            let actor_id = n.extract_actor_id();
            let (mut actor_name, mut actor_avatar) = if actor_id != 0 {
                resolve_author(actor_id, &profiles, &groups)
            } else {
                ("ВКонтакте".to_string(), None)
            };
            let (target_owner_id, target_post_id, text) = n.extract_target_and_text();
            if actor_id == 0 {
                if let Some(title) = n.extract_header_title() {
                    actor_name = title;
                }
            }
            if actor_avatar.is_none() {
                actor_avatar = n.extract_image_url();
            }
            items.push(NotificationItem {
                kind,
                date,
                actor_id,
                actor_name,
                actor_avatar,
                text,
                target_owner_id,
                target_post_id,
            });
        }
        Ok(items)
    }

    pub async fn get_videos(
        &self,
        token: &str,
        owner_id: Option<i64>,
        count: u32,
    ) -> Result<Vec<VideoItem>, VkError> {
        let mut params = vec![("count".to_string(), count.clamp(1, 100).to_string())];
        if let Some(oid) = owner_id {
            params.push(("owner_id".to_string(), oid.to_string()));
        }
        let raw: RawVideoListResponse = self.call_method("video.get", token, params).await?;
        Ok(raw.items.into_iter().map(RawVideo::into_video_item).collect())
    }

    pub async fn search_videos(
        &self,
        token: &str,
        query: &str,
        count: u32,
    ) -> Result<Vec<VideoItem>, VkError> {
        let params = vec![
            ("q".to_string(), query.to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
        ];
        let raw: RawVideoListResponse = self.call_method("video.search", token, params).await?;
        Ok(raw.items.into_iter().map(RawVideo::into_video_item).collect())
    }

    pub async fn resolve_video(
        &self,
        token: &str,
        owner_id: i64,
        video_id: i64,
        access_key: Option<&str>,
    ) -> Result<VideoItem, VkError> {
        let spec = match access_key.map(str::trim).filter(|s| !s.is_empty()) {
            Some(key) => format!("{owner_id}_{video_id}_{key}"),
            None => format!("{owner_id}_{video_id}"),
        };
        let params = vec![("videos".to_string(), spec)];
        let raw: RawVideoListResponse = self.call_method("video.get", token, params).await?;
        raw.items
            .into_iter()
            .next()
            .map(RawVideo::into_video_item)
            .ok_or_else(|| VkError::ApiError {
                code: 100,
                message: format!("Video {owner_id}_{video_id} not found"),
            })
    }

    pub async fn search_users(
        &self,
        token: &str,
        query: &str,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let params = vec![
            ("q".to_string(), query.to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
            (
                "fields".to_string(),
                "photo_200,online,status,verified,screen_name".to_string(),
            ),
        ];
        let raw: RawFriendsListResponse = self.call_method("users.search", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn search_groups(
        &self,
        token: &str,
        query: &str,
        count: u32,
    ) -> Result<Vec<OwnerSummary>, VkError> {
        let params = vec![
            ("q".to_string(), query.to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
            (
                "fields".to_string(),
                "photo_200,members_count,status,verified,screen_name".to_string(),
            ),
        ];
        let raw: RawGroupsListResponse = self.call_method("groups.search", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawOwnerGroup::into_summary)
            .collect())
    }

    pub async fn get_audio_playlists(
        &self,
        token: &str,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<AudioPlaylist>, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
        ];
        let raw: RawAudioPlaylistsResponse =
            self.call_method("audio.getPlaylists", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawAudioPlaylist::into_playlist)
            .collect())
    }

    pub async fn get_playlist_audio(
        &self,
        token: &str,
        owner_id: i64,
        album_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("album_id".to_string(), album_id.to_string()),
            ("count".to_string(), count.clamp(1, 200).to_string()),
        ];
        let raw: RawAudioListResponse = self.call_method("audio.get", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .map(RawAudio::into_track)
            .collect())
    }

    pub async fn send_message_with_options(
        &self,
        token: &str,
        peer_id: i64,
        text: &str,
        reply_to: Option<i64>,
        attachment: Option<&str>,
    ) -> Result<i64, VkError> {
        let random_id = next_random_id();
        let mut params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("random_id".to_string(), random_id.to_string()),
            ("message".to_string(), text.to_string()),
        ];
        if let Some(reply_id) = reply_to {
            params.push(("reply_to".to_string(), reply_id.to_string()));
        }
        if let Some(att) = attachment.map(str::trim).filter(|s| !s.is_empty()) {
            params.push(("attachment".to_string(), att.to_string()));
        }
        self.call_method("messages.send", token, params).await
    }

    pub async fn delete_message(&self, token: &str, message_id: i64) -> Result<(), VkError> {
        let params = vec![
            ("message_ids".to_string(), message_id.to_string()),
            ("delete_for_all".to_string(), "1".to_string()),
        ];
        let _: serde_json::Value = self.call_method("messages.delete", token, params).await?;
        Ok(())
    }

    pub async fn edit_message(
        &self,
        token: &str,
        peer_id: i64,
        message_id: i64,
        text: &str,
    ) -> Result<(), VkError> {
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("message_id".to_string(), message_id.to_string()),
            ("message".to_string(), text.to_string()),
        ];
        let _: serde_json::Value = self.call_method("messages.edit", token, params).await?;
        Ok(())
    }

    pub async fn mark_as_read(&self, token: &str, peer_id: i64) -> Result<(), VkError> {
        let params = vec![("peer_id".to_string(), peer_id.to_string())];
        let _: serde_json::Value = self.call_method("messages.markAsRead", token, params).await?;
        Ok(())
    }

    pub async fn upload_message_photo(
        &self,
        token: &str,
        peer_id: i64,
        file_bytes: Vec<u8>,
        filename: &str,
    ) -> Result<String, VkError> {
        let server: RawUploadServerResponse = self
            .call_method(
                "photos.getMessagesUploadServer",
                token,
                vec![("peer_id".to_string(), peer_id.to_string())],
            )
            .await?;

        let part = reqwest::multipart::Part::bytes(file_bytes).file_name(filename.to_string());
        let form = reqwest::multipart::Form::new().part("photo", part);
        let upload_resp: RawPhotoUploadResponse = self
            .http
            .post(&server.upload_url)
            .header(USER_AGENT, VK_USER_AGENT)
            .multipart(form)
            .send()
            .await?
            .json()
            .await?;

        let saved: Vec<RawSavedPhoto> = self
            .call_method(
                "photos.saveMessagesPhoto",
                token,
                vec![
                    ("photo".to_string(), upload_resp.photo),
                    ("server".to_string(), upload_resp.server.to_string()),
                    ("hash".to_string(), upload_resp.hash),
                ],
            )
            .await?;

        let first = saved.into_iter().next().ok_or_else(|| VkError::Internal {
            details: "photos.saveMessagesPhoto returned empty list".to_string(),
        })?;
        Ok(format!("photo{}_{}", first.owner_id, first.id))
    }

    pub async fn upload_message_doc(
        &self,
        token: &str,
        peer_id: i64,
        file_bytes: Vec<u8>,
        filename: &str,
        is_audio_message: bool,
    ) -> Result<String, VkError> {
        let (upload_bytes, upload_filename) = if is_audio_message && file_bytes.starts_with(b"RIFF") {
            let mp3 = encode_wav_to_mp3(&file_bytes)?;
            (mp3, "voice.mp3".to_string())
        } else {
            (file_bytes, filename.to_string())
        };

        let doc_type = if is_audio_message {
            "audio_message"
        } else {
            "doc"
        };
        let server: RawUploadServerResponse = self
            .call_method(
                "docs.getMessagesUploadServer",
                token,
                vec![
                    ("peer_id".to_string(), peer_id.to_string()),
                    ("type".to_string(), doc_type.to_string()),
                ],
            )
            .await?;

        let part = reqwest::multipart::Part::bytes(upload_bytes).file_name(upload_filename.clone());
        let form = reqwest::multipart::Form::new().part("file", part);
        let resp_text = self
            .http
            .post(&server.upload_url)
            .header(USER_AGENT, VK_USER_AGENT)
            .multipart(form)
            .send()
            .await?
            .text()
            .await?;
        let upload_resp: RawDocUploadResponse = serde_json::from_str(&resp_text).map_err(|err| {
            VkError::Internal {
                details: format!("Upload response decode error ({err}): {resp_text}"),
            }
        })?;
        let file_token = upload_resp.file.ok_or_else(|| VkError::Internal {
            details: format!(
                "Upload failed: {}",
                upload_resp.error.unwrap_or_else(|| resp_text.clone())
            ),
        })?;

        let saved: RawDocSaveResponse = self
            .call_method(
                "docs.save",
                token,
                vec![
                    ("file".to_string(), file_token),
                    ("title".to_string(), upload_filename),
                ],
            )
            .await?;

        if let Some(doc) = saved.audio_message.or(saved.doc) {
            Ok(format!("doc{}_{}", doc.owner_id, doc.id))
        } else {
            Err(VkError::Internal {
                details: "docs.save returned no doc or audio_message".to_string(),
            })
        }
    }

    pub async fn forward_messages(
        &self,
        token: &str,
        peer_id: i64,
        message_ids: &[i64],
        text: &str,
    ) -> Result<i64, VkError> {
        let random_id = next_random_id();
        let fwd_csv = message_ids
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("random_id".to_string(), random_id.to_string()),
            ("message".to_string(), text.to_string()),
            ("forward_messages".to_string(), fwd_csv),
        ];
        self.call_method("messages.send", token, params).await
    }

    pub async fn send_sticker(
        &self,
        token: &str,
        peer_id: i64,
        sticker_id: i64,
    ) -> Result<i64, VkError> {
        let random_id = next_random_id();
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("random_id".to_string(), random_id.to_string()),
            ("sticker_id".to_string(), sticker_id.to_string()),
        ];
        self.call_method("messages.send", token, params).await
    }

    pub async fn send_reaction(
        &self,
        token: &str,
        peer_id: i64,
        cmid: i64,
        reaction_id: u32,
    ) -> Result<(), VkError> {
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("cmid".to_string(), cmid.to_string()),
            ("reaction_id".to_string(), reaction_id.to_string()),
        ];
        let _: serde_json::Value = self
            .call_method("messages.sendReaction", token, params)
            .await?;
        Ok(())
    }

    pub async fn search_messages(
        &self,
        token: &str,
        peer_id: Option<i64>,
        query: &str,
        count: u32,
    ) -> Result<Vec<MessageItem>, VkError> {
        let mut params = vec![
            ("q".to_string(), query.to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
        ];
        if let Some(pid) = peer_id.filter(|&p| p != 0) {
            params.push(("peer_id".to_string(), pid.to_string()));
        }
        let raw: RawHistoryResponse = self.call_method("messages.search", token, params).await?;
        let fallback_peer = peer_id.unwrap_or(0);
        Ok(raw
            .items
            .into_iter()
            .map(|msg| MessageItem {
                id: msg.id,
                peer_id: msg.peer_id.unwrap_or(fallback_peer),
                from_id: msg.from_id,
                text: msg.text,
                date: msg.date,
                is_out: msg.out,
                attachments: msg
                    .attachments
                    .into_iter()
                    .filter_map(parse_attachment)
                    .collect(),
            })
            .collect())
    }

    pub async fn get_chat_members(
        &self,
        token: &str,
        peer_id: i64,
    ) -> Result<Vec<ChatMember>, VkError> {
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("fields".to_string(), "photo_200,online".to_string()),
        ];
        let raw: RawChatMembersResponse = self
            .call_method("messages.getConversationMembers", token, params)
            .await?;
        let profiles: HashMap<i64, UserProfile> = raw
            .profiles
            .into_iter()
            .map(RawUser::into_profile)
            .map(|u| (u.id, u))
            .collect();
        Ok(raw
            .items
            .into_iter()
            .filter_map(|m| {
                let u = profiles.get(&m.member_id)?;
                Some(ChatMember {
                    id: u.id,
                    name: format!("{} {}", u.first_name, u.last_name)
                        .trim()
                        .to_string(),
                    avatar_url: u.avatar_url.clone(),
                    online: u.online,
                    is_admin: m.is_admin,
                })
            })
            .collect())
    }

    pub async fn set_chat_title(
        &self,
        token: &str,
        peer_id: i64,
        title: &str,
    ) -> Result<(), VkError> {
        let chat_id = if peer_id > 2_000_000_000 {
            peer_id - 2_000_000_000
        } else {
            peer_id
        };
        let params = vec![
            ("chat_id".to_string(), chat_id.to_string()),
            ("title".to_string(), title.to_string()),
        ];
        let _: serde_json::Value = self.call_method("messages.editChat", token, params).await?;
        Ok(())
    }

    pub async fn pin_message(
        &self,
        token: &str,
        peer_id: i64,
        message_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("message_id".to_string(), message_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method("messages.pin", token, params).await?;
        Ok(())
    }

    pub async fn get_user_presence(
        &self,
        token: &str,
        user_id: i64,
    ) -> Result<UserPresence, VkError> {
        let params = vec![
            ("user_ids".to_string(), user_id.to_string()),
            ("fields".to_string(), "online,last_seen".to_string()),
        ];
        let users: Vec<RawPresenceUser> = self.call_method("users.get", token, params).await?;
        let u = users.into_iter().next().ok_or_else(|| VkError::ApiError {
            code: 113,
            message: "User not found".to_string(),
        })?;
        Ok(UserPresence {
            user_id: u.id,
            online: u.online,
            last_seen: u.last_seen.map(|ls| ls.time),
        })
    }

    pub async fn get_stories(&self, token: &str) -> Result<Vec<StoryItem>, VkError> {
        let params = vec![("extended".to_string(), "1".to_string())];
        let raw: RawStoriesResponse = self.call_method("stories.get", token, params).await?;
        let profiles: HashMap<i64, UserProfile> = raw
            .profiles
            .into_iter()
            .map(RawUser::into_profile)
            .map(|u| (u.id, u))
            .collect();
        let groups: HashMap<i64, RawGroup> = raw.groups.into_iter().map(|g| (g.id, g)).collect();

        let mut out = Vec::new();
        for bucket in raw.items {
            for s in bucket.stories {
                let (author_name, author_avatar) =
                    resolve_author(s.owner_id, &profiles, &groups);
                let is_video = s.story_type.as_deref() == Some("video");
                let preview_url = s
                    .photo
                    .as_ref()
                    .and_then(|p| extract_max_photo(p).0)
                    .or_else(|| {
                        s.video
                            .as_ref()
                            .and_then(|v| non_empty(v.photo_800.clone()).or_else(|| non_empty(v.photo_320.clone())))
                    });
                let media_url = if is_video {
                    s.video
                        .and_then(|v| v.files.and_then(|f| f.into_qualities_and_best().1))
                } else {
                    preview_url.clone()
                };
                out.push(StoryItem {
                    id: s.id,
                    owner_id: s.owner_id,
                    author_name,
                    author_avatar,
                    date: s.date,
                    preview_url,
                    media_url,
                    is_video,
                });
            }
        }
        Ok(out)
    }

    pub async fn get_fave(&self, token: &str, count: u32) -> Result<Vec<FaveItem>, VkError> {
        let params = vec![
            ("extended".to_string(), "1".to_string()),
            ("count".to_string(), count.clamp(1, 100).to_string()),
        ];
        let raw: RawFaveResponse = self.call_method("fave.get", token, params).await?;
        let profiles: HashMap<i64, UserProfile> = raw
            .profiles
            .into_iter()
            .map(RawUser::into_profile)
            .map(|u| (u.id, u))
            .collect();
        let groups: HashMap<i64, RawGroup> = raw.groups.into_iter().map(|g| (g.id, g)).collect();

        let mut out = Vec::new();
        for item in raw.items {
            if item.kind == "post" {
                if let Some(raw_post) = item.post {
                    let mapped = map_post_items_with_maps(vec![raw_post], &profiles, &groups);
                    if let Some(post) = mapped.into_iter().next() {
                        out.push(FaveItem {
                            kind: "post".to_string(),
                            post: Some(post),
                            link_title: None,
                            link_url: None,
                        });
                    }
                }
            } else if item.kind == "link" {
                if let Some(link) = item.link {
                    out.push(FaveItem {
                        kind: "link".to_string(),
                        post: None,
                        link_title: link.title,
                        link_url: link.url,
                    });
                }
            }
        }
        Ok(out)
    }

    pub async fn fave_add_post(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("id".to_string(), post_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method("fave.addPost", token, params).await?;
        Ok(())
    }

    pub async fn fave_remove_post(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("id".to_string(), post_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method("fave.removePost", token, params).await?;
        Ok(())
    }

    pub async fn vote_poll(
        &self,
        token: &str,
        owner_id: i64,
        poll_id: i64,
        answer_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("poll_id".to_string(), poll_id.to_string()),
            ("answer_ids".to_string(), answer_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method("polls.addVote", token, params).await?;
        Ok(())
    }

    pub async fn create_post_scheduled(
        &self,
        token: &str,
        owner_id: i64,
        message: &str,
        publish_date: Option<i64>,
    ) -> Result<i64, VkError> {
        let mut params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        if let Some(ts) = publish_date.filter(|&t| t > 0) {
            params.push(("publish_date".to_string(), ts.to_string()));
        }
        let raw: RawWallPostResponse = self.call_method("wall.post", token, params).await?;
        Ok(raw.post_id)
    }

    pub async fn add_audio(
        &self,
        token: &str,
        owner_id: i64,
        audio_id: i64,
    ) -> Result<i64, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("audio_id".to_string(), audio_id.to_string()),
        ];
        self.call_method("audio.add", token, params).await
    }

    pub async fn delete_audio(
        &self,
        token: &str,
        owner_id: i64,
        audio_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("audio_id".to_string(), audio_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method("audio.delete", token, params).await?;
        Ok(())
    }

    pub async fn get_audio_recommendations(
        &self,
        token: &str,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let params = vec![("count".to_string(), count.clamp(1, 200).to_string())];
        let raw: RawAudioListResponse = self
            .call_method("audio.getRecommendations", token, params)
            .await?;
        Ok(raw.items.into_iter().map(RawAudio::into_track).collect())
    }

    pub async fn set_audio_broadcast(
        &self,
        token: &str,
        owner_id: i64,
        audio_id: i64,
    ) -> Result<(), VkError> {
        let params = if audio_id > 0 {
            vec![("audio".to_string(), format!("{owner_id}_{audio_id}"))]
        } else {
            Vec::new()
        };
        let _: serde_json::Value = self
            .call_method("audio.setBroadcast", token, params)
            .await?;
        Ok(())
    }

    pub async fn get_inactive_friends(&self, token: &str) -> Result<Vec<OwnerSummary>, VkError> {
        let params = vec![
            ("count".to_string(), "1000".to_string()),
            ("fields".to_string(), "photo_200,deactivated".to_string()),
        ];
        let raw: RawFriendsListResponse = self.call_method("friends.get", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .filter(|u| u.deactivated.as_deref().is_some_and(|d| !d.is_empty()))
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn get_sticker_packs(&self, token: &str) -> Result<Vec<StickerPack>, VkError> {
        let params = vec![
            ("type".to_string(), "stickers".to_string()),
            ("filters".to_string(), "purchased,active".to_string()),
            ("extended".to_string(), "1".to_string()),
        ];
        let raw: RawStickerProductsResponse =
            self.call_method("store.getProducts", token, params).await?;
        let raw_packs = match raw {
            RawStickerProductsResponse::List(items) => items,
            RawStickerProductsResponse::Object { items } => items,
        };
        let mut packs = Vec::with_capacity(raw_packs.len());
        for p in raw_packs {
            let mut stickers = Vec::new();
            if let Some(raw_stickers) = p.stickers {
                for s in raw_stickers {
                    let best = s
                        .images
                        .iter()
                        .chain(s.images_with_background.iter())
                        .min_by_key(|img| img.width.abs_diff(128))
                        .map(|img| img.url.clone())
                        .unwrap_or_else(|| format!("https://vk.com/sticker/1-{}-128", s.sticker_id));
                    stickers.push(StickerItem {
                        sticker_id: s.sticker_id,
                        url: best,
                    });
                }
            } else if let Some(ids) = p.sticker_ids {
                for sid in ids {
                    stickers.push(StickerItem {
                        sticker_id: sid,
                        url: format!("https://vk.com/sticker/1-{sid}-128"),
                    });
                }
            }
            if stickers.is_empty() {
                continue;
            }
            let icon_url = p
                .icon
                .and_then(|ic| non_empty(ic.url))
                .or_else(|| {
                    p.previews
                        .as_ref()
                        .and_then(|list| list.first().map(|img| img.url.clone()))
                })
                .or_else(|| stickers.first().map(|s| s.url.clone()));
            packs.push(StickerPack {
                id: p.id,
                title: p.title,
                icon_url,
                stickers,
            });
        }
        Ok(packs)
    }

    pub async fn resolve_screen_name(
        &self,
        token: &str,
        screen_name: &str,
    ) -> Result<ResolvedTarget, VkError> {
        let params = vec![("screen_name".to_string(), screen_name.to_string())];
        let val: serde_json::Value = self
            .call_method("utils.resolveScreenName", token, params)
            .await?;
        let obj_type = val.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let object_id = val.get("object_id").and_then(|v| v.as_i64()).unwrap_or(0);
        if object_id <= 0 {
            return Ok(ResolvedTarget::Unknown);
        }
        match obj_type {
            "user" => Ok(ResolvedTarget::User { id: object_id }),
            "group" | "page" | "event" => Ok(ResolvedTarget::Group { id: object_id }),
            _ => Ok(ResolvedTarget::Unknown),
        }
    }

    pub async fn get_history_attachments(
        &self,
        token: &str,
        peer_id: i64,
        media_type: &str,
        count: u32,
    ) -> Result<Vec<Attachment>, VkError> {
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("media_type".to_string(), media_type.to_string()),
            ("count".to_string(), count.clamp(1, 200).to_string()),
        ];
        let raw: RawHistoryAttachmentsResponse = self
            .call_method("messages.getHistoryAttachments", token, params)
            .await?;
        Ok(raw
            .items
            .into_iter()
            .filter_map(|item| item.attachment.and_then(parse_attachment))
            .collect())
    }

    pub async fn create_post_with_photo(
        &self,
        token: &str,
        owner_id: i64,
        message: &str,
        photo_bytes: Option<(Vec<u8>, String)>,
        publish_date: Option<i64>,
    ) -> Result<i64, VkError> {
        let mut attachment_str: Option<String> = None;
        if let Some((bytes, filename)) = photo_bytes {
            let server: RawUploadServerResponse = self
                .call_method("photos.getWallUploadServer", token, vec![])
                .await?;
            let part = reqwest::multipart::Part::bytes(bytes).file_name(filename);
            let form = reqwest::multipart::Form::new().part("photo", part);
            let upload_resp: RawPhotoUploadResponse = self
                .http
                .post(&server.upload_url)
                .header(USER_AGENT, VK_USER_AGENT)
                .multipart(form)
                .send()
                .await?
                .json()
                .await?;
            let saved: Vec<RawSavedPhoto> = self
                .call_method(
                    "photos.saveWallPhoto",
                    token,
                    vec![
                        ("server".to_string(), upload_resp.server.to_string()),
                        ("photo".to_string(), upload_resp.photo),
                        ("hash".to_string(), upload_resp.hash),
                    ],
                )
                .await?;
            if let Some(p) = saved.into_iter().next() {
                attachment_str = Some(format!("photo{}_{}", p.owner_id, p.id));
            }
        }
        let mut params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        if let Some(att) = attachment_str {
            params.push(("attachments".to_string(), att));
        }
        if let Some(ts) = publish_date.filter(|&t| t > 0) {
            params.push(("publish_date".to_string(), ts.to_string()));
        }
        let raw: RawWallPostResponse = self.call_method("wall.post", token, params).await?;
        Ok(raw.post_id)
    }

    pub async fn reply_comment(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
        reply_to_comment: Option<i64>,
        message: &str,
    ) -> Result<i64, VkError> {
        let mut params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("post_id".to_string(), post_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        if let Some(cid) = reply_to_comment.filter(|&id| id > 0) {
            params.push(("reply_to_comment".to_string(), cid.to_string()));
        }
        let raw: RawCreateCommentResponse =
            self.call_method("wall.createComment", token, params).await?;
        Ok(raw.comment_id)
    }

    pub async fn like_comment(
        &self,
        token: &str,
        owner_id: i64,
        comment_id: i64,
        add: bool,
    ) -> Result<(), VkError> {
        let method = if add { "likes.add" } else { "likes.delete" };
        let params = vec![
            ("type".to_string(), "comment".to_string()),
            ("owner_id".to_string(), owner_id.to_string()),
            ("item_id".to_string(), comment_id.to_string()),
        ];
        let _: serde_json::Value = self.call_method(method, token, params).await?;
        Ok(())
    }

    pub async fn get_audio_lyrics(
        &self,
        token: &str,
        owner_id: i64,
        audio_id: i64,
    ) -> Result<String, VkError> {
        let audios_param = format!("{owner_id}_{audio_id}");
        let tracks: Vec<RawAudioLyricsMeta> = self
            .call_method(
                "audio.getById",
                token,
                vec![("audios".to_string(), audios_param)],
            )
            .await?;
        let Some(lyrics_id) = tracks.into_iter().next().and_then(|t| t.lyrics_id) else {
            return Ok(String::new());
        };
        let raw: RawLyricsResponse = self
            .call_method(
                "audio.getLyrics",
                token,
                vec![("lyrics_id".to_string(), lyrics_id.to_string())],
            )
            .await?;
        Ok(raw.text)
    }

    pub async fn get_friends_birthdays(
        &self,
        token: &str,
    ) -> Result<Vec<BirthdayFriend>, VkError> {
        let params = vec![
            ("count".to_string(), "500".to_string()),
            ("fields".to_string(), "photo_200,bdate".to_string()),
        ];
        let raw: RawBirthdayListResponse = self.call_method("friends.get", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .filter_map(|u| {
                let bdate = non_empty(u.bdate)?;
                let name = format!("{} {}", u.first_name.trim(), u.last_name.trim())
                    .trim()
                    .to_string();
                let avatar = non_empty(u.photo_200)
                    .or_else(|| non_empty(u.photo_100))
                    .or_else(|| non_empty(u.photo_50));
                Some(BirthdayFriend {
                    id: u.id,
                    name,
                    avatar_url: avatar,
                    bdate,
                })
            })
            .collect())
    }

    pub async fn get_album_photo_urls(
        &self,
        token: &str,
        owner_id: i64,
        count: u32,
    ) -> Result<Vec<String>, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("count".to_string(), count.clamp(1, 200).to_string()),
            ("photo_sizes".to_string(), "1".to_string()),
        ];
        let raw: RawPhotosAllResponse = self.call_method("photos.getAll", token, params).await?;
        Ok(raw
            .items
            .into_iter()
            .filter_map(|p| {
                p.orig_photo
                    .and_then(|s| non_empty(s.url))
                    .or_else(|| {
                        p.sizes
                            .into_iter()
                            .max_by_key(|s| s.width.unwrap_or(0))
                            .and_then(|s| non_empty(s.url))
                    })
                    .or_else(|| non_empty(p.photo_1280))
                    .or_else(|| non_empty(p.photo_807))
                    .or_else(|| non_empty(p.photo_604))
            })
            .collect())
    }

    pub async fn create_playlist(
        &self,
        token: &str,
        owner_id: i64,
        title: &str,
    ) -> Result<i64, VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("title".to_string(), title.to_string()),
        ];
        let raw: RawPlaylistId = self
            .call_method("audio.createPlaylist", token, params)
            .await?;
        Ok(raw.id)
    }

    pub async fn delete_messages_batch(
        &self,
        token: &str,
        peer_id: i64,
        message_ids: &[i64],
    ) -> Result<(), VkError> {
        if message_ids.is_empty() {
            return Ok(());
        }
        let ids_str = message_ids
            .iter()
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(",");
        let params = vec![
            ("peer_id".to_string(), peer_id.to_string()),
            ("message_ids".to_string(), ids_str),
            ("delete_for_all".to_string(), "1".to_string()),
        ];
        let _: serde_json::Value = self.call_method("messages.delete", token, params).await?;
        Ok(())
    }

    pub async fn add_to_playlist(
        &self,
        token: &str,
        owner_id: i64,
        playlist_id: i64,
        audio_owner_id: i64,
        audio_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            ("playlist_id".to_string(), playlist_id.to_string()),
            (
                "audio_ids".to_string(),
                format!("{audio_owner_id}_{audio_id}"),
            ),
        ];
        let _: serde_json::Value = self.call_method("audio.addToPlaylist", token, params).await?;
        Ok(())
    }

    pub async fn ignore_newsfeed_item(
        &self,
        token: &str,
        owner_id: i64,
        post_id: i64,
    ) -> Result<(), VkError> {
        let params = vec![
            ("type".to_string(), "wall".to_string()),
            ("owner_id".to_string(), owner_id.to_string()),
            ("item_id".to_string(), post_id.to_string()),
        ];
        let _: serde_json::Value = self
            .call_method("newsfeed.ignoreItem", token, params)
            .await?;
        Ok(())
    }

    pub async fn get_fave_pages(&self, token: &str) -> Result<Vec<OwnerSummary>, VkError> {
        let params = vec![
            ("count".to_string(), "100".to_string()),
            ("fields".to_string(), "photo_200,online,verified".to_string()),
        ];
        let raw: RawFavePagesResponse = self.call_method("fave.getPages", token, params).await?;
        let mut out = Vec::new();
        for item in raw.items {
            if let Some(u) = item.user {
                out.push(u.into_summary());
            } else if let Some(g) = item.group {
                out.push(g.into_summary());
            }
        }
        Ok(out)
    }

    pub async fn send_wall_to_peer(
        &self,
        token: &str,
        peer_id: i64,
        owner_id: i64,
        post_id: i64,
    ) -> Result<i64, VkError> {
        let att = format!("wall{owner_id}_{post_id}");
        self.send_message_with_options(token, peer_id, "", None, Some(&att))
            .await
    }

    pub async fn get_similar_audio(
        &self,
        token: &str,
        owner_id: i64,
        audio_id: i64,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let params = vec![
            ("target_audio".to_string(), format!("{owner_id}_{audio_id}")),
            ("count".to_string(), count.clamp(1, 200).to_string()),
        ];
        let raw: RawAudioListResponse = self
            .call_method("audio.getRecommendations", token, params)
            .await?;
        Ok(raw.items.into_iter().map(RawAudio::into_track).collect())
    }

    pub async fn get_banned(&self, token: &str) -> Result<Vec<OwnerSummary>, VkError> {
        let params = vec![
            ("count".to_string(), "100".to_string()),
            ("fields".to_string(), "photo_200".to_string()),
        ];
        let raw: RawBannedResponse = self.call_method("account.getBanned", token, params).await?;
        Ok(raw
            .profiles
            .into_iter()
            .map(RawOwnerUser::into_summary)
            .collect())
    }

    pub async fn ban_user(&self, token: &str, owner_id: i64) -> Result<(), VkError> {
        let params = vec![("owner_id".to_string(), owner_id.to_string())];
        let _: serde_json::Value = self.call_method("account.ban", token, params).await?;
        Ok(())
    }

    pub async fn unban_user(&self, token: &str, owner_id: i64) -> Result<(), VkError> {
        let params = vec![("owner_id".to_string(), owner_id.to_string())];
        let _: serde_json::Value = self.call_method("account.unban", token, params).await?;
        Ok(())
    }

    pub async fn get_friend_requests(
        &self,
        token: &str,
    ) -> Result<Vec<FriendRequestItem>, VkError> {
        let params = vec![
            ("count".to_string(), "50".to_string()),
            ("extended".to_string(), "1".to_string()),
            ("need_mutual".to_string(), "0".to_string()),
        ];
        let raw: RawFriendRequestsResponse =
            self.call_method("friends.getRequests", token, params).await?;
        let mut msg_by_id: HashMap<i64, Option<String>> = HashMap::new();
        let mut ids = Vec::new();
        for item in raw.items {
            ids.push(item.user_id.to_string());
            msg_by_id.insert(item.user_id, non_empty(item.message));
        }
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let users: Vec<RawOwnerUser> = self
            .call_method(
                "users.get",
                token,
                vec![
                    ("user_ids".to_string(), ids.join(",")),
                    ("fields".to_string(), "photo_200".to_string()),
                ],
            )
            .await?;
        Ok(users
            .into_iter()
            .map(|u| {
                let id = u.id;
                let s = u.into_summary();
                FriendRequestItem {
                    id,
                    name: s.name,
                    avatar_url: s.avatar_url,
                    message: msg_by_id.remove(&id).flatten(),
                }
            })
            .collect())
    }

    pub async fn accept_friend(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        let params = vec![("user_id".to_string(), user_id.to_string())];
        let _: serde_json::Value = self.call_method("friends.add", token, params).await?;
        Ok(())
    }

    pub async fn decline_friend(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        let params = vec![("user_id".to_string(), user_id.to_string())];
        let _: serde_json::Value = self.call_method("friends.delete", token, params).await?;
        Ok(())
    }

    pub async fn set_status(&self, token: &str, text: &str) -> Result<(), VkError> {
        let params = vec![("text".to_string(), text.to_string())];
        let _: serde_json::Value = self.call_method("status.set", token, params).await?;
        Ok(())
    }

    pub async fn get_media_comments(
        &self,
        token: &str,
        is_video: bool,
        owner_id: i64,
        item_id: i64,
    ) -> Result<Vec<CommentItem>, VkError> {
        let method = if is_video {
            "video.getComments"
        } else {
            "photos.getComments"
        };
        let id_key = if is_video { "video_id" } else { "photo_id" };
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            (id_key.to_string(), item_id.to_string()),
            ("count".to_string(), "50".to_string()),
            ("extended".to_string(), "1".to_string()),
            ("fields".to_string(), "photo_100".to_string()),
        ];
        let raw: RawCommentsListResponse = self.call_method(method, token, params).await?;
        let profiles: HashMap<i64, RawUser> =
            raw.profiles.into_iter().map(|u| (u.id, u)).collect();
        let groups: HashMap<i64, RawGroup> =
            raw.groups.into_iter().map(|g| (g.id, g)).collect();
        Ok(raw
            .items
            .into_iter()
            .map(|c| {
                let (author_name, author_avatar) = if c.from_id > 0 {
                    profiles
                        .get(&c.from_id)
                        .map(|u| {
                            let name = format!("{} {}", u.first_name.trim(), u.last_name.trim())
                                .trim()
                                .to_string();
                            let av = non_empty(u.photo_100.clone())
                                .or_else(|| non_empty(u.photo_200.clone()));
                            (name, av)
                        })
                        .unwrap_or_else(|| (format!("id{}", c.from_id), None))
                } else {
                    groups
                        .get(&(-c.from_id))
                        .map(|g| {
                            let av = non_empty(g.photo_100.clone())
                                .or_else(|| non_empty(g.photo_200.clone()));
                            (g.name.clone(), av)
                        })
                        .unwrap_or_else(|| (format!("club{}", -c.from_id), None))
                };
                CommentItem {
                    id: c.id,
                    from_id: c.from_id,
                    author_name,
                    author_avatar,
                    date: c.date,
                    text: c.text,
                    likes_count: 0,
                    is_liked: false,
                }
            })
            .collect())
    }

    pub async fn create_media_comment(
        &self,
        token: &str,
        is_video: bool,
        owner_id: i64,
        item_id: i64,
        message: &str,
    ) -> Result<i64, VkError> {
        let method = if is_video {
            "video.createComment"
        } else {
            "photos.createComment"
        };
        let id_key = if is_video { "video_id" } else { "photo_id" };
        let params = vec![
            ("owner_id".to_string(), owner_id.to_string()),
            (id_key.to_string(), item_id.to_string()),
            ("message".to_string(), message.to_string()),
        ];
        self.call_method(method, token, params).await
    }

    pub async fn get_audio(
        &self,
        token: &str,
        offset: u32,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        if count == 0 {
            return Ok(Vec::new());
        }
        let clamped_count = count.clamp(1, 200);
        let params = vec![
            ("offset".to_string(), offset.to_string()),
            ("count".to_string(), clamped_count.to_string()),
        ];
        let raw: RawAudioListResponse = self.call_method("audio.get", token, params).await?;
        Ok(raw.items.into_iter().map(RawAudio::into_track).collect())
    }

    pub async fn search_audio(
        &self,
        token: &str,
        query: &str,
        offset: u32,
        count: u32,
    ) -> Result<Vec<AudioTrack>, VkError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Audio search query must not be empty".to_string(),
            });
        }
        if count == 0 {
            return Ok(Vec::new());
        }

        let clamped_count = count.clamp(1, 200);
        let params = vec![
            ("q".to_string(), trimmed.to_string()),
            ("offset".to_string(), offset.to_string()),
            ("count".to_string(), clamped_count.to_string()),
            ("auto_complete".to_string(), "1".to_string()),
        ];
        let raw: RawAudioListResponse = self.call_method("audio.search", token, params).await?;
        Ok(raw.items.into_iter().map(RawAudio::into_track).collect())
    }

    pub async fn get_long_poll_server(&self, token: &str) -> Result<LongPollServerInfo, VkError> {
        let params = vec![
            ("lp_version".to_string(), "3".to_string()),
            ("need_pts".to_string(), "0".to_string()),
        ];
        self.call_method("messages.getLongPollServer", token, params)
            .await
    }

    async fn call_method<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        token: &str,
        mut params: Vec<(String, String)>,
    ) -> Result<T, VkError> {
        let trimmed_token = token.trim();
        if trimmed_token.is_empty() {
            return Err(VkError::InvalidToken);
        }

        self.rate_limiter.acquire().await;

        params.push(("v".to_string(), VK_API_VERSION.to_string()));
        params.push(("access_token".to_string(), trimmed_token.to_string()));

        let url = format!("{}{}", self.base_url, method.trim_start_matches('/'));
        let response = self
            .http
            .post(&url)
            .header(USER_AGENT, VK_USER_AGENT)
            .form(&params)
            .send()
            .await?;

        let status = response.status();
        let body = response.text().await?;

        parse_vk_envelope(status, &body)
    }
}

fn default_http_client() -> Result<reqwest::Client, VkError> {
    reqwest::Client::builder()
        .use_rustls_tls()
        .user_agent(VK_USER_AGENT)
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|err| VkError::Network {
            details: format!("Failed to build HTTP client: {err}"),
        })
}

fn normalize_base_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        DEFAULT_API_BASE_URL.to_string()
    } else if trimmed.ends_with('/') {
        trimmed.to_string()
    } else {
        format!("{trimmed}/")
    }
}

fn next_random_id() -> i32 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(1, |d| d.subsec_nanos() as u64);
    let seq = RANDOM_ID_SEQ.fetch_add(1, Ordering::Relaxed);
    let mixed = ((nanos ^ seq.wrapping_mul(2_654_435_761)) % (i32::MAX as u64 - 1)) + 1;
    mixed as i32
}

fn parse_vk_envelope<T: serde::de::DeserializeOwned>(
    status: StatusCode,
    body: &str,
) -> Result<T, VkError> {
    match serde_json::from_str::<VkApiEnvelope<T>>(body) {
        Ok(envelope) => {
            if let Some(err) = envelope.error {
                return Err(map_vk_api_error(err));
            }
            match envelope.response {
                Some(resp) => Ok(resp),
                None => Err(VkError::Internal {
                    details: "VK API response missing both 'response' and 'error'".to_string(),
                }),
            }
        }
        Err(parse_err) => {
            if status == StatusCode::TOO_MANY_REQUESTS {
                Err(VkError::RateLimited)
            } else if status == StatusCode::UNAUTHORIZED {
                Err(VkError::InvalidToken)
            } else {
                let snippet: String = body.chars().take(200).collect();
                Err(VkError::Network {
                    details: format!("VK API HTTP {status} ({parse_err}): {snippet}"),
                })
            }
        }
    }
}

fn map_vk_api_error(err: VkApiErrorPayload) -> VkError {
    match err.error_code {
        5 => VkError::InvalidToken,
        6 => VkError::RateLimited,
        14 => VkError::CaptchaRequired {
            sid: err.captcha_sid.unwrap_or_default(),
            img_url: err.captcha_img.unwrap_or_default(),
        },
        17 => VkError::ValidationRequired {
            validation_type: err
                .validation_type
                .and_then(|s| non_empty(Some(s)))
                .unwrap_or_else(|| "validation_required".to_string()),
            phone_mask: err
                .phone_mask
                .and_then(|s| non_empty(Some(s)))
                .or_else(|| err.redirect_uri.and_then(|s| non_empty(Some(s))))
                .unwrap_or_default(),
        },
        code => VkError::ApiError {
            code,
            message: err.error_msg,
        },
    }
}

pub(crate) fn message_preview_from_parts(text: &str, attachments: &[Attachment]) -> String {
    if !text.trim().is_empty() {
        return text.to_string();
    }
    match attachments.first() {
        Some(Attachment::Photo { .. }) => "[Фото]".to_string(),
        Some(Attachment::Audio { .. }) => "[Аудио]".to_string(),
        Some(Attachment::Document { .. }) => "[Документ]".to_string(),
        Some(Attachment::Sticker { .. }) => "[Стикер]".to_string(),
        Some(Attachment::Link { .. }) => "[Ссылка]".to_string(),
        Some(Attachment::Video { .. }) => "[Видео]".to_string(),
        Some(Attachment::AudioMessage { .. }) => "[Голосовое сообщение]".to_string(),
        Some(Attachment::Poll { .. }) => "[Опрос]".to_string(),
        Some(Attachment::Reply { .. }) => "[Ответ]".to_string(),
        Some(Attachment::Forwarded { .. }) => "[Пересланное сообщение]".to_string(),
        Some(Attachment::BotKeyboard { .. }) => "[Клавиатура]".to_string(),
        Some(Attachment::Unknown { .. }) => "[Вложение]".to_string(),
        None => String::new(),
    }
}

fn non_empty(opt: Option<String>) -> Option<String> {
    opt.map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn nonzero_u32(val: Option<u32>) -> Option<u32> {
    val.filter(|&v| v > 0)
}

fn photo_size_rank(size_type: Option<&str>) -> u32 {
    match size_type.unwrap_or("") {
        "w" => 10,
        "z" => 9,
        "y" => 8,
        "x" => 7,
        "r" => 6,
        "q" => 5,
        "p" => 4,
        "o" => 3,
        "m" => 2,
        "s" => 1,
        _ => 0,
    }
}

fn extract_max_photo(photo: &RawPhoto) -> (Option<String>, Option<u32>, Option<u32>) {
    let best = photo
        .sizes
        .iter()
        .filter(|s| non_empty(s.url.clone()).is_some())
        .max_by_key(|s| {
            let area = u64::from(s.width.unwrap_or(0)) * u64::from(s.height.unwrap_or(0));
            (
                area,
                s.width.unwrap_or(0),
                photo_size_rank(s.size_type.as_deref()),
            )
        });

    match best {
        Some(size) => (
            non_empty(size.url.clone()),
            nonzero_u32(size.width),
            nonzero_u32(size.height),
        ),
        None => match photo.orig_photo.as_ref() {
            Some(orig) => (
                non_empty(orig.url.clone()),
                nonzero_u32(orig.width),
                nonzero_u32(orig.height),
            ),
            None => (
                non_empty(photo.photo_1280.clone())
                    .or_else(|| non_empty(photo.photo_807.clone()))
                    .or_else(|| non_empty(photo.photo_604.clone())),
                None,
                None,
            ),
        },
    }
}

pub(crate) fn parse_attachment(raw: RawAttachment) -> Option<Attachment> {
    if raw.kind.trim().is_empty() {
        return None;
    }

    let attachment = match raw.kind.as_str() {
        "photo" => {
            if let Some(photo) = raw.photo {
                let (url_opt, width, height) = extract_max_photo(&photo);
                if let Some(url) = url_opt {
                    Attachment::Photo { url, width, height }
                } else {
                    Attachment::Unknown {
                        kind: "photo".to_string(),
                    }
                }
            } else {
                Attachment::Unknown {
                    kind: "photo".to_string(),
                }
            }
        }
        "audio" => {
            if let Some(audio) = raw.audio {
                Attachment::Audio {
                    artist: audio.artist,
                    title: audio.title,
                    duration_sec: audio.duration,
                    url: non_empty(audio.url),
                }
            } else {
                Attachment::Unknown {
                    kind: "audio".to_string(),
                }
            }
        }
        "doc" => {
            if let Some(doc) = raw.doc {
                if let Some(am) = doc.preview.and_then(|p| p.audio_msg) {
                    let url = non_empty(am.link_mp3)
                        .or_else(|| non_empty(am.link_ogg))
                        .or_else(|| non_empty(doc.url))
                        .unwrap_or_default();
                    let transcript = non_empty(am.transcript);
                    Attachment::AudioMessage {
                        url,
                        duration_sec: am.duration,
                        transcript,
                    }
                } else {
                    Attachment::Document {
                        title: doc.title,
                        url: doc.url.unwrap_or_default(),
                        ext: doc.ext.unwrap_or_default(),
                    }
                }
            } else {
                Attachment::Unknown {
                    kind: "doc".to_string(),
                }
            }
        }
        "sticker" => {
            if let Some(sticker) = raw.sticker {
                let best_url = sticker
                    .images
                    .iter()
                    .chain(sticker.images_with_background.iter())
                    .filter(|img| non_empty(img.url.clone()).is_some())
                    .max_by_key(|img| img.width.unwrap_or(0))
                    .and_then(|img| non_empty(img.url.clone()));
                if let Some(url) = best_url {
                    Attachment::Sticker { url }
                } else {
                    Attachment::Unknown {
                        kind: "sticker".to_string(),
                    }
                }
            } else {
                Attachment::Unknown {
                    kind: "sticker".to_string(),
                }
            }
        }
        "link" => {
            if let Some(link) = raw.link {
                let url = link.url.unwrap_or_default();
                let title = non_empty(link.title)
                    .or_else(|| non_empty(link.caption))
                    .unwrap_or_else(|| url.clone());
                Attachment::Link { title, url }
            } else {
                Attachment::Unknown {
                    kind: "link".to_string(),
                }
            }
        }
        "video" => {
            if let Some(video) = raw.video {
                let item = video.into_video_item();
                Attachment::Video {
                    id: item.id,
                    owner_id: item.owner_id,
                    access_key: item.access_key,
                    title: item.title,
                    duration_sec: item.duration_sec,
                    thumbnail_url: item.thumbnail_url,
                    player_url: item.player_url,
                    stream_url: item.stream_url,
                    qualities: item.qualities,
                }
            } else {
                Attachment::Unknown {
                    kind: "video".to_string(),
                }
            }
        }
        "audio_message" => {
            if let Some(am) = raw.audio_message {
                let url = non_empty(am.link_mp3)
                    .or_else(|| non_empty(am.link_ogg))
                    .unwrap_or_default();
                let transcript = non_empty(am.transcript);
                Attachment::AudioMessage {
                    url,
                    duration_sec: am.duration,
                    transcript,
                }
            } else {
                Attachment::Unknown {
                    kind: "audio_message".to_string(),
                }
            }
        }
        "poll" => {
            if let Some(poll) = raw.poll {
                Attachment::Poll {
                    id: poll.id,
                    owner_id: poll.owner_id,
                    question: poll.question,
                    answers: poll
                        .answers
                        .into_iter()
                        .map(|a| PollAnswer {
                            id: a.id,
                            text: a.text,
                            votes: a.votes,
                            rate: a.rate.round().max(0.0) as u32,
                        })
                        .collect(),
                }
            } else {
                Attachment::Unknown {
                    kind: "poll".to_string(),
                }
            }
        }
        other => Attachment::Unknown {
            kind: other.to_string(),
        },
    };

    Some(attachment)
}

#[derive(Debug, Deserialize)]
struct VkApiEnvelope<T> {
    response: Option<T>,
    error: Option<VkApiErrorPayload>,
}

#[derive(Debug, Deserialize)]
struct VkApiErrorPayload {
    error_code: i32,
    #[serde(default)]
    error_msg: String,
    captcha_sid: Option<String>,
    captcha_img: Option<String>,
    validation_type: Option<String>,
    phone_mask: Option<String>,
    redirect_uri: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawUser {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    first_name: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    last_name: String,
    photo_100: Option<String>,
    photo_200: Option<String>,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    online: bool,
}

impl RawUser {
    fn into_profile(self) -> UserProfile {
        let avatar_url = non_empty(self.photo_200).or_else(|| non_empty(self.photo_100));
        UserProfile {
            id: self.id,
            first_name: self.first_name,
            last_name: self.last_name,
            avatar_url,
            online: self.online,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawGroup {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    name: String,
    photo_50: Option<String>,
    photo_100: Option<String>,
    photo_200: Option<String>,
}

impl RawGroup {
    fn best_avatar(&self) -> Option<String> {
        non_empty(self.photo_200.clone())
            .or_else(|| non_empty(self.photo_100.clone()))
            .or_else(|| non_empty(self.photo_50.clone()))
    }
}

#[derive(Debug, Deserialize)]
struct RawPhotoSet {
    photo_50: Option<String>,
    photo_100: Option<String>,
    photo_200: Option<String>,
}

impl RawPhotoSet {
    fn best_url(&self) -> Option<String> {
        non_empty(self.photo_200.clone())
            .or_else(|| non_empty(self.photo_100.clone()))
            .or_else(|| non_empty(self.photo_50.clone()))
    }
}

#[derive(Debug, Deserialize)]
struct RawConversationsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawConversationEntry>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
struct RawConversationEntry {
    conversation: RawConversation,
    last_message: Option<RawMessage>,
}

#[derive(Debug, Deserialize)]
struct RawConversationsByIdResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawConversation>,
}

#[derive(Debug, Deserialize)]
struct RawConversation {
    peer: RawPeer,
    #[serde(default)]
    unread_count: u32,
    chat_settings: Option<RawChatSettings>,
    push_settings: Option<RawPushSettings>,
    current_keyboard: Option<RawBotKeyboard>,
}

#[derive(Debug, Deserialize)]
struct RawPeer {
    id: i64,
    #[serde(rename = "type")]
    kind: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawChatSettings {
    title: Option<String>,
    photo: Option<RawPhotoSet>,
}

#[derive(Debug, Deserialize)]
struct RawPushSettings {
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    disabled_forever: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    no_sound: bool,
    disabled_until: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RawHistoryResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawMessage>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
}

#[derive(Debug, Deserialize)]
struct RawMessage {
    id: i64,
    peer_id: Option<i64>,
    #[serde(default)]
    from_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    text: String,
    #[serde(default)]
    date: i64,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    out: bool,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    attachments: Vec<RawAttachment>,
    reply_message: Option<Box<RawMessage>>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    fwd_messages: Vec<RawMessage>,
    keyboard: Option<RawBotKeyboard>,
}

#[derive(Debug, Deserialize)]
struct RawBotKeyboard {
    #[serde(default)]
    inline: bool,
    #[serde(default)]
    one_time: bool,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    buttons: Vec<Vec<RawBotButton>>,
}

#[derive(Debug, Deserialize)]
struct RawBotButton {
    action: RawBotButtonAction,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    color: String,
}

#[derive(Debug, Deserialize)]
struct RawBotButtonAction {
    #[serde(rename = "type", default, deserialize_with = "deserialize_null_default")]
    kind: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    label: String,
    payload: Option<serde_json::Value>,
    link: Option<String>,
}

fn parse_bot_keyboard_data(raw: RawBotKeyboard) -> Option<BotKeyboard> {
    let rows: Vec<BotKeyboardRow> = raw
        .buttons
        .into_iter()
        .filter_map(|row| {
            let buttons: Vec<BotKeyboardButton> = row
                .into_iter()
                .map(|btn| {
                    let action_type = if btn.action.kind.is_empty() {
                        "text".to_string()
                    } else {
                        btn.action.kind
                    };
                    let label = if !btn.action.label.trim().is_empty() {
                        btn.action.label
                    } else {
                        match action_type.as_str() {
                            "location" => "Местоположение".to_string(),
                            "vkpay" => "VK Pay".to_string(),
                            "open_app" => "Открыть приложение".to_string(),
                            _ => "Кнопка".to_string(),
                        }
                    };
                    let payload = btn.action.payload.map(|v| match v {
                        serde_json::Value::String(s) => s,
                        other => other.to_string(),
                    });
                    let color = if btn.color.is_empty() {
                        "secondary".to_string()
                    } else {
                        btn.color
                    };
                    BotKeyboardButton {
                        action_type,
                        label,
                        color,
                        payload,
                        link: non_empty(btn.action.link),
                    }
                })
                .collect();
            if buttons.is_empty() {
                None
            } else {
                Some(BotKeyboardRow { buttons })
            }
        })
        .collect();

    if rows.is_empty() {
        None
    } else {
        Some(BotKeyboard {
            inline: raw.inline,
            one_time: raw.one_time,
            rows,
        })
    }
}

fn parse_bot_keyboard(raw: RawBotKeyboard) -> Option<Attachment> {
    parse_bot_keyboard_data(raw).map(|kb| Attachment::BotKeyboard {
        inline: kb.inline,
        one_time: kb.one_time,
        rows: kb.rows,
    })
}

#[derive(Debug, Deserialize)]
pub(crate) struct RawAttachment {
    #[serde(rename = "type", default, deserialize_with = "deserialize_null_default")]
    kind: String,
    photo: Option<RawPhoto>,
    audio: Option<RawAudio>,
    doc: Option<RawDocument>,
    sticker: Option<RawSticker>,
    link: Option<RawLink>,
    video: Option<RawVideo>,
    audio_message: Option<RawAudioMessage>,
    poll: Option<RawPoll>,
}

#[derive(Debug, Deserialize)]
struct RawPhoto {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    sizes: Vec<RawPhotoSize>,
    orig_photo: Option<RawPhotoSize>,
    photo_1280: Option<String>,
    photo_807: Option<String>,
    photo_604: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPhotoSize {
    #[serde(rename = "type")]
    size_type: Option<String>,
    url: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct RawDocument {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    title: String,
    url: Option<String>,
    ext: Option<String>,
    preview: Option<RawDocPreview>,
}

#[derive(Debug, Deserialize)]
struct RawDocPreview {
    audio_msg: Option<RawAudioMessage>,
}

#[derive(Debug, Deserialize)]
struct RawSticker {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    images: Vec<RawStickerImage>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    images_with_background: Vec<RawStickerImage>,
}

#[derive(Debug, Deserialize)]
struct RawStickerImage {
    url: Option<String>,
    width: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct RawLink {
    title: Option<String>,
    caption: Option<String>,
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawNewsfeedResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawNewsfeedItem>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
    next_from: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawNewsfeedItem {
    #[serde(rename = "type")]
    item_type: Option<String>,
    post_id: Option<i64>,
    id: Option<i64>,
    #[serde(default)]
    source_id: i64,
    #[serde(default)]
    owner_id: i64,
    #[serde(default)]
    from_id: i64,
    #[serde(default)]
    date: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    text: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    attachments: Vec<RawAttachment>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    copy_history: Vec<RawNewsfeedItem>,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    marked_as_ads: bool,
    likes: Option<RawLikesInfo>,
    comments: Option<RawCommentsInfo>,
}

#[derive(Debug, Deserialize)]
struct RawWallResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawNewsfeedItem>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
struct RawCity {
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawUserCounters {
    friends: Option<u32>,
    followers: Option<u32>,
    photos: Option<u32>,
    audios: Option<u32>,
    groups: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct RawOwnerUser {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    first_name: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    last_name: String,
    screen_name: Option<String>,
    photo_100: Option<String>,
    photo_200: Option<String>,
    photo_max_orig: Option<String>,
    status: Option<String>,
    about: Option<String>,
    city: Option<RawCity>,
    site: Option<String>,
    followers_count: Option<u32>,
    counters: Option<RawUserCounters>,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    online: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    verified: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    is_friend: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    can_post: bool,
    #[allow(dead_code)]
    deactivated: Option<String>,
}

impl RawOwnerUser {
    fn full_name(&self) -> String {
        let joined = format!("{} {}", self.first_name, self.last_name)
            .trim()
            .to_string();
        if joined.is_empty() {
            format!("User {}", self.id)
        } else {
            joined
        }
    }

    fn best_avatar(&self) -> Option<String> {
        non_empty(self.photo_200.clone())
            .or_else(|| non_empty(self.photo_max_orig.clone()))
            .or_else(|| non_empty(self.photo_100.clone()))
    }

    fn into_owner_page(self) -> OwnerPage {
        let name = self.full_name();
        let avatar_url = self.best_avatar();
        let friends_count = self.counters.as_ref().and_then(|c| c.friends);
        let photos_count = self.counters.as_ref().and_then(|c| c.photos);
        let audios_count = self.counters.as_ref().and_then(|c| c.audios);
        let groups_count = self.counters.as_ref().and_then(|c| c.groups);
        let followers_count = self
            .followers_count
            .or_else(|| self.counters.as_ref().and_then(|c| c.followers));
        OwnerPage {
            id: self.id,
            is_group: false,
            name,
            screen_name: non_empty(self.screen_name),
            avatar_url,
            cover_url: None,
            status: non_empty(self.status),
            description: non_empty(self.about),
            followers_count,
            friends_count,
            photos_count,
            audios_count,
            groups_count,
            online: self.online,
            city: self.city.and_then(|c| non_empty(c.title)),
            site: non_empty(self.site),
            is_verified: self.verified,
            is_member_or_friend: self.is_friend,
            can_post: self.can_post,
            wall_posts: Vec::new(),
        }
    }

    fn into_summary(self) -> OwnerSummary {
        let name = self.full_name();
        let avatar_url = self.best_avatar();
        OwnerSummary {
            id: self.id,
            is_group: false,
            name,
            screen_name: non_empty(self.screen_name),
            avatar_url,
            subtitle: non_empty(self.status),
            online: self.online,
            is_verified: self.verified,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawCoverImage {
    url: Option<String>,
    #[serde(default)]
    width: u32,
}

#[derive(Debug, Deserialize)]
struct RawCover {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    images: Vec<RawCoverImage>,
}

#[derive(Debug, Deserialize)]
struct RawOwnerGroup {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    name: String,
    screen_name: Option<String>,
    photo_50: Option<String>,
    photo_100: Option<String>,
    photo_200: Option<String>,
    cover: Option<RawCover>,
    status: Option<String>,
    description: Option<String>,
    members_count: Option<u32>,
    city: Option<RawCity>,
    site: Option<String>,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    verified: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    is_member: bool,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    can_post: bool,
    #[allow(dead_code)]
    deactivated: Option<String>,
}

impl RawOwnerGroup {
    fn best_avatar(&self) -> Option<String> {
        non_empty(self.photo_200.clone())
            .or_else(|| non_empty(self.photo_100.clone()))
            .or_else(|| non_empty(self.photo_50.clone()))
    }

    fn best_cover(&self) -> Option<String> {
        self.cover.as_ref().and_then(|c| {
            c.images
                .iter()
                .filter_map(|img| non_empty(img.url.clone()).map(|u| (img.width, u)))
                .max_by_key(|(w, _)| *w)
                .map(|(_, u)| u)
        })
    }

    fn into_owner_page(self) -> OwnerPage {
        let avatar_url = self.best_avatar();
        let cover_url = self.best_cover();
        let name = non_empty(Some(self.name)).unwrap_or_else(|| format!("Group {}", self.id));
        OwnerPage {
            id: -self.id.abs(),
            is_group: true,
            name,
            screen_name: non_empty(self.screen_name),
            avatar_url,
            cover_url,
            status: non_empty(self.status),
            description: non_empty(self.description),
            followers_count: self.members_count,
            friends_count: None,
            photos_count: None,
            audios_count: None,
            groups_count: None,
            online: false,
            city: self.city.and_then(|c| non_empty(c.title)),
            site: non_empty(self.site),
            is_verified: self.verified,
            is_member_or_friend: self.is_member,
            can_post: self.can_post,
            wall_posts: Vec::new(),
        }
    }

    fn into_summary(self) -> OwnerSummary {
        let avatar_url = self.best_avatar();
        let name = non_empty(Some(self.name)).unwrap_or_else(|| format!("Group {}", self.id));
        let subtitle = non_empty(self.status)
            .or_else(|| self.members_count.map(|m| format!("{m} участников")));
        OwnerSummary {
            id: -self.id.abs(),
            is_group: true,
            name,
            screen_name: non_empty(self.screen_name),
            avatar_url,
            subtitle,
            online: false,
            is_verified: self.verified,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawGroupsByIdResponse {
    Wrapped {
        #[serde(default, deserialize_with = "deserialize_null_default")]
        groups: Vec<RawOwnerGroup>,
    },
    List(Vec<RawOwnerGroup>),
}

impl RawGroupsByIdResponse {
    fn into_vec(self) -> Vec<RawOwnerGroup> {
        match self {
            Self::Wrapped { groups } => groups,
            Self::List(groups) => groups,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawFriendsListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawOwnerUser>,
}

#[derive(Debug, Deserialize)]
struct RawGroupsListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawOwnerGroup>,
}

#[derive(Debug, Deserialize)]
struct RawPhotosListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawPhoto>,
}

fn resolve_author(
    source_id: i64,
    profiles: &HashMap<i64, UserProfile>,
    groups: &HashMap<i64, RawGroup>,
) -> (String, Option<String>) {
    if source_id < 0 {
        let gid = source_id.abs();
        if let Some(group) = groups.get(&gid) {
            let name =
                non_empty(Some(group.name.clone())).unwrap_or_else(|| format!("Group {gid}"));
            (name, group.best_avatar())
        } else {
            (format!("Group {gid}"), None)
        }
    } else if let Some(user) = profiles.get(&source_id) {
        let full_name = format!("{} {}", user.first_name, user.last_name)
            .trim()
            .to_string();
        let name = if full_name.is_empty() {
            format!("User {source_id}")
        } else {
            full_name
        };
        (name, user.avatar_url.clone())
    } else {
        (format!("User {source_id}"), None)
    }
}

#[derive(Debug, Deserialize)]
struct RawCommentsListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawComment>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
struct RawComment {
    id: i64,
    #[serde(default)]
    from_id: i64,
    #[serde(default)]
    date: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    text: String,
    likes: Option<RawLikesInfo>,
}

#[derive(Debug, Deserialize)]
struct RawCreateCommentResponse {
    comment_id: i64,
}

#[derive(Debug, Deserialize)]
struct RawWallPostResponse {
    post_id: i64,
}

#[derive(Debug, Deserialize)]
struct RawNotificationsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawNotification>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
#[serde(transparent)]
struct RawNotification(serde_json::Value);

impl RawNotification {
    fn extract_date(&self) -> i64 {
        self.0.get("date").and_then(|v| v.as_i64()).unwrap_or(0)
    }

    fn extract_kind(&self) -> String {
        if let Some(t) = self.0.get("type").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            return t.to_string();
        }
        if let Some(t) = self
            .0
            .get("icon_type")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            return t.to_string();
        }
        if let Some(t) = self
            .0
            .get("main_item")
            .and_then(|m| m.get("type"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            return t.to_string();
        }
        if let Some(t) = self
            .0
            .get("action")
            .and_then(|a| a.get("type"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            return t.to_string();
        }
        String::new()
    }

    fn extract_header_title(&self) -> Option<String> {
        let header = self
            .0
            .get("header")
            .and_then(|v| v.as_str().or_else(|| v.get("text").and_then(|t| t.as_str())))
            .or_else(|| self.0.get("title").and_then(|v| v.as_str()));
        header
            .map(clean_vk_mentions)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    fn extract_actor_id(&self) -> i64 {
        // Legacy feedback object
        if let Some(fb) = self.0.get("feedback") {
            if let Some(id) = fb.get("from_id").and_then(|v| v.as_i64()) {
                return id;
            }
            if let Some(id) = fb.get("owner_id").and_then(|v| v.as_i64()) {
                return id;
            }
            if let Some(arr) = fb.get("items").and_then(|v| v.as_array()) {
                if let Some(first) = arr.first() {
                    if let Some(id) = first
                        .get("from_id")
                        .or_else(|| first.get("id"))
                        .and_then(|v| v.as_i64())
                    {
                        return id;
                    }
                }
            }
        }
        // Modern v5.199 notification format
        for key in ["main_item", "action", "header"] {
            if let Some(obj) = self.0.get(key) {
                if let Some(id) = obj
                    .get("from_id")
                    .or_else(|| obj.get("source_id"))
                    .or_else(|| obj.get("user_id"))
                    .or_else(|| obj.get("owner_id"))
                    .and_then(|v| v.as_i64())
                {
                    if id != 0 {
                        return id;
                    }
                }
                if let Some(arr) = obj.get("image_object").and_then(|v| v.as_array()) {
                    if let Some(first) = arr.first() {
                        if let Some(id) = first
                            .get("from_id")
                            .or_else(|| first.get("id"))
                            .and_then(|v| v.as_i64())
                        {
                            if id != 0 {
                                return id;
                            }
                        }
                    }
                }
            }
        }
        self.0
            .get("from_id")
            .or_else(|| self.0.get("source_id"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
    }

    fn extract_target_and_text(&self) -> (Option<i64>, Option<i64>, String) {
        let mut owner_id = None;
        let mut post_id = None;
        if let Some(p) = self.0.get("parent") {
            owner_id = p
                .get("owner_id")
                .or_else(|| p.get("to_id"))
                .and_then(|v| v.as_i64());
            post_id = p.get("id").and_then(|v| v.as_i64());
            if post_id.is_none() {
                if let Some(post) = p.get("post") {
                    owner_id = owner_id.or_else(|| post.get("owner_id").and_then(|v| v.as_i64()));
                    post_id = post.get("id").and_then(|v| v.as_i64());
                }
            }
        }
        if owner_id.is_none() {
            owner_id = self
                .0
                .get("action")
                .and_then(|a| a.get("owner_id"))
                .and_then(|v| v.as_i64());
        }
        if post_id.is_none() {
            post_id = self
                .0
                .get("action")
                .and_then(|a| a.get("item_id").or_else(|| a.get("post_id")))
                .and_then(|v| v.as_i64());
        }

        let text = self
            .0
            .get("feedback")
            .and_then(|fb| fb.get("text").and_then(|v| v.as_str()))
            .or_else(|| {
                self.0
                    .get("main_item")
                    .and_then(|m| m.get("text").and_then(|v| v.as_str()))
            })
            .or_else(|| self.0.get("text").and_then(|v| v.as_str()))
            .or_else(|| self.0.get("body").and_then(|v| v.as_str()))
            .or_else(|| {
                self.0
                    .get("footer")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.contains("{date}"))
            })
            .map(clean_vk_mentions)
            .unwrap_or_default();
        (owner_id, post_id, text)
    }

    fn extract_image_url(&self) -> Option<String> {
        for key in ["main_item", "header"] {
            if let Some(obj) = self.0.get(key) {
                if let Some(arr) = obj.get("image_object").and_then(|v| v.as_array()) {
                    for item in arr {
                        for field in ["photo_200", "photo_100", "photo_50", "url"] {
                            if let Some(u) = item.get(field).and_then(|v| v.as_str()) {
                                if !u.trim().is_empty() {
                                    return Some(u.to_string());
                                }
                            }
                        }
                    }
                }
                if let Some(u) = obj.get("icon_url").and_then(|v| v.as_str()) {
                    if !u.trim().is_empty() {
                        return Some(u.to_string());
                    }
                }
            }
        }
        None
    }
}

fn clean_vk_mentions(raw: &str) -> String {
    // Convert "[id123|Name]" or "[club123|Group]" into "Name" and strip VK wiki bold '''...'''
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find('[') {
        out.push_str(&rest[..start]);
        let after_bracket = &rest[start + 1..];
        if let Some(end) = after_bracket.find(']') {
            let inner = &after_bracket[..end];
            if let Some((_, label)) = inner.split_once('|') {
                out.push_str(label);
            } else {
                out.push('[');
                out.push_str(inner);
                out.push(']');
            }
            rest = &after_bracket[end + 1..];
        } else {
            out.push('[');
            rest = after_bracket;
            break;
        }
    }
    out.push_str(rest);
    out.replace("'''", "").replace("''", "")
}

#[derive(Debug, Deserialize)]
struct RawVideoListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawVideo>,
}

#[derive(Debug, Deserialize)]
struct RawVideoImage {
    url: Option<String>,
    #[serde(default)]
    width: u32,
}

#[derive(Debug, Deserialize)]
struct RawVideoFiles {
    hls: Option<String>,
    hls_ondemand: Option<String>,
    mp4_1080: Option<String>,
    mp4_720: Option<String>,
    mp4_480: Option<String>,
    mp4_360: Option<String>,
    mp4_240: Option<String>,
}

impl RawVideoFiles {
    fn into_qualities_and_best(self) -> (Vec<VideoQualityOption>, Option<String>) {
        let mut qualities = Vec::new();
        for (label, opt) in [
            ("1080p", self.mp4_1080),
            ("720p", self.mp4_720),
            ("480p", self.mp4_480),
            ("360p", self.mp4_360),
            ("240p", self.mp4_240),
            ("HLS (Авто)", self.hls.or(self.hls_ondemand)),
        ] {
            if let Some(url) = non_empty(opt) {
                qualities.push(VideoQualityOption {
                    label: label.to_string(),
                    url,
                });
            }
        }
        let best = qualities.first().map(|q| q.url.clone());
        (qualities, best)
    }
}

#[derive(Debug, Deserialize)]
struct RawVideo {
    #[serde(default)]
    id: i64,
    #[serde(default)]
    owner_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    title: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    description: String,
    #[serde(default)]
    duration: u32,
    #[serde(default)]
    views: u32,
    access_key: Option<String>,
    player: Option<String>,
    files: Option<RawVideoFiles>,
    photo_320: Option<String>,
    photo_800: Option<String>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    image: Vec<RawVideoImage>,
}

impl RawVideo {
    fn into_video_item(self) -> VideoItem {
        let thumb = non_empty(self.photo_800)
            .or_else(|| non_empty(self.photo_320))
            .or_else(|| {
                self.image
                    .into_iter()
                    .filter_map(|img| non_empty(img.url).map(|u| (img.width, u)))
                    .max_by_key(|(w, _)| *w)
                    .map(|(_, u)| u)
            });
        let (qualities, stream_url) = self
            .files
            .map(RawVideoFiles::into_qualities_and_best)
            .unwrap_or_default();
        VideoItem {
            id: self.id,
            owner_id: self.owner_id,
            access_key: non_empty(self.access_key),
            title: if self.title.is_empty() {
                "Видео".to_string()
            } else {
                self.title
            },
            description: self.description,
            duration_sec: self.duration,
            thumbnail_url: thumb,
            player_url: non_empty(self.player),
            stream_url,
            qualities,
            views: self.views,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawAudioPlaylistsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawAudioPlaylist>,
}

#[derive(Debug, Deserialize)]
struct RawAudioPlaylist {
    id: i64,
    owner_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    title: String,
    #[serde(default)]
    count: u32,
    photo: Option<RawAudioThumb>,
}

impl RawAudioPlaylist {
    fn into_playlist(self) -> AudioPlaylist {
        let cover_url = self.photo.and_then(|p| {
            non_empty(p.photo_300)
                .or_else(|| non_empty(p.photo_270))
                .or_else(|| non_empty(p.photo_135))
        });
        AudioPlaylist {
            id: self.id,
            owner_id: self.owner_id,
            title: self.title,
            count: self.count,
            cover_url,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawUploadServerResponse {
    upload_url: String,
}

#[derive(Debug, Deserialize)]
struct RawPhotoUploadResponse {
    server: i64,
    photo: String,
    hash: String,
}

#[derive(Debug, Deserialize)]
struct RawSavedPhoto {
    id: i64,
    owner_id: i64,
}

#[derive(Debug, Deserialize)]
struct RawAudioMessage {
    #[serde(default)]
    duration: u32,
    link_mp3: Option<String>,
    link_ogg: Option<String>,
    transcript: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPoll {
    id: i64,
    #[serde(default)]
    owner_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    question: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    answers: Vec<RawPollAnswer>,
}

#[derive(Debug, Deserialize)]
struct RawPollAnswer {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    text: String,
    #[serde(default)]
    votes: u32,
    #[serde(default)]
    rate: f64,
}

#[derive(Debug, Deserialize)]
struct RawDocUploadResponse {
    file: Option<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawStickerProductsResponse {
    Object {
        #[serde(default, deserialize_with = "deserialize_null_default")]
        items: Vec<RawStickerPack>,
    },
    List(Vec<RawStickerPack>),
}

#[derive(Debug, Deserialize)]
struct RawStickerPack {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    title: String,
    icon: Option<RawStickerIcon>,
    previews: Option<Vec<RawStoreStickerImage>>,
    stickers: Option<Vec<RawStickerDef>>,
    sticker_ids: Option<Vec<i64>>,
}

#[derive(Debug, Deserialize)]
struct RawStickerIcon {
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawStickerDef {
    sticker_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    images: Vec<RawStoreStickerImage>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    images_with_background: Vec<RawStoreStickerImage>,
}

#[derive(Debug, Deserialize)]
struct RawStoreStickerImage {
    url: String,
    #[serde(default)]
    width: u32,
}

#[derive(Debug, Deserialize)]
struct RawHistoryAttachmentsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawHistoryAttachmentEntry>,
}

#[derive(Debug, Deserialize)]
struct RawHistoryAttachmentEntry {
    attachment: Option<RawAttachment>,
}

#[derive(Debug, Deserialize)]
struct RawAudioLyricsMeta {
    lyrics_id: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RawLyricsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    text: String,
}

#[derive(Debug, Deserialize)]
struct RawBirthdayListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawBirthdayUser>,
}

#[derive(Debug, Deserialize)]
struct RawBirthdayUser {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    first_name: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    last_name: String,
    photo_50: Option<String>,
    photo_100: Option<String>,
    photo_200: Option<String>,
    bdate: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPhotosAllResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawPhoto>,
}

#[derive(Debug, Deserialize)]
struct RawPlaylistId {
    id: i64,
}

#[derive(Debug, Deserialize)]
struct RawBannedResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawOwnerUser>,
}

#[derive(Debug, Deserialize)]
struct RawFriendRequestsResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawFriendRequestEntry>,
}

#[derive(Debug, Deserialize)]
struct RawFriendRequestEntry {
    user_id: i64,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawFavePagesResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawFavePageEntry>,
}

#[derive(Debug, Deserialize)]
struct RawFavePageEntry {
    user: Option<RawOwnerUser>,
    group: Option<RawOwnerGroup>,
}

fn encode_wav_to_mp3(bytes: &[u8]) -> Result<Vec<u8>, VkError> {
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(VkError::InvalidInput {
            details: "Неверный формат WAV-записи".to_string(),
        });
    }
    let mut pos = 12usize;
    let mut channels: u16 = 1;
    let mut sample_rate: u32 = 16000;
    let mut bits_per_sample: u16 = 16;
    let mut pcm_data: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let chunk_id = &bytes[pos..pos + 4];
        let chunk_size = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        let data_start = pos + 8;
        let data_end = data_start.saturating_add(chunk_size).min(bytes.len());
        if chunk_id == b"fmt " && data_end >= data_start + 16 {
            channels = u16::from_le_bytes([bytes[data_start + 2], bytes[data_start + 3]]);
            sample_rate = u32::from_le_bytes([
                bytes[data_start + 4],
                bytes[data_start + 5],
                bytes[data_start + 6],
                bytes[data_start + 7],
            ]);
            bits_per_sample = u16::from_le_bytes([bytes[data_start + 14], bytes[data_start + 15]]);
        } else if chunk_id == b"data" {
            pcm_data = Some(&bytes[data_start..data_end]);
            break;
        }
        pos = data_start + chunk_size + (chunk_size % 2);
    }

    let pcm = pcm_data.ok_or_else(|| VkError::InvalidInput {
        details: "В WAV-файле отсутствует data chunk".to_string(),
    })?;
    if bits_per_sample != 16 || (channels != 1 && channels != 2) {
        return Err(VkError::InvalidInput {
            details: format!("Неподдерживаемый WAV формат: {channels}ch {bits_per_sample}bit"),
        });
    }

    let samples: Vec<i16> = pcm
        .chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]))
        .collect();

    let mut builder = mp3lame_encoder::Builder::new().ok_or_else(|| VkError::Internal {
        details: "Не удалось создать LAME MP3 encoder".to_string(),
    })?;
    builder
        .set_num_channels(channels as u8)
        .map_err(|e| VkError::Internal { details: format!("MP3 channels: {e:?}") })?;
    builder
        .set_sample_rate(sample_rate)
        .map_err(|e| VkError::Internal { details: format!("MP3 sample_rate: {e:?}") })?;
    builder
        .set_brate(mp3lame_encoder::Bitrate::Kbps64)
        .map_err(|e| VkError::Internal { details: format!("MP3 bitrate: {e:?}") })?;
    builder
        .set_quality(mp3lame_encoder::Quality::Good)
        .map_err(|e| VkError::Internal { details: format!("MP3 quality: {e:?}") })?;
    let mut encoder = builder
        .build()
        .map_err(|e| VkError::Internal { details: format!("MP3 build: {e:?}") })?;

    let mut mp3_out = Vec::with_capacity(mp3lame_encoder::max_required_buffer_size(samples.len()));
    if channels == 1 {
        let input = mp3lame_encoder::MonoPcm(&samples);
        encoder
            .encode_to_vec(input, &mut mp3_out)
            .map_err(|e| VkError::Internal { details: format!("MP3 encode: {e:?}") })?;
    } else {
        let input = mp3lame_encoder::InterleavedPcm(&samples);
        encoder
            .encode_to_vec(input, &mut mp3_out)
            .map_err(|e| VkError::Internal { details: format!("MP3 encode: {e:?}") })?;
    }
    encoder
        .flush_to_vec::<mp3lame_encoder::FlushNoGap>(&mut mp3_out)
        .map_err(|e| VkError::Internal { details: format!("MP3 flush: {e:?}") })?;
    Ok(mp3_out)
}

#[derive(Debug, Deserialize)]
struct RawDocSaveResponse {
    doc: Option<RawSavedPhoto>,
    audio_message: Option<RawSavedPhoto>,
}

#[derive(Debug, Deserialize)]
struct RawChatMembersResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawChatMemberItem>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
}

#[derive(Debug, Deserialize)]
struct RawChatMemberItem {
    member_id: i64,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    is_admin: bool,
}

#[derive(Debug, Deserialize)]
struct RawLastSeen {
    time: i64,
}

#[derive(Debug, Deserialize)]
struct RawPresenceUser {
    id: i64,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    online: bool,
    last_seen: Option<RawLastSeen>,
}

#[derive(Debug, Deserialize)]
struct RawStoriesResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawStoryBucket>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
struct RawStoryBucket {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    stories: Vec<RawStory>,
}

#[derive(Debug, Deserialize)]
struct RawStory {
    id: i64,
    owner_id: i64,
    #[serde(default)]
    date: i64,
    #[serde(rename = "type")]
    story_type: Option<String>,
    photo: Option<RawPhoto>,
    video: Option<RawVideo>,
}

#[derive(Debug, Deserialize)]
struct RawFaveResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawFaveEntry>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    profiles: Vec<RawUser>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    groups: Vec<RawGroup>,
}

#[derive(Debug, Deserialize)]
struct RawFaveEntry {
    #[serde(rename = "type", default)]
    kind: String,
    post: Option<RawNewsfeedItem>,
    link: Option<RawLink>,
}

fn map_post_items(
    items: Vec<RawNewsfeedItem>,
    raw_profiles: Vec<RawUser>,
    raw_groups: Vec<RawGroup>,
) -> Vec<FeedPost> {
    let profiles: HashMap<i64, UserProfile> = raw_profiles
        .into_iter()
        .map(RawUser::into_profile)
        .map(|u| (u.id, u))
        .collect();
    let groups: HashMap<i64, RawGroup> = raw_groups.into_iter().map(|g| (g.id, g)).collect();
    map_post_items_with_maps(items, &profiles, &groups)
}

fn map_post_items_with_maps(
    items: Vec<RawNewsfeedItem>,
    profiles: &HashMap<i64, UserProfile>,
    groups: &HashMap<i64, RawGroup>,
) -> Vec<FeedPost> {

    let mut posts = Vec::with_capacity(items.len());
    for item in items {
        if let Some(ref kind) = item.item_type {
            if kind != "post" {
                continue;
            }
        }
        let post_id = item.post_id.or(item.id).unwrap_or(0);
        if post_id == 0 {
            continue;
        }

        let source_id = if item.source_id != 0 {
            item.source_id
        } else if item.from_id != 0 {
            item.from_id
        } else {
            item.owner_id
        };
        let (author_name, author_avatar) = resolve_author(source_id, &profiles, &groups);

        let mut text_parts: Vec<String> = Vec::new();
        if !item.text.trim().is_empty() {
            text_parts.push(item.text);
        }

        let mut all_raw_attachments = item.attachments;
        for repost in item.copy_history {
            let repost_owner = if repost.owner_id != 0 {
                repost.owner_id
            } else if repost.from_id != 0 {
                repost.from_id
            } else {
                repost.source_id
            };
            if !repost.text.trim().is_empty() {
                if repost_owner != 0 {
                    let (repost_author, _) = resolve_author(repost_owner, &profiles, &groups);
                    text_parts.push(format!("↻ {repost_author}:\n{}", repost.text));
                } else {
                    text_parts.push(repost.text);
                }
            }
            all_raw_attachments.extend(repost.attachments);
        }

        let mut photos = Vec::new();
        let mut attachments = Vec::new();
        for raw_att in all_raw_attachments {
            if let Some(parsed) = parse_attachment(raw_att) {
                match &parsed {
                    Attachment::Photo { url, .. } => photos.push(url.clone()),
                    _ => attachments.push(parsed),
                }
            }
        }

        let (likes_count, is_liked) = match item.likes {
            Some(likes) => (likes.count, likes.user_likes),
            None => (0, false),
        };
        let comments_count = item.comments.map_or(0, |c| c.count);

        posts.push(FeedPost {
            post_id,
            source_id: if item.owner_id != 0 && item.source_id == 0 {
                item.owner_id
            } else {
                source_id
            },
            author_name,
            author_avatar,
            date: item.date,
            text: text_parts.join("\n\n"),
            photos,
            attachments,
            likes_count,
            is_liked,
            comments_count,
            is_ads: item.marked_as_ads,
        });
    }
    posts
}

#[derive(Debug, Deserialize)]
struct RawLikesInfo {
    #[serde(default)]
    count: u32,
    #[serde(default, deserialize_with = "deserialize_bool_from_int_or_bool")]
    user_likes: bool,
}

#[derive(Debug, Deserialize)]
struct RawCommentsInfo {
    #[serde(default)]
    count: u32,
}

#[derive(Debug, Deserialize)]
struct RawLikesResponse {
    likes: u32,
}

#[derive(Debug, Deserialize)]
struct RawAudioListResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    items: Vec<RawAudio>,
}

#[derive(Debug, Deserialize)]
struct RawAudio {
    #[serde(default)]
    id: i64,
    #[serde(default)]
    owner_id: i64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    artist: String,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    title: String,
    #[serde(default)]
    duration: u32,
    url: Option<String>,
    album: Option<RawAudioAlbum>,
}

impl RawAudio {
    fn into_track(self) -> AudioTrack {
        let cover_url = self
            .album
            .and_then(|a| a.thumb)
            .and_then(|t| t.best_cover_url());
        AudioTrack {
            id: self.id,
            owner_id: self.owner_id,
            artist: self.artist,
            title: self.title,
            duration_sec: self.duration,
            stream_url: non_empty(self.url),
            cover_url,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawAudioAlbum {
    thumb: Option<RawAudioThumb>,
}

#[derive(Debug, Deserialize)]
struct RawAudioThumb {
    photo_135: Option<String>,
    photo_270: Option<String>,
    photo_300: Option<String>,
    photo_600: Option<String>,
    photo_1200: Option<String>,
}

impl RawAudioThumb {
    fn best_cover_url(self) -> Option<String> {
        non_empty(self.photo_300)
            .or_else(|| non_empty(self.photo_270))
            .or_else(|| non_empty(self.photo_600))
            .or_else(|| non_empty(self.photo_1200))
            .or_else(|| non_empty(self.photo_135))
    }
}

fn deserialize_null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    T: Default + Deserialize<'de>,
    D: Deserializer<'de>,
{
    let opt = Option::deserialize(deserializer)?;
    Ok(opt.unwrap_or_default())
}

pub(crate) fn deserialize_bool_from_int_or_bool<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    struct BoolOrIntVisitor;

    impl<'de> Visitor<'de> for BoolOrIntVisitor {
        type Value = bool;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a boolean, 0/1 integer, or null")
        }

        fn visit_bool<E: de::Error>(self, v: bool) -> Result<bool, E> {
            Ok(v)
        }

        fn visit_i64<E: de::Error>(self, v: i64) -> Result<bool, E> {
            Ok(v != 0)
        }

        fn visit_u64<E: de::Error>(self, v: u64) -> Result<bool, E> {
            Ok(v != 0)
        }

        fn visit_unit<E: de::Error>(self) -> Result<bool, E> {
            Ok(false)
        }

        fn visit_none<E: de::Error>(self) -> Result<bool, E> {
            Ok(false)
        }
    }

    deserializer.deserialize_any(BoolOrIntVisitor)
}

pub(crate) fn deserialize_u64_from_int_or_str<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    struct U64OrStrVisitor;

    impl<'de> Visitor<'de> for U64OrStrVisitor {
        type Value = u64;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("an unsigned integer or numeric string")
        }

        fn visit_u64<E: de::Error>(self, v: u64) -> Result<u64, E> {
            Ok(v)
        }

        fn visit_i64<E: de::Error>(self, v: i64) -> Result<u64, E> {
            u64::try_from(v).map_err(|_| E::custom(format!("negative integer for u64: {v}")))
        }

        fn visit_str<E: de::Error>(self, v: &str) -> Result<u64, E> {
            v.trim()
                .parse::<u64>()
                .map_err(|err| E::custom(format!("invalid u64 string '{v}': {err}")))
        }
    }

    deserializer.deserialize_any(U64OrStrVisitor)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Arc;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use url::form_urlencoded;

    use super::*;

    #[derive(Debug, Clone)]
    struct CapturedApiRequest {
        path: String,
        params: BTreeMap<String, String>,
        user_agent: Option<String>,
    }

    struct MockVkServer {
        base_url: String,
        requests: Arc<tokio::sync::Mutex<Vec<CapturedApiRequest>>>,
        handle: tokio::task::JoinHandle<()>,
    }

    impl Drop for MockVkServer {
        fn drop(&mut self) {
            self.handle.abort();
        }
    }

    impl MockVkServer {
        async fn start(responses: Vec<(u16, &'static str, String)>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let base_url = format!("http://127.0.0.1:{port}/method/");

            let resp_ref = Arc::new(tokio::sync::Mutex::new(VecDeque::from(responses)));
            let requests = Arc::new(tokio::sync::Mutex::new(Vec::new()));
            let req_ref = Arc::clone(&requests);

            let handle = tokio::spawn(async move {
                loop {
                    let Ok((mut socket, _)) = listener.accept().await else {
                        break;
                    };

                    let resp_ref = Arc::clone(&resp_ref);
                    let req_ref = Arc::clone(&req_ref);

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

                        let headers_str = String::from_utf8_lossy(&buf[..header_end]);
                        let mut lines = headers_str.lines();
                        let request_line = lines.next().unwrap_or("");
                        let path = request_line
                            .split_whitespace()
                            .nth(1)
                            .unwrap_or("/")
                            .split('?')
                            .next()
                            .unwrap_or("/")
                            .to_string();

                        let mut content_length = 0usize;
                        let mut user_agent = None;
                        for line in lines {
                            if let Some((name, val)) = line.split_once(':') {
                                if name.trim().eq_ignore_ascii_case("content-length") {
                                    content_length = val.trim().parse::<usize>().unwrap_or(0);
                                } else if name.trim().eq_ignore_ascii_case("user-agent") {
                                    user_agent = Some(val.trim().to_string());
                                }
                            }
                        }

                        while buf.len() < header_end + content_length {
                            let n = match socket.read(&mut tmp).await {
                                Ok(0) | Err(_) => break,
                                Ok(n) => n,
                            };
                            buf.extend_from_slice(&tmp[..n]);
                        }

                        let body =
                            &buf[header_end..(header_end + content_length).min(buf.len())];
                        let params: BTreeMap<String, String> = form_urlencoded::parse(body)
                            .map(|(k, v)| (k.into_owned(), v.into_owned()))
                            .collect();

                        req_ref.lock().await.push(CapturedApiRequest {
                            path,
                            params,
                            user_agent,
                        });

                        let (status, ct, resp_body) = resp_ref
                            .lock()
                            .await
                            .pop_front()
                            .unwrap_or((500, "text/plain", "no queued mock response".to_string()));

                        let reason = match status {
                            200 => "OK",
                            401 => "Unauthorized",
                            429 => "Too Many Requests",
                            502 => "Bad Gateway",
                            _ => "Error",
                        };

                        let raw_http = format!(
                            "HTTP/1.1 {status} {reason}\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resp_body}",
                            resp_body.len()
                        );
                        let _ = socket.write_all(raw_http.as_bytes()).await;
                        let _ = socket.shutdown().await;
                    });
                }
            });

            Self {
                base_url,
                requests,
                handle,
            }
        }

        async fn requests(&self) -> Vec<CapturedApiRequest> {
            self.requests.lock().await.clone()
        }
    }

    fn test_client(base_url: &str) -> VkApiClient {
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        VkApiClient::with_client(http, base_url)
    }

    #[tokio::test]
    async fn test_rate_limiter_sliding_window() {
        // Test fast sliding-window behavior with 3 permits per 150ms window
        let limiter = RateLimiter::new(3, Duration::from_millis(150));
        let start = tokio::time::Instant::now();

        let mut timestamps = Vec::new();
        for _ in 0..7 {
            limiter.acquire().await;
            timestamps.push(tokio::time::Instant::now().duration_since(start));
        }

        // First 3 permits complete immediately
        assert!(timestamps[2] < Duration::from_millis(75));
        // Permits 4..6 wait at least one full 150ms window
        assert!(timestamps[3] >= Duration::from_millis(140));
        assert!(timestamps[5] < Duration::from_millis(280));
        // Permit 7 waits at least two full windows (300ms)
        assert!(timestamps[6] >= Duration::from_millis(290));

        // After a full window elapses, next permit is immediate
        tokio::time::sleep(Duration::from_millis(160)).await;
        let before = tokio::time::Instant::now();
        limiter.acquire().await;
        assert!(before.elapsed() < Duration::from_millis(50));
    }

    #[tokio::test]
    async fn test_get_conversations_resolves_dm_group_chat_mute_and_attachment_preview() {
        let fixture = r#"{
            "response": {
                "count": 3,
                "items": [
                    {
                        "conversation": {
                            "peer": {"id": 1001, "type": "user"},
                            "unread_count": 2
                        },
                        "last_message": {
                            "id": 10,
                            "from_id": 1001,
                            "peer_id": 1001,
                            "text": "Привет!",
                            "date": 1700000100,
                            "out": 0,
                            "attachments": []
                        }
                    },
                    {
                        "conversation": {
                            "peer": {"id": -555, "type": "group"},
                            "unread_count": 0,
                            "push_settings": {"disabled_forever": true}
                        },
                        "last_message": {
                            "id": 11,
                            "from_id": -555,
                            "peer_id": -555,
                            "text": "",
                            "date": 1700000200,
                            "out": 0,
                            "attachments": [
                                {"type": "photo", "photo": {"sizes": [{"type": "m", "url": "https://cdn/m.jpg", "width": 130, "height": 130}]}}
                            ]
                        }
                    },
                    {
                        "conversation": {
                            "peer": {"id": 2000000007, "type": "chat"},
                            "unread_count": 5,
                            "chat_settings": {
                                "title": "Rust Team",
                                "photo": {"photo_100": "https://cdn/chat100.jpg", "photo_200": "https://cdn/chat200.jpg"}
                            },
                            "push_settings": {"disabled_until": -1}
                        },
                        "last_message": {
                            "id": 12,
                            "from_id": 42,
                            "peer_id": 2000000007,
                            "text": "Ship it",
                            "date": 1700000300,
                            "out": 1,
                            "attachments": []
                        }
                    }
                ],
                "profiles": [
                    {"id": 1001, "first_name": "Alice", "last_name": "Smith", "photo_200": "https://cdn/alice.jpg", "online": 1}
                ],
                "groups": [
                    {"id": 555, "name": "VK News", "photo_100": "https://cdn/group100.jpg"}
                ]
            }
        }"#;

        let server = MockVkServer::start(vec![(200, "application/json", fixture.to_string())]).await;
        let client = test_client(&server.base_url);

        let page = client
            .get_conversations_with_profiles("tok_123", 0, 20)
            .await
            .unwrap();

        assert_eq!(page.profiles.len(), 1);
        assert!(page.profiles[0].online);
        assert_eq!(page.items.len(), 3);

        assert_eq!(
            page.items[0],
            ConversationItem {
                peer_id: 1001,
                title: "Alice Smith".to_string(),
                avatar_url: Some("https://cdn/alice.jpg".to_string()),
                last_message_text: "Привет!".to_string(),
                last_message_date: 1700000100,
                unread_count: 2,
                is_muted: false,
            }
        );
        assert_eq!(
            page.items[1],
            ConversationItem {
                peer_id: -555,
                title: "VK News".to_string(),
                avatar_url: Some("https://cdn/group100.jpg".to_string()),
                last_message_text: "[Фото]".to_string(),
                last_message_date: 1700000200,
                unread_count: 0,
                is_muted: true,
            }
        );
        assert_eq!(
            page.items[2],
            ConversationItem {
                peer_id: 2000000007,
                title: "Rust Team".to_string(),
                avatar_url: Some("https://cdn/chat200.jpg".to_string()),
                last_message_text: "Ship it".to_string(),
                last_message_date: 1700000300,
                unread_count: 5,
                is_muted: true,
            }
        );

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].path, "/method/messages.getConversations");
        assert_eq!(reqs[0].params.get("v").unwrap(), VK_API_VERSION);
        assert_eq!(reqs[0].params.get("access_token").unwrap(), "tok_123");
        assert_eq!(reqs[0].params.get("extended").unwrap(), "1");
        assert_eq!(reqs[0].user_agent.as_deref(), Some(VK_USER_AGENT));
    }

    #[tokio::test]
    async fn test_get_history_maps_all_attachment_variants() {
        let fixture = r#"{
            "response": {
                "count": 2,
                "items": [
                    {
                        "id": 501,
                        "peer_id": 1001,
                        "from_id": 1001,
                        "text": "Media bundle",
                        "date": 1700000500,
                        "out": 0,
                        "attachments": [
                            {
                                "type": "photo",
                                "photo": {
                                    "sizes": [
                                        {"type": "s", "url": "https://cdn/s.jpg", "width": 75, "height": 50},
                                        {"type": "z", "url": "https://cdn/z.jpg", "width": 1280, "height": 720}
                                    ]
                                }
                            },
                            {
                                "type": "audio",
                                "audio": {
                                    "artist": "Kino",
                                    "title": "Gruppa Krovi",
                                    "duration": 284,
                                    "url": ""
                                }
                            },
                            {
                                "type": "doc",
                                "doc": {"title": "spec.pdf", "url": "https://cdn/spec.pdf", "ext": "pdf"}
                            },
                            {
                                "type": "sticker",
                                "sticker": {
                                    "images": [
                                        {"url": "https://cdn/st64.png", "width": 64},
                                        {"url": "https://cdn/st256.png", "width": 256}
                                    ]
                                }
                            },
                            {
                                "type": "link",
                                "link": {"title": "Rust Lang", "url": "https://rust-lang.org"}
                            },
                            {
                                "type": "wall_reply"
                            }
                        ]
                    },
                    {
                        "id": 502,
                        "peer_id": 1001,
                        "from_id": 42,
                        "text": "Reply",
                        "date": 1700000510,
                        "out": 1,
                        "attachments": []
                    }
                ],
                "profiles": []
            }
        }"#;

        let server = MockVkServer::start(vec![(200, "application/json", fixture.to_string())]).await;
        let client = test_client(&server.base_url);

        let msgs = client.get_history("tok", 1001, 0, 50).await.unwrap();
        assert_eq!(msgs.len(), 2);
        assert!(!msgs[0].is_out);
        assert!(msgs[1].is_out);
        assert_eq!(
            msgs[0].attachments,
            vec![
                Attachment::Photo {
                    url: "https://cdn/z.jpg".to_string(),
                    width: Some(1280),
                    height: Some(720),
                },
                Attachment::Audio {
                    artist: "Kino".to_string(),
                    title: "Gruppa Krovi".to_string(),
                    duration_sec: 284,
                    url: None,
                },
                Attachment::Document {
                    title: "spec.pdf".to_string(),
                    url: "https://cdn/spec.pdf".to_string(),
                    ext: "pdf".to_string(),
                },
                Attachment::Sticker {
                    url: "https://cdn/st256.png".to_string(),
                },
                Attachment::Link {
                    title: "Rust Lang".to_string(),
                    url: "https://rust-lang.org".to_string(),
                },
                Attachment::Unknown {
                    kind: "wall_reply".to_string(),
                },
            ]
        );
    }

    #[tokio::test]
    async fn test_send_message_newsfeed_likes_audio_users_and_longpoll_server() {
        let server = MockVkServer::start(vec![
            (200, "application/json", r#"{"response": 9001}"#.to_string()),
            (200, "application/json", r#"{"response": 9002}"#.to_string()),
            (
                200,
                "application/json",
                r#"{
                    "response": {
                        "items": [
                            {
                                "type": "post",
                                "post_id": 77,
                                "source_id": -10,
                                "date": 1700001000,
                                "text": "Release!",
                                "attachments": [
                                    {"type": "photo", "photo": {"sizes": [{"type": "x", "url": "https://cdn/post.jpg", "width": 604, "height": 400}]}}
                                ],
                                "likes": {"count": 15, "user_likes": 1},
                                "comments": {"count": 4}
                            },
                            {
                                "type": "friend",
                                "post_id": 88,
                                "source_id": 1
                            }
                        ],
                        "profiles": [],
                        "groups": [{"id": 10, "name": "Rust Club", "photo_200": "https://cdn/rc.jpg"}],
                        "next_from": "next_cursor_2"
                    }
                }"#
                .to_string(),
            ),
            (200, "application/json", r#"{"response": {"likes": 16}}"#.to_string()),
            (200, "application/json", r#"{"response": {"likes": 15}}"#.to_string()),
            (
                200,
                "application/json",
                r#"{
                    "response": {
                        "count": 2,
                        "items": [
                            {
                                "id": 1,
                                "owner_id": 42,
                                "artist": "Artist",
                                "title": "Song",
                                "duration": 210,
                                "url": "https://cdn/audio/index.m3u8",
                                "album": {"thumb": {"photo_300": "https://cdn/cov300.jpg"}}
                            },
                            {
                                "id": 2,
                                "owner_id": 42,
                                "artist": "Restricted",
                                "title": "NoURL",
                                "duration": 180,
                                "url": ""
                            }
                        ]
                    }
                }"#
                .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"response": {"count": 1, "items": [{"id": 3, "owner_id": 9, "artist": "Found", "title": "Hit", "duration": 150, "url": "https://cdn/hit.m3u8"}]}}"#
                    .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"response": [{"id": 42, "first_name": "Bob", "last_name": "Jones", "photo_100": "https://cdn/bob.jpg", "online": true}]}"#
                    .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"response": {"key": "lp_key", "server": "im.vk.com/nim1", "ts": "424242"}}"#
                    .to_string(),
            ),
        ])
        .await;
        let client = test_client(&server.base_url);

        // Empty message rejected locally
        assert!(matches!(
            client.send_message("tok", 1001, "   ").await.unwrap_err(),
            VkError::InvalidInput { .. }
        ));

        let id1 = client.send_message("tok", 1001, "Hello").await.unwrap();
        let id2 = client.send_message("tok", 1001, "World").await.unwrap();
        assert_eq!(id1, 9001);
        assert_eq!(id2, 9002);

        let feed = client.get_newsfeed("tok", None, 20).await.unwrap();
        assert_eq!(feed.next_from.as_deref(), Some("next_cursor_2"));
        assert_eq!(feed.items.len(), 1);
        assert_eq!(feed.items[0].author_name, "Rust Club");
        assert_eq!(feed.items[0].photos, vec!["https://cdn/post.jpg"]);
        assert!(feed.items[0].is_liked);
        assert_eq!(feed.items[0].likes_count, 15);
        assert_eq!(feed.items[0].comments_count, 4);

        assert_eq!(client.like_post("tok", -10, 77).await.unwrap(), 16);
        assert_eq!(client.unlike_post("tok", -10, 77).await.unwrap(), 15);

        let audio = client.get_audio("tok", 0, 50).await.unwrap();
        assert_eq!(audio.len(), 2);
        assert_eq!(
            audio[0].stream_url.as_deref(),
            Some("https://cdn/audio/index.m3u8")
        );
        assert_eq!(
            audio[0].cover_url.as_deref(),
            Some("https://cdn/cov300.jpg")
        );
        assert_eq!(audio[1].stream_url, None);

        assert!(matches!(
            client.search_audio("tok", "   ", 0, 10).await.unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        let found = client.search_audio("tok", "Hit", 0, 10).await.unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].title, "Hit");

        let me = client.get_current_user("tok").await.unwrap().unwrap();
        assert_eq!(me.id, 42);
        assert!(me.online);

        let lp = client.get_long_poll_server("tok").await.unwrap();
        assert_eq!(
            lp,
            LongPollServerInfo {
                key: "lp_key".to_string(),
                server: "im.vk.com/nim1".to_string(),
                ts: 424242,
            }
        );

        let reqs = server.requests().await;
        let rid1 = reqs[0].params.get("random_id").unwrap().parse::<i32>().unwrap();
        let rid2 = reqs[1].params.get("random_id").unwrap().parse::<i32>().unwrap();
        assert!(rid1 > 0);
        assert!(rid2 > 0);
        assert_ne!(rid1, rid2);
        assert_eq!(reqs[3].params.get("type").unwrap(), "post");
        assert_eq!(reqs[4].params.get("item_id").unwrap(), "77");
        assert_eq!(reqs[6].params.get("q").unwrap(), "Hit");
        assert_eq!(reqs[8].params.get("lp_version").unwrap(), "3");
    }

    #[tokio::test]
    async fn test_vk_api_error_mapping() {
        let server = MockVkServer::start(vec![
            (
                200,
                "application/json",
                r#"{"error":{"error_code":5,"error_msg":"User authorization failed"}}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"error":{"error_code":6,"error_msg":"Too many requests per second"}}"#
                    .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"error":{"error_code":14,"error_msg":"Captcha needed","captcha_sid":"sid99","captcha_img":"https://vk.com/cap.jpg"}}"#
                    .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"error":{"error_code":17,"error_msg":"Validation required","validation_type":"2fa_sms","phone_mask":"+7 *** 99"}}"#
                    .to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"error":{"error_code":901,"error_msg":"Can't send messages for users without permission"}}"#
                    .to_string(),
            ),
            (429, "text/plain", "slow down".to_string()),
            (502, "text/html", "<html>Bad Gateway</html>".to_string()),
        ])
        .await;
        let client = test_client(&server.base_url);

        // Empty token never hits server
        assert!(matches!(
            client.get_current_user("   ").await.unwrap_err(),
            VkError::InvalidToken
        ));

        assert!(matches!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::InvalidToken
        ));
        assert!(matches!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::RateLimited
        ));
        assert_eq!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::CaptchaRequired {
                sid: "sid99".to_string(),
                img_url: "https://vk.com/cap.jpg".to_string(),
            }
        );
        assert_eq!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::ValidationRequired {
                validation_type: "2fa_sms".to_string(),
                phone_mask: "+7 *** 99".to_string(),
            }
        );
        assert_eq!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::ApiError {
                code: 901,
                message: "Can't send messages for users without permission".to_string(),
            }
        );
        assert!(matches!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::RateLimited
        ));
        assert!(matches!(
            client.get_current_user("tok").await.unwrap_err(),
            VkError::Network { .. }
        ));

        assert_eq!(server.requests().await.len(), 7);
    }

    #[tokio::test]
    async fn test_bot_keyboard_parsing_get_conversation_keyboard_and_send_with_payload() {
        let server = MockVkServer::start(vec![
            (
                200,
                "application/json",
                serde_json::json!({
                    "response": {
                        "count": 1,
                        "items": [
                            {
                                "peer": { "id": -12345, "type": "group" },
                                "unread_count": 0,
                                "current_keyboard": {
                                    "inline": false,
                                    "one_time": true,
                                    "buttons": [
                                        [
                                            {
                                                "color": "positive",
                                                "action": {
                                                    "type": "text",
                                                    "label": "Лайк",
                                                    "payload": { "cmd": "like" }
                                                }
                                            },
                                            {
                                                "color": "primary",
                                                "action": {
                                                    "type": "open_link",
                                                    "label": "Сайт",
                                                    "link": "https://vk.com"
                                                }
                                            }
                                        ],
                                        []
                                    ]
                                }
                            }
                        ]
                    }
                })
                .to_string(),
            ),
            (200, "application/json", r#"{"response": 9090}"#.to_string()),
        ])
        .await;

        let client = test_client(&server.base_url);
        let kb = client
            .get_conversation_keyboard("tok", -12345)
            .await
            .unwrap()
            .expect("expected conversation keyboard");

        assert!(!kb.inline);
        assert!(kb.one_time);
        assert_eq!(kb.rows.len(), 1);
        assert_eq!(kb.rows[0].buttons.len(), 2);
        assert_eq!(kb.rows[0].buttons[0].label, "Лайк");
        assert_eq!(kb.rows[0].buttons[0].color, "positive");
        assert_eq!(kb.rows[0].buttons[0].payload.as_deref(), Some("{\"cmd\":\"like\"}"));
        assert_eq!(kb.rows[0].buttons[1].action_type, "open_link");
        assert_eq!(kb.rows[0].buttons[1].link.as_deref(), Some("https://vk.com"));

        let msg_id = client
            .send_message_with_payload("tok", -12345, "Лайк", Some("{\"cmd\":\"like\"}"))
            .await
            .unwrap();
        assert_eq!(msg_id, 9090);

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 2);
        assert_eq!(reqs[0].path, "/method/messages.getConversationsById");
        assert_eq!(reqs[1].path, "/method/messages.send");
        assert!(format!("{:?}", reqs[1].params).contains("payload"));
    }
}
