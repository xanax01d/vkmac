use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AuthState {
    LoggedOut,
    Needs2FA {
        validation_type: String,
        phone_mask: String,
        redirect_uri: Option<String>,
    },
    NeedsCaptcha {
        sid: String,
        img_url: String,
        redirect_uri: Option<String>,
    },
    Authenticated {
        user_id: i64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct OAuthConfig {
    pub client_id: String,
    pub client_secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct UserProfile {
    pub id: i64,
    pub first_name: String,
    pub last_name: String,
    pub avatar_url: Option<String>,
    pub online: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ConversationItem {
    pub peer_id: i64,
    pub title: String,
    pub avatar_url: Option<String>,
    pub last_message_text: String,
    pub last_message_date: i64,
    pub unread_count: u32,
    pub is_muted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct PollAnswer {
    pub id: i64,
    pub text: String,
    pub votes: u32,
    pub rate: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct VideoQualityOption {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BotKeyboardButton {
    pub action_type: String,
    pub label: String,
    pub color: String,
    pub payload: Option<String>,
    pub link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BotKeyboardRow {
    pub buttons: Vec<BotKeyboardButton>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BotKeyboard {
    pub inline: bool,
    pub one_time: bool,
    pub rows: Vec<BotKeyboardRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum Attachment {
    Photo {
        url: String,
        width: Option<u32>,
        height: Option<u32>,
    },
    Audio {
        artist: String,
        title: String,
        duration_sec: u32,
        url: Option<String>,
    },
    Document {
        title: String,
        url: String,
        ext: String,
    },
    Sticker {
        url: String,
    },
    Link {
        title: String,
        url: String,
    },
    Video {
        id: i64,
        owner_id: i64,
        access_key: Option<String>,
        title: String,
        duration_sec: u32,
        thumbnail_url: Option<String>,
        player_url: Option<String>,
        stream_url: Option<String>,
        qualities: Vec<VideoQualityOption>,
    },
    AudioMessage {
        url: String,
        duration_sec: u32,
        transcript: Option<String>,
    },
    Poll {
        id: i64,
        owner_id: i64,
        question: String,
        answers: Vec<PollAnswer>,
    },
    Reply {
        message_id: i64,
        text: String,
    },
    Forwarded {
        from_name: String,
        text: String,
        date: i64,
    },
    BotKeyboard {
        inline: bool,
        one_time: bool,
        rows: Vec<BotKeyboardRow>,
    },
    Unknown {
        kind: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MessageItem {
    pub id: i64,
    pub peer_id: i64,
    pub from_id: i64,
    pub text: String,
    pub date: i64,
    pub is_out: bool,
    pub attachments: Vec<Attachment>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FeedPost {
    pub post_id: i64,
    pub source_id: i64,
    pub author_name: String,
    pub author_avatar: Option<String>,
    pub date: i64,
    pub text: String,
    pub photos: Vec<String>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    pub likes_count: u32,
    pub is_liked: bool,
    pub comments_count: u32,
    #[serde(default)]
    pub is_ads: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct NewsfeedPage {
    pub items: Vec<FeedPost>,
    pub next_from: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct OwnerSummary {
    pub id: i64,
    pub is_group: bool,
    pub name: String,
    pub screen_name: Option<String>,
    pub avatar_url: Option<String>,
    pub subtitle: Option<String>,
    pub online: bool,
    pub is_verified: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct OwnerPage {
    pub id: i64,
    pub is_group: bool,
    pub name: String,
    pub screen_name: Option<String>,
    pub avatar_url: Option<String>,
    pub cover_url: Option<String>,
    pub status: Option<String>,
    pub description: Option<String>,
    pub followers_count: Option<u32>,
    pub friends_count: Option<u32>,
    pub photos_count: Option<u32>,
    pub audios_count: Option<u32>,
    pub groups_count: Option<u32>,
    pub online: bool,
    pub city: Option<String>,
    pub site: Option<String>,
    pub is_verified: bool,
    pub is_member_or_friend: bool,
    pub can_post: bool,
    pub wall_posts: Vec<FeedPost>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct CommentItem {
    pub id: i64,
    pub from_id: i64,
    pub author_name: String,
    pub author_avatar: Option<String>,
    pub date: i64,
    pub text: String,
    pub likes_count: u32,
    pub is_liked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct NotificationItem {
    pub kind: String,
    pub date: i64,
    pub actor_id: i64,
    pub actor_name: String,
    pub actor_avatar: Option<String>,
    pub text: String,
    pub target_owner_id: Option<i64>,
    pub target_post_id: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct VideoItem {
    pub id: i64,
    pub owner_id: i64,
    pub access_key: Option<String>,
    pub title: String,
    pub description: String,
    pub duration_sec: u32,
    pub thumbnail_url: Option<String>,
    pub player_url: Option<String>,
    pub stream_url: Option<String>,
    #[serde(default)]
    pub qualities: Vec<VideoQualityOption>,
    pub views: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct AudioPlaylist {
    pub id: i64,
    pub owner_id: i64,
    pub title: String,
    pub count: u32,
    pub cover_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct StoryItem {
    pub id: i64,
    pub owner_id: i64,
    pub author_name: String,
    pub author_avatar: Option<String>,
    pub date: i64,
    pub preview_url: Option<String>,
    pub media_url: Option<String>,
    pub is_video: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FaveItem {
    pub kind: String,
    pub post: Option<FeedPost>,
    pub link_title: Option<String>,
    pub link_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ChatMember {
    pub id: i64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub online: bool,
    pub is_admin: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct UserPresence {
    pub user_id: i64,
    pub online: bool,
    pub last_seen: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct StickerItem {
    pub sticker_id: i64,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct StickerPack {
    pub id: i64,
    pub title: String,
    pub icon_url: Option<String>,
    pub stickers: Vec<StickerItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ResolvedTarget {
    User { id: i64 },
    Group { id: i64 },
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SnippetItem {
    pub id: i64,
    pub title: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BirthdayFriend {
    pub id: i64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub bdate: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ArtistStat {
    pub artist: String,
    pub play_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FriendRequestItem {
    pub id: i64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct AccountSummary {
    pub user_id: i64,
    pub name: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ChatStats {
    pub total_messages: u32,
    pub outgoing_count: u32,
    pub incoming_count: u32,
    pub top_hour: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct AudioTrack {
    pub id: i64,
    pub owner_id: i64,
    pub artist: String,
    pub title: String,
    pub duration_sec: u32,
    pub stream_url: Option<String>,
    pub cover_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum VkEvent {
    NewMessage { message: MessageItem },
    MessageEdited { message: MessageItem },
    ReadIncoming { peer_id: i64, msg_id: i64 },
    ReadOutgoing { peer_id: i64, msg_id: i64 },
    Typing { peer_id: i64, user_id: i64 },
    ConnectionStatus { connected: bool },
}

#[uniffi::export(with_foreign)]
pub trait VkEventListener: Send + Sync {
    fn on_event(&self, event: VkEvent);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_item_and_attachments_json_roundtrip() {
        let msg = MessageItem {
            id: 101,
            peer_id: 2000000001,
            from_id: 42,
            text: "Hello!".to_string(),
            date: 1700000000,
            is_out: true,
            attachments: vec![
                Attachment::Photo {
                    url: "https://example.com/p.jpg".to_string(),
                    width: Some(1280),
                    height: Some(720),
                },
                Attachment::Audio {
                    artist: "Artist".to_string(),
                    title: "Track".to_string(),
                    duration_sec: 185,
                    url: Some("https://example.com/a.m3u8".to_string()),
                },
                Attachment::Document {
                    title: "doc.pdf".to_string(),
                    url: "https://example.com/doc.pdf".to_string(),
                    ext: "pdf".to_string(),
                },
                Attachment::Sticker {
                    url: "https://example.com/sticker.png".to_string(),
                },
                Attachment::Link {
                    title: "VK".to_string(),
                    url: "https://vk.com".to_string(),
                },
                Attachment::Unknown {
                    kind: "poll".to_string(),
                },
            ],
        };

        let json = serde_json::to_string(&msg).expect("serialize message");
        let decoded: MessageItem = serde_json::from_str(&json).expect("deserialize message");
        assert_eq!(decoded, msg);
    }

    #[test]
    fn test_models_json_roundtrip() {
        let conv = ConversationItem {
            peer_id: 123,
            title: "Test Chat".to_string(),
            avatar_url: Some("https://example.com/ava.jpg".to_string()),
            last_message_text: "Hi".to_string(),
            last_message_date: 1700000100,
            unread_count: 3,
            is_muted: true,
        };
        let cfg = OAuthConfig {
            client_id: "12345".to_string(),
            client_secret: "secret".to_string(),
        };
        let track = AudioTrack {
            id: 1,
            owner_id: 2,
            artist: "Band".to_string(),
            title: "Song".to_string(),
            duration_sec: 210,
            stream_url: None,
            cover_url: Some("https://example.com/cover.jpg".to_string()),
        };

        assert_eq!(
            serde_json::from_str::<ConversationItem>(&serde_json::to_string(&conv).unwrap())
                .unwrap(),
            conv
        );
        assert_eq!(
            serde_json::from_str::<OAuthConfig>(&serde_json::to_string(&cfg).unwrap()).unwrap(),
            cfg
        );
        assert_eq!(
            serde_json::from_str::<AudioTrack>(&serde_json::to_string(&track).unwrap()).unwrap(),
            track
        );
    }
}
