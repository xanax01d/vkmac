# Project: vk-mac

Native macOS client ("minimal combine": Chats, Newsfeed, Music) built on a Rust core (`vk-core`) and SwiftUI (`VKMac`) via UniFFI (`0.28`, `tokio`), built with Command Line Tools (`Swift 5.8.1`, `MacOSX13.3.sdk`, `rustc/cargo 1.100.0`, no `Xcode.app`) on macOS `15.8.1` (`x86_64`).

## Architecture

- **Rust Core (`vk-core`)**: Pure proc-macro UniFFI `0.28` library (`crate-type = ["staticlib", "cdylib", "rlib"]`) owning domain models, configuration, macOS Keychain persistence (`security-framework 3`, service `com.vkmac.client`), SQLite local cache (`rusqlite 0.32` bundled, `cache.db`), OAuth authentication (`oauth.vk.com/token` + redirect fragment parsing), rate-limited VK API client (`reqwest 0.12`, `v=5.199`, <= 3 req/s), background `LongPollWorker` (`tokio`, `wait=25`), and the `VkClient` facade.
- **UniFFI Bridge (`uniffi-bindgen` + `CVkCore`)**: Local `uniffi-bindgen` crate (`uniffi 0.28`, `cli`) configured via `vk-core/uniffi.toml` (`ffi_module_name = "CVkCore"`, `ffi_module_filename = "vk_coreFFI"`) to emit `vk_core.swift`, `vk_coreFFI.h`, and `vk_coreFFI.modulemap` (staged as `module.modulemap` in `VKMac/Generated/CVkCore/`).
- **SwiftUI App (`VKMac`)**: SwiftPM executable package (`swift-tools-version: 5.8`, `.macOS(.v13)`). `AppState` (`@MainActor ObservableObject`) wraps `VkClient` and conforms to `VkEventListener` via `nonisolated` dispatch to `@MainActor`. `AudioPlayerService` wraps `AVPlayer` for HLS `.m3u8` streaming with queue/Shuffle/Repeat and integrates with `MPNowPlayingInfoCenter` (including explicit `playbackState` on macOS) and `MPRemoteCommandCenter`. Views (`MainSplitView`, `AuthView`, `ChatsView`, `FeedView`, `MusicView`, `SettingsView`, `MiniPlayerBar`) strictly target macOS 13.3 SDK / Swift 5.8.1 APIs.
- **Packaging (`scripts/build_app.sh`)**: Builds `vk-core --release` (`MACOSX_DEPLOYMENT_TARGET=13.0`), rewrites `libvk_core.dylib` ID to `@rpath/libvk_core.dylib`, generates UniFFI Swift/C bindings, builds `VKMac` (`swift build -c release`), assembles `build/VKMac.app/Contents/{MacOS,Frameworks,Resources}` + `Info.plist`, ensures `@executable_path/../Frameworks` rpath, and applies entitlement-free inside-out ad-hoc `codesign`.

## Feature Inventory

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | Workspace & UniFFI Setup | `vk-core/Cargo.toml` (`staticlib`, `cdylib`, `rlib`), `vk-core/uniffi.toml`, `lib.rs` `setup_scaffolding!()` | M1 | survey_1, survey_2 |
| F2 | Core Data Models & Errors | `VkError`, `AuthState`, `OAuthConfig`, `UserProfile`, `ConversationItem`, `Attachment`, `MessageItem`, `FeedPost`, `NewsfeedPage`, `AudioTrack`, `VkEvent`, `VkEventListener` | M1 | survey_2 |
| F3 | OAuth Config Management | `config.rs`: `VK_CLIENT_ID`/`VK_CLIENT_SECRET`, `<data_dir>/oauth_config.json`, official public client defaults, optional `VK_API_BASE_URL`/`VK_OAUTH_URL` overrides, zero hardcoded user credentials | M1 | survey_2 |
| F4 | macOS Keychain Token Store | `keychain.rs`: `TokenStore` trait (`KeychainStore` via `security-framework 3`, service `com.vkmac.client`, `-25300` handling, no `kSecAttrAccessGroup`; `InMemoryTokenStore` for tests) | M1 | survey_1, survey_2 |
| F5 | SQLite Cache & Migrations | `storage.rs`: `rusqlite 0.32` bundled, `cache.db`, WAL mode, `user_version` migration v1 (`users`, `conversations`, `messages`, `audio_tracks`), CRUD/upsert/clear | M1 | survey_2 |
| F6 | VK Authentication Logic | `auth.rs`: `oauth.vk.com/token` password grant, `need_validation` (2FA), `need_captcha`, `login_with_redirect_url` (`#access_token=...&user_id=...`), `get_oauth_authorize_url` | M1 | survey_2 |
| F7 | VK API Client & Rate Limiter | `api.rs`: `v=5.199`, <= 3 req/s sliding window, `messages.getConversations`, `messages.getHistory`, `messages.send`, `newsfeed.get`, `likes.add`/`likes.delete`, `audio.get`, `audio.search`, `users.get`, `messages.getLongPollServer`, error mapping | M2 | survey_2 |
| F8 | Long Poll Worker | `longpoll.rs`: background Tokio task (`wait=25`), events `4`/`5`/`6`/`7`/`61`/`62`, `failed: 1/2/3/4`, exponential backoff, `ConnectionStatus`, SQLite write-through, cancellation | M2 | survey_2 |
| F9 | `VkClient` UniFFI Facade | `client.rs`: `#[derive(uniffi::Object)]`, Tokio runtime/handle, all async & sync methods, `subscribe_events`, cache-first `get_cached_*` + network refresh, `like_post`/`unlike_post`, `clear_cache`/`get_cache_size_bytes`, `logout` | M2 | survey_2, survey_3 |
| F10 | Rust Automated Test Suite | `cargo test --workspace` covering SQLite migrations/CRUD, mock JSON fixtures (`getConversations`, `getHistory`, `newsfeed.get`, `audio.get`, `likes`, Long Poll), error codes (`5`, `14`, `17`, 2FA, captcha), rate limiter, redirect URL & config | M2 | survey_2 |
| F11 | Build & `.app` Packaging | `.gitignore`, `VKMac/Package.swift` (`swift-tools-version: 5.8`, `.macOS(.v13)`, `#filePath`/`Context.packageDirectory` `-L`, `@executable_path/../Frameworks` rpath), `VKMac/Resources/Info.plist`, `scripts/build_app.sh`, ad-hoc `codesign --verify` | M3 | survey_1, survey_3 |
| F12 | Swift `AppState` & Events | `AppState.swift`: `@MainActor ObservableObject`, `nonisolated` `VkEventListener` -> `@MainActor`, bootstrap/restore, auth, chats/Long Poll, feed/likes, music/search, settings/logout | M4 | survey_3 |
| F13 | `AudioPlayerService` | `AudioPlayerService.swift`: `AVPlayer` HLS `.m3u8`, queue (Next/Previous/Shuffle/Repeat), periodic time observer + safe cleanup, `MPNowPlayingInfoCenter` (explicit `playbackState`, `NSImage` artwork), `MPRemoteCommandCenter` | M4 | survey_3 |
| F14 | App Shell & Main Navigation | `VKMacApp.swift` (`AppDelegate` `.regular` activation policy), `MainSplitView.swift` (`NavigationSplitView`: `Чаты`, `Лента`, `Музыка`, `Настройки`, Long Poll indicator, pinned `MiniPlayerBar`) | M5 | survey_3 |
| F15 | Authentication UI | `AuthView.swift`: Direct login/password, 2FA code input, captcha image + input, embedded `WKWebView` OAuth intercepting `#access_token=` | M5 | survey_3 |
| F16 | Chats UI | `ChatsView.swift`: conversation list (avatars, unread badges, mute), message thread, attachments, typing indicator, pagination, Enter-to-send | M5 | survey_3 |
| F17 | Newsfeed UI | `FeedView.swift`: `LazyVStack` post cards, author/avatar/date, `.textSelection(.enabled)`, `AsyncImage` photo gallery, interactive Like toggle (`likes.add`/`delete`), `next_from` pagination | M5 | survey_3 |
| F18 | Music & MiniPlayer UI | `MusicView.swift` (track list, search, play/queue), `MiniPlayerBar.swift` (artwork, title/artist, Play/Pause, Next/Prev, Shuffle/Repeat, scrubbable progress slider) | M5 | survey_3 |
| F19 | Settings UI | `SettingsView.swift`: `client_id`/`client_secret` config form, account status + logout, SQLite cache path/size/clear | M5 | survey_3 |

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|--------------|--------|
| M1 | Rust Core Foundation, Storage & Auth | F1–F6: `vk-core` crate manifest, `uniffi.toml`, `lib.rs`, `error.rs`, `models.rs`, `config.rs`, `keychain.rs`, `storage.rs`, `auth.rs` + unit tests | none | DONE (`sub_orch_m1_gen2`: 30/30 tests, 0 clippy warnings, CLEAN) |
| M2 | Rust API Client, Long Poll & `VkClient` Facade | F7–F10: `api.rs`, `longpoll.rs`, `client.rs`, `lib.rs` exports, full `cargo test --workspace` suite, `uniffi-bindgen` generation verification | M1 | IN_PROGRESS |
| M3 | Build Infrastructure & `.app` Packaging | F11: `.gitignore`, `VKMac/Package.swift`, `VKMac/Resources/Info.plist`, `scripts/build_app.sh`, minimal compiling `VKMacApp.swift` bootstrap, verified `build/VKMac.app` | M2 | PLANNED |
| M4 | Swift `AppState` & `AudioPlayerService` | F12–F13: `AppState.swift` (`VkEventListener`, async state management) and `AudioPlayerService.swift` (`AVPlayer`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`) | M3 | PLANNED |
| M5 | SwiftUI Views & Full App Integration | F14–F19: `VKMacApp.swift`, `MainSplitView.swift`, `AuthView.swift`, `ChatsView.swift`, `FeedView.swift`, `MusicView.swift`, `SettingsView.swift`, `MiniPlayerBar.swift` + full `./scripts/build_app.sh` verification | M3, M4 | PLANNED |
| M6 | Final Milestone: E2E Pass & Tier 5 Hardening | Phase 1: Pass 100% of E2E test suite (Tiers 1–4 sequentially once `TEST_READY.md` is published). Phase 2: Adversarial white-box coverage hardening (Tier 5) | M5 | PLANNED |

## Interface Contracts

### 1. Rust Core <-> Swift UniFFI 0.28 Contract (`vk-core` / `VKMac`)

- Scaffolding: `uniffi::setup_scaffolding!()` in `vk-core/src/lib.rs`, configured by `vk-core/uniffi.toml`:
  ```toml
  [bindings.swift]
  ffi_module_name = "CVkCore"
  ffi_module_filename = "vk_coreFFI"
  ```
- **Models & Enums**:
  - `VkError` (`#[derive(Debug, thiserror::Error, uniffi::Error)]`):
    `InvalidToken`, `ValidationRequired { validation_type: String, phone_mask: String }`, `CaptchaRequired { sid: String, img_url: String }`, `ApiError { code: i32, message: String }`, `Network { details: String }`, `Storage { details: String }`, `Keychain { details: String }`, `InvalidInput { details: String }`, `RateLimited`, `Internal { details: String }`
  - `AuthState` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]`):
    `LoggedOut`, `Needs2FA { validation_type: String, phone_mask: String }`, `NeedsCaptcha { sid: String, img_url: String }`, `Authenticated { user_id: i64 }`
  - `OAuthConfig` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `client_id: String`, `client_secret: String`
  - `UserProfile` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `id: i64`, `first_name: String`, `last_name: String`, `avatar_url: Option<String>`, `online: bool`
  - `ConversationItem` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `peer_id: i64`, `title: String`, `avatar_url: Option<String>`, `last_message_text: String`, `last_message_date: i64`, `unread_count: u32`, `is_muted: bool`
  - `Attachment` (`#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]`):
    `Photo { url: String, width: Option<u32>, height: Option<u32> }`, `Audio { artist: String, title: String, duration_sec: u32, url: Option<String> }`, `Document { title: String, url: String, ext: String }`, `Sticker { url: String }`, `Link { title: String, url: String }`, `Unknown { kind: String }`
  - `MessageItem` (`#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]`):
    `id: i64`, `peer_id: i64`, `from_id: i64`, `text: String`, `date: i64`, `is_out: bool`, `attachments: Vec<Attachment>`
  - `FeedPost` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `post_id: i64`, `source_id: i64`, `author_name: String`, `author_avatar: Option<String>`, `date: i64`, `text: String`, `photos: Vec<String>`, `likes_count: u32`, `is_liked: bool`, `comments_count: u32`
  - `NewsfeedPage` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `items: Vec<FeedPost>`, `next_from: Option<String>`
  - `AudioTrack` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]`):
    `id: i64`, `owner_id: i64`, `artist: String`, `title: String`, `duration_sec: u32`, `stream_url: Option<String>`, `cover_url: Option<String>`
  - `VkEvent` (`#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]`):
    `NewMessage { message: MessageItem }`, `MessageEdited { message: MessageItem }`, `ReadIncoming { peer_id: i64, msg_id: i64 }`, `ReadOutgoing { peer_id: i64, msg_id: i64 }`, `Typing { peer_id: i64, user_id: i64 }`, `ConnectionStatus { connected: bool }`
- **Callback Trait**:
  - `#[uniffi::export(with_foreign)] pub trait VkEventListener: Send + Sync { fn on_event(&self, event: VkEvent); }`
- **`VkClient` (`#[derive(uniffi::Object)]`, `#[uniffi::export(async_runtime = "tokio")]`)**:
  - `#[uniffi::constructor] pub fn new(data_dir: String) -> Result<Arc<Self>, VkError>` (empty `data_dir` resolves to `$HOME/Library/Application Support/VKMac`)
  - `pub async fn restore_session(&self) -> AuthState`
  - `pub async fn login_password(&self, login: String, password: String, code_2fa: Option<String>, captcha_sid: Option<String>, captcha_key: Option<String>) -> Result<AuthState, VkError>`
  - `pub async fn login_with_redirect_url(&self, url: String) -> Result<AuthState, VkError>`
  - `pub async fn logout(&self) -> Result<(), VkError>`
  - `pub async fn subscribe_events(&self, listener: Arc<dyn VkEventListener>)`
  - `pub fn get_oauth_config(&self) -> OAuthConfig`
  - `pub fn set_oauth_config(&self, client_id: String, client_secret: String) -> Result<(), VkError>`
  - `pub fn get_oauth_authorize_url(&self) -> String`
  - `pub async fn get_current_user(&self) -> Result<Option<UserProfile>, VkError>`
  - `pub fn get_cached_conversations(&self, offset: u32, count: u32) -> Result<Vec<ConversationItem>, VkError>`
  - `pub async fn get_conversations(&self, offset: u32, count: u32) -> Result<Vec<ConversationItem>, VkError>`
  - `pub fn get_cached_messages(&self, peer_id: i64, offset: u32, count: u32) -> Result<Vec<MessageItem>, VkError>`
  - `pub async fn get_messages(&self, peer_id: i64, offset: u32, count: u32) -> Result<Vec<MessageItem>, VkError>`
  - `pub async fn send_message(&self, peer_id: i64, text: String) -> Result<MessageItem, VkError>`
  - `pub async fn get_newsfeed(&self, start_from: Option<String>) -> Result<NewsfeedPage, VkError>`
  - `pub async fn like_post(&self, owner_id: i64, post_id: i64) -> Result<u32, VkError>`
  - `pub async fn unlike_post(&self, owner_id: i64, post_id: i64) -> Result<u32, VkError>`
  - `pub fn get_cached_audio(&self, offset: u32, count: u32) -> Result<Vec<AudioTrack>, VkError>`
  - `pub async fn get_audio(&self, offset: u32, count: u32) -> Result<Vec<AudioTrack>, VkError>`
  - `pub async fn search_audio(&self, query: String) -> Result<Vec<AudioTrack>, VkError>`
  - `pub fn clear_cache(&self) -> Result<(), VkError>`
  - `pub fn get_cache_size_bytes(&self) -> Result<u64, VkError>`

### 2. Environment & External Entry Points (for Runtime & Opaque-Box Testing)

- `scripts/build_app.sh`: builds `vk-core`, generates UniFFI bindings, builds `VKMac`, packages & ad-hoc signs `build/VKMac.app`.
- `build/VKMac.app/Contents/MacOS/VKMac`: native macOS GUI executable (`com.vkmac.client`).
- Environment variables (optional overrides, production defaults to official VK URLs):
  - `VK_CLIENT_ID`, `VK_CLIENT_SECRET`: OAuth client parameters
  - `VK_API_BASE_URL` (default `https://api.vk.com/method/`)
  - `VK_OAUTH_TOKEN_URL` (default `https://oauth.vk.com/token`)
  - `VK_OAUTH_AUTHORIZE_URL` (default `https://oauth.vk.com/authorize`)

## Code Layout

```
vk-mac/
├── Cargo.toml                         # Existing workspace: ["vk-core", "uniffi-bindgen"]
├── .gitignore                         # M3
├── PROJECT.md                         # Project Orchestrator
├── TEST_INFRA.md                      # E2E Testing Orchestrator
├── TEST_READY.md                      # E2E Testing Orchestrator
├── uniffi-bindgen/                    # Existing CLI runner
├── vk-core/
│   ├── Cargo.toml                     # M1
│   ├── uniffi.toml                    # M1
│   └── src/
│       ├── lib.rs                     # M1 (updated in M2 to export api, longpoll, client)
│       ├── error.rs                   # M1
│       ├── models.rs                  # M1
│       ├── config.rs                  # M1
│       ├── keychain.rs                # M1
│       ├── storage.rs                 # M1
│       ├── auth.rs                    # M1
│       ├── api.rs                     # M2
│       ├── longpoll.rs                # M2
│       └── client.rs                  # M2
├── VKMac/
│   ├── Package.swift                  # M3
│   ├── Resources/Info.plist           # M3
│   ├── Generated/                     # Generated by build_app.sh (M3)
│   │   └── CVkCore/{vk_coreFFI.h, module.modulemap}
│   └── Sources/VKMac/
│       ├── Generated/vk_core.swift    # Generated by build_app.sh (M3)
│       ├── VKMacApp.swift             # M3 (minimal bootstrap) -> M5 (full root wiring)
│       ├── AppState.swift             # M4
│       ├── AudioPlayerService.swift   # M4
│       └── Views/                     # M5
│           ├── MainSplitView.swift
│           ├── AuthView.swift
│           ├── ChatsView.swift
│           ├── FeedView.swift
│           ├── MusicView.swift
│           ├── SettingsView.swift
│           └── MiniPlayerBar.swift
├── scripts/
│   └── build_app.sh                   # M3
├── tests/e2e/                         # E2E Testing Track (opaque-box test suite)
└── build/VKMac.app                    # Packaged app artifact (M3, M5)
```
