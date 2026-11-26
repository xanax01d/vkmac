# `vk-mac` Opaque-Box E2E Test Infrastructure (`tests/e2e/`)

This directory contains the self-contained, zero-third-party-dependency E2E test infrastructure for `vk-mac`.
Tests are derived strictly from `ORIGINAL_REQUEST.md` and `PROJECT.md § Feature Inventory` & `§ Interface Contracts`, with **zero dependency on internal `vk-core` or `VKMac` source modules**.

---

## 1. Runner CLI (`tests/e2e/run_e2e.sh`)

```bash
./tests/e2e/run_e2e.sh --self-test [-v|--verbose]  # Validate infra, build hls_probe, test mock_server
./tests/e2e/run_e2e.sh --list                       # List test cases across tiers
./tests/e2e/run_e2e.sh --tier <1|2|3|4|all> [-v]    # Build harnesses, start mock server, run tier(s)
./tests/e2e/run_e2e.sh --help                       # Show CLI usage and options
```

### Exported Environment Variables (in `--tier` mode)
- `E2E_PROJECT_ROOT` / `E2E_REPO_ROOT`: repository root
- `E2E_DIR`: `tests/e2e` directory
- `E2E_RUN_TMP`: temporary run directory (cleaned up on exit unless `E2E_KEEP_TMP=1`)
- `E2E_MOCK_PORT`, `E2E_MOCK_URL`, `E2E_MOCK_BASE_URL`: local mock server address (`http://127.0.0.1:<port>`)
- `VK_API_BASE_URL`: `${E2E_MOCK_BASE_URL}/method/`
- `VK_OAUTH_TOKEN_URL`: `${E2E_MOCK_BASE_URL}/token`
- `VK_OAUTH_AUTHORIZE_URL`: `${E2E_MOCK_BASE_URL}/authorize`
- `E2E_APP_PATH`: `build/VKMac.app`
- `E2E_HARNESS_BIN`: `tests/e2e/harness/bin/vk_e2e_harness`
- `E2E_HLS_PROBE_BIN`: `tests/e2e/harness/bin/hls_probe`
- `E2E_VERBOSE`: `0` or `1`
- `PYTHONPATH`: includes `tests/e2e/lib`

---

## 2. Tier Runner Contract (`tests/e2e/tiers/tier{N}/run_tier.py`)

Each tier runner must:
1. Import `TestRegistry` and `run_tier_cli` from `e2e_common`.
2. Register test cases via `@registry.test_case(id="T1-F1-01", feature="F1", title="...", tags=[...])`.
3. Call `raise SystemExit(run_tier_cli(tier=N, registry=registry))`.

`run_tier_cli` automatically supports:
- `--list` and `--list --json` (`{"tier": N, "count": M, "cases": [{"id", "feature", "title", "tags"}]}`)
- `--verbose` (`-v`)
- `--filter <substr>`
- Automatic `MockAdminClient.reset()` before each test case.

### Coverage Thresholds (`self_test.py --strict-tiers`)
- **Tier 1**: `>= 95` cases (`>= 5` per feature `F1..F19`)
- **Tier 2**: `>= 95` cases (`>= 5` per feature `F1..F19`)
- **Tier 3**: `>= 19` pairwise cross-feature cases
- **Tier 4**: `>= 10` realistic end-to-end application scenarios
- **Total**: `>= 219` unique test IDs

---

## 3. Mock VK Server (`tests/e2e/mock_server.py`) & `MockAdminClient`

Zero third-party dependencies (`ThreadingHTTPServer`, `HTTP/1.0`, `127.0.0.1:0`).

### OAuth Endpoints
- `POST|GET /token`:
  - `client_id == "invalid_client"` (or empty) -> `401 invalid_client`
  - `username == "user_2fa"` (without `code`) -> `401 need_validation` (`validation_type`, `validation_sid`, `phone_mask`, `redirect_uri`); `code == "123456"` succeeds
  - `username == "user_captcha"` (without `captcha_key`) -> `401 need_captcha` (`captcha_sid`, `captcha_img`); `captcha_key == "e2e_ok"` succeeds
  - `username == "bad_user"` or `password == "wrong"` -> `401 invalid_grant`
  - Normal -> `200 {"access_token": "vk_e2e_token_10001", "expires_in": 0, "user_id": 10001}`
- `GET /authorize`: `302` redirect to local `/blank.html#access_token=vk_e2e_token_10001&expires_in=0&user_id=10001` (or `#error=access_denied` under `authorize_error` scenario).
- `GET /blank.html`: `200 text/html`.

### VK API `v=5.199` (`/method/<name>`, duplicate slashes normalized)
- `messages.getConversations` (3 seeded peers: user `20001`, chat `2000000001` with `chat_settings` & `push_settings`, group `-123456`)
- `messages.getHistory` (peer `20001` includes `photo`, `audio`, `doc`, `sticker`, `link` attachments; supports `offset`, `count`, `rev`)
- `messages.send` (appends message, updates conversation `last_message`, returns `msg_id`)
- `newsfeed.get` (page 1 -> `next_from: "page_2"`, page 2 omits `next_from`)
- `likes.add` / `likes.delete` (stateful counter & `user_likes`)
- `audio.get` (tracks `5001` & `5002` with `/media/playlist.m3u8`, track `5003` with empty `""` url)
- `audio.search` (case-insensitive filter on `artist` and `title`)
- `users.get` (`10001`, `20001`, `20002`)
- `messages.getLongPollServer`

### Long Poll (`/lp`) & Media (`/media/*`)
- `GET|POST /lp`: `threading.Condition`-backed wait up to `wait` seconds; supports events `4`, `5`, `6`, `7`, `61`, `62` and `failed: 1|2|3|4`.
- `GET /media/playlist.m3u8` (`application/vnd.apple.mpegurl`) + `GET /media/segment0.ts` (`video/mp2t`, `Accept-Ranges: bytes`, full RFC 9110 `Range` incl. suffix `bytes=-N` and `416`, pure-Python PAT/PMT/PES AAC-LC 2.090s stream).
- `GET /media/*.png` (`image/png`), `GET /media/*.jpg` (`image/jpeg`), `GET /media/*.pdf` (`application/pdf`).

### `MockAdminClient` (`e2e_common.py`)
Proxy-safe (`ProxyHandler({})`):
- `admin.health()` -> `GET /__admin/health`
- `admin.reset()` -> `POST /__admin/reset`
- `admin.set_scenario(payload)` -> `POST /__admin/scenario`
  - `{"oauth": {"mode": "need_validation"|"need_captcha"|"invalid_client"|"invalid_grant"|"authorize_error", "once": True, "remaining_count": 1}}`
  - `{"api": {"<method_or_*>": {"error_code": 5|6|14|17|int, "http_status": 500, "latency_ms": 200, "remaining_count": 1}}}`
  - `{"lp": {"failed": 1|2|3|4, "once": True, "remaining_count": 1}}`
  - `{"strict_tokens": True, "revoke_token": "..."}`
- `admin.push_lp(updates)` -> `POST /__admin/push_lp`
- `admin.get_requests(vk_method=..., path_prefix=...)` -> `GET /__admin/requests` (with monotonic `timestamp` for `assert_rate_limit`)
- `admin.clear_requests()` -> `DELETE /__admin/requests`
- `admin.get_state()` -> `GET /__admin/state`

---

## 4. Isolation, Keychain, SQLite & App Driver (`e2e_common.py`, `app_driver.py`)

### `isolated_home()`
- Creates a temporary `$HOME` with `$HOME/Library/Application Support/VKMac/` and initializes an unlocked empty-password `$HOME/Library/Keychains/login.keychain-db` (`-p ""`) so `SecItemAdd` never hangs or touches `~/Library/Keychains/login.keychain-db`.
- `iso.keychain_find(service="com.vkmac.client", account=...)` runs `security find-generic-password` **without `-w`** (avoids cross-binary ACL prompts).
- `iso.sqlite_query(sql, params)`, `iso.sqlite_tables()`, `iso.sqlite_user_version()` inspect `cache.db` in `?mode=ro` read-only mode.

### `VKMacAppDriver` (`app_driver.py`)
- Launches `build/VKMac.app/Contents/MacOS/VKMac` directly via `subprocess.Popen(..., start_new_session=True)` with `iso.env(...)` (defaults `stdout`/`stderr` to `subprocess.DEVNULL` when `log_dir is None`).
- `wait_ready(timeout=10.0)`: verifies process health + `lsappinfo` `CFBundleIdentifier == "com.vkmac.client"` & `ApplicationType == "Foreground"`.
- `wait_for_window(timeout=5.0)`: runs `hls_probe --check-window <pid>` (`CGWindowListCopyWindowInfo`, no Accessibility TCC required).
- `quit()`: sends `SIGTERM` -> `SIGKILL` to the process group.
- `launch_via_open(app_path, env_vars, ...)`: launches via `open -n -g -F` and resolves/returns the newly spawned PID (or raises `AppLaunchError`).

---

## 5. Swift Harnesses (`tests/e2e/harness/`)

### `vk_e2e_harness` (`main.swift`)
Compiled by `build_harness.sh` (`[--if-available | --require-vk-core] [--force|-f]`, incremental mtime checks) against `VKMac/Generated/CVkCore`, `VKMac/Sources/VKMac/Generated/vk_core.swift`, and `libvk_core.dylib`.
Invoke via `e2e_common.run_harness(payload, env=iso.env(...))`:
- Single op: `{"data_dir": "...", "op": "<method>", "params": {...}}`
- Multi-step (reuses one `VkClient` + `VkEventListener`): `{"data_dir": "...", "ops": [{"op": "...", "params": {...}}, ...]}`

Supported `op` names:
- `restore_session`, `login_password` (`login`, `password`, `code_2fa`, `captcha_sid`, `captcha_key`), `login_with_redirect_url` (`url`), `logout`
- `subscribe_events`, `collect_events` (`wait_ms`, `min_events`)
- `get_oauth_config`, `set_oauth_config` (`client_id`, `client_secret`), `get_oauth_authorize_url`
- `get_current_user`
- `get_cached_conversations`, `get_conversations` (`offset`, `count`)
- `get_cached_messages`, `get_messages` (`peer_id`, `offset`, `count`), `send_message` (`peer_id`, `text`)
- `get_newsfeed` (`start_from`), `like_post` (`owner_id`, `post_id`), `unlike_post` (`owner_id`, `post_id`)
- `get_cached_audio`, `get_audio` (`offset`, `count`), `search_audio` (`query`)
- `clear_cache`, `get_cache_size_bytes`

### `hls_probe` (`hls_probe.swift`)
- `hls_probe --url <m3u8_url> [--timeout 15]`: probes live `AVPlayer` HLS playback + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.
- `hls_probe --check-window <pid>`: checks onscreen windows via `CGWindowListCopyWindowInfo`.
