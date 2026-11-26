# E2E Test Infra: vk-mac

## Test Philosophy
- Opaque-box, requirement-driven. Derived strictly from `ORIGINAL_REQUEST.md` and `PROJECT.md § Feature Inventory` & `§ Interface Contracts`, with zero dependency on `vk-core` or `VKMac` internal modules.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing across 4 tiers.
- Progressive testability: Tier 1 tests use minimal verification channels (exit codes, single FFI method returns, plist/codesign/otool checks); later tiers compose multi-step state, Long Poll streams, HLS playback, and live `.app` launches.

## Feature Inventory

| # | Feature | Source (requirement) | Tier 1 | Tier 2 | Tier 3 |
|---|---------|---------------------|:------:|:------:|:------:|
| F1 | Workspace & UniFFI Setup | ORIGINAL_REQUEST R1, PROJECT.md F1 | >=5 | >=5 | ✓ |
| F2 | Core Data Models & Errors | ORIGINAL_REQUEST R2, PROJECT.md F2 | >=5 | >=5 | ✓ |
| F3 | OAuth Config Management | ORIGINAL_REQUEST R2, PROJECT.md F3 | >=5 | >=5 | ✓ |
| F4 | macOS Keychain Token Store | ORIGINAL_REQUEST R2, PROJECT.md F4 | >=5 | >=5 | ✓ |
| F5 | SQLite Cache & Migrations | ORIGINAL_REQUEST R2, PROJECT.md F5 | >=5 | >=5 | ✓ |
| F6 | VK Authentication Logic | ORIGINAL_REQUEST R2, PROJECT.md F6 | >=5 | >=5 | ✓ |
| F7 | VK API Client & Rate Limiter | ORIGINAL_REQUEST R2, PROJECT.md F7 | >=5 | >=5 | ✓ |
| F8 | Long Poll Worker | ORIGINAL_REQUEST R2, PROJECT.md F8 | >=5 | >=5 | ✓ |
| F9 | `VkClient` UniFFI Facade | ORIGINAL_REQUEST R2, PROJECT.md F9 | >=5 | >=5 | ✓ |
| F10 | Rust Automated Test Suite | ORIGINAL_REQUEST AC, PROJECT.md F10 | >=5 | >=5 | ✓ |
| F11 | Build & `.app` Packaging | ORIGINAL_REQUEST R1, AC, PROJECT.md F11 | >=5 | >=5 | ✓ |
| F12 | Swift `AppState` & Events | ORIGINAL_REQUEST R3, PROJECT.md F12 | >=5 | >=5 | ✓ |
| F13 | `AudioPlayerService` | ORIGINAL_REQUEST R3, PROJECT.md F13 | >=5 | >=5 | ✓ |
| F14 | App Shell & Main Navigation | ORIGINAL_REQUEST R3, PROJECT.md F14 | >=5 | >=5 | ✓ |
| F15 | Authentication UI | ORIGINAL_REQUEST R3, PROJECT.md F15 | >=5 | >=5 | ✓ |
| F16 | Chats UI | ORIGINAL_REQUEST R3, PROJECT.md F16 | >=5 | >=5 | ✓ |
| F17 | Newsfeed UI | ORIGINAL_REQUEST R3, PROJECT.md F17 | >=5 | >=5 | ✓ |
| F18 | Music & MiniPlayer UI | ORIGINAL_REQUEST R3, PROJECT.md F18 | >=5 | >=5 | ✓ |
| F19 | Settings UI | ORIGINAL_REQUEST R3, PROJECT.md F19 | >=5 | >=5 | ✓ |

## Test Architecture
- **Test runner**: `tests/e2e/run_e2e.sh`
  - Invocation:
    - `./tests/e2e/run_e2e.sh --tier 1`
    - `./tests/e2e/run_e2e.sh --tier 2`
    - `./tests/e2e/run_e2e.sh --tier 3`
    - `./tests/e2e/run_e2e.sh --tier 4`
    - `./tests/e2e/run_e2e.sh --tier all`
    - `./tests/e2e/run_e2e.sh --self-test` (validates mock server, scripts, and coverage thresholds without needing `VKMac.app` built yet)
  - Pass/fail semantics: Exit code `0` iff all executed tests in the selected tier(s) pass; non-zero on any failure, assertion error, or missing build artifact.
- **Local Mock Server**: `tests/e2e/mock_server.py`
  - Python 3 stdlib `ThreadingHTTPServer` bound to `127.0.0.1:0` (ephemeral port).
  - Emulates VK OAuth (`oauth.vk.com/token`, `/authorize`, `/blank.html`), VK API `v=5.199` (`/method/*`), Long Poll (`/lp`), and HLS audio/image media (`/media/playlist.m3u8`, `/media/segment0.ts`, images).
  - Controlled via `/__admin/*` endpoints for per-test state reset, error injection, Long Poll event pushing, and request/rate-limit inspection.
- **Opaque-Box Swift UniFFI Harness**: `tests/e2e/harness/`
  - Standalone Swift CLI compiled against `VKMac/Generated/CVkCore`, `VKMac/Sources/VKMac/Generated/vk_core.swift`, and `libvk_core.dylib`, invoking `VkClient` and `VkEventListener` via public UniFFI contract with `VK_API_BASE_URL`, `VK_OAUTH_TOKEN_URL`, `VK_OAUTH_AUTHORIZE_URL`, `VK_CLIENT_ID`, `VK_CLIENT_SECRET` env overrides and isolated `HOME` / `data_dir`.
- **Directory layout**:
  ```
  tests/e2e/
  ├── README.md
  ├── run_e2e.sh
  ├── mock_server.py
  ├── self_test.py
  ├── lib/
  │   ├── e2e_common.py
  │   └── app_driver.py
  ├── harness/
  │   ├── build_harness.sh
  │   ├── main.swift
  │   └── hls_probe.swift
  └── tiers/
      ├── tier1/
      ├── tier2/
      ├── tier3/
      └── tier4/
  ```

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Clean build via `scripts/build_app.sh` & `.app` bundle/codesign/rpath/plist verification | F1, F11 | Medium |
| 2 | Cold launch `VKMac.app` with env overrides & isolated `HOME`, window/activation check, clean quit | F11, F12, F14 | Medium |
| 3 | Password login -> Keychain token persistence -> session restore across client restart | F2, F3, F4, F6, F9 | Medium |
| 4 | 2FA & Captcha challenge recovery flow -> authenticated session -> user profile fetch | F2, F6, F7, F9, F15 | High |
| 5 | WebView OAuth URL generation -> redirect `#access_token=` login -> authenticated session | F3, F4, F6, F9, F15 | Medium |
| 6 | Cache-first chats workflow: load conversations, fetch messages, send message, receive live Long Poll `NewMessage` + `ReadIncoming` + `Typing`, verify SQLite persistence on restart | F5, F7, F8, F9, F12, F16 | High |
| 7 | Newsfeed browsing with `next_from` pagination & interactive `like_post` / `unlike_post` round-trip | F2, F7, F9, F12, F17 | Medium |
| 8 | Music library load + search + local HLS `.m3u8` streaming via `AVPlayer` + NowPlaying/RemoteCommand probe | F5, F7, F9, F13, F18 | High |
| 9 | Settings `client_id`/`client_secret` reconfiguration -> persisted `oauth_config.json` -> updated authorize URL -> cache size inspection & clear | F3, F5, F9, F19 | Medium |
| 10 | Full lifecycle: login -> chats -> feed -> music -> logout -> Keychain & SQLite cache wiped -> `restore_session` returns `LoggedOut` | F4, F5, F6, F9, F12, F19 | High |

## Coverage Thresholds
- Tier 1: >= 5 per feature -> >= 95 test cases (F1–F19)
- Tier 2: >= 5 per feature -> >= 95 test cases (F1–F19)
- Tier 3: >= 19 pairwise cross-feature test cases
- Tier 4: >= 10 realistic application scenarios
- Total minimum: >= 219 test cases
