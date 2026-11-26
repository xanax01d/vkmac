use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use crate::error::VkError;
use crate::models::OAuthConfig;

/// Public OAuth client parameters of the official VK Android client.
/// These are non-user, public application identifiers; user credentials are NEVER hardcoded.
pub const DEFAULT_VK_CLIENT_ID: &str = "2274003";
pub const DEFAULT_VK_CLIENT_SECRET: &str = "hHbZxrka2uZ6jB1inYsH";

pub const DEFAULT_API_BASE_URL: &str = "https://api.vk.com/method/";
pub const DEFAULT_OAUTH_TOKEN_URL: &str = "https://oauth.vk.com/token";
pub const DEFAULT_OAUTH_AUTHORIZE_URL: &str = "https://oauth.vk.com/authorize";
pub const OAUTH_REDIRECT_URI: &str = "https://oauth.vk.com/blank.html";
pub const VK_API_VERSION: &str = "5.199";
pub const OAUTH_CONFIG_FILENAME: &str = "oauth_config.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OAuthConfigFile {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    client_secret: String,
}

fn process_env(key: &str) -> Option<String> {
    std::env::var(key).ok()
}

fn non_empty_env<F>(env: &F, key: &str) -> Option<String>
where
    F: Fn(&str) -> Option<String>,
{
    env(key)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

pub fn resolve_data_dir(data_dir: &str) -> Result<PathBuf, VkError> {
    resolve_data_dir_with_env(data_dir, process_env)
}

pub fn default_data_dir() -> Result<PathBuf, VkError> {
    resolve_data_dir("")
}

pub fn resolve_data_dir_with_env<F>(data_dir: &str, env: F) -> Result<PathBuf, VkError>
where
    F: Fn(&str) -> Option<String>,
{
    let trimmed = data_dir.trim();
    if !trimmed.is_empty() {
        return Ok(PathBuf::from(trimmed));
    }

    match non_empty_env(&env, "HOME") {
        Some(home) => Ok(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("VKMac")),
        None => Err(VkError::InvalidInput {
            details: "data_dir is empty and HOME environment variable is not set".to_string(),
        }),
    }
}

pub fn resolve_oauth_config(data_dir: &Path) -> OAuthConfig {
    resolve_oauth_config_with_env(data_dir, process_env)
}

pub fn resolve_oauth_config_with_env<F>(data_dir: &Path, env: F) -> OAuthConfig
where
    F: Fn(&str) -> Option<String>,
{
    // Priority 1: <data_dir>/oauth_config.json
    let config_path = data_dir.join(OAUTH_CONFIG_FILENAME);
    if config_path.exists() {
        match std::fs::read_to_string(&config_path) {
            Ok(contents) => match serde_json::from_str::<OAuthConfigFile>(&contents) {
                Ok(parsed) => {
                    let client_id = parsed.client_id.trim().to_string();
                    let client_secret = parsed.client_secret.trim().to_string();
                    if !client_id.is_empty() && !client_secret.is_empty() {
                        return OAuthConfig {
                            client_id,
                            client_secret,
                        };
                    }
                    tracing::warn!(
                        path = %config_path.display(),
                        "oauth_config.json has empty client_id or client_secret; falling through"
                    );
                }
                Err(err) => {
                    tracing::warn!(
                        path = %config_path.display(),
                        error = %err,
                        "Failed to parse oauth_config.json; falling through"
                    );
                }
            },
            Err(err) => {
                tracing::warn!(
                    path = %config_path.display(),
                    error = %err,
                    "Failed to read oauth_config.json; falling through"
                );
            }
        }
    }

    // Priority 2: VK_CLIENT_ID and VK_CLIENT_SECRET environment variables
    if let (Some(client_id), Some(client_secret)) = (
        non_empty_env(&env, "VK_CLIENT_ID"),
        non_empty_env(&env, "VK_CLIENT_SECRET"),
    ) {
        return OAuthConfig {
            client_id,
            client_secret,
        };
    }

    // Priority 3: Official public VK client defaults
    OAuthConfig {
        client_id: DEFAULT_VK_CLIENT_ID.to_string(),
        client_secret: DEFAULT_VK_CLIENT_SECRET.to_string(),
    }
}

pub fn save_oauth_config(data_dir: &Path, config: &OAuthConfig) -> Result<(), VkError> {
    let client_id = config.client_id.trim();
    let client_secret = config.client_secret.trim();

    if client_id.is_empty() {
        return Err(VkError::InvalidInput {
            details: "OAuth client_id must not be empty".to_string(),
        });
    }
    if client_secret.is_empty() {
        return Err(VkError::InvalidInput {
            details: "OAuth client_secret must not be empty".to_string(),
        });
    }
    if client_id.chars().any(char::is_control) || client_secret.chars().any(char::is_control) {
        return Err(VkError::InvalidInput {
            details: "OAuth client_id and client_secret must not contain control characters"
                .to_string(),
        });
    }

    std::fs::create_dir_all(data_dir).map_err(|err| VkError::Storage {
        details: format!(
            "Failed to create config directory {}: {err}",
            data_dir.display()
        ),
    })?;

    let payload = OAuthConfigFile {
        client_id: client_id.to_string(),
        client_secret: client_secret.to_string(),
    };
    let json = serde_json::to_string_pretty(&payload).map_err(|err| VkError::Storage {
        details: format!("Failed to serialize oauth_config.json: {err}"),
    })?;

    static OAUTH_TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    let target_path = data_dir.join(OAUTH_CONFIG_FILENAME);
    let seq = OAUTH_TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp_path = data_dir.join(format!(
        "{OAUTH_CONFIG_FILENAME}.tmp.{}.{seq}",
        std::process::id()
    ));

    std::fs::write(&tmp_path, json).map_err(|err| {
        let _ = std::fs::remove_file(&tmp_path);
        VkError::Storage {
            details: format!("Failed to write {}: {err}", tmp_path.display()),
        }
    })?;

    std::fs::rename(&tmp_path, &target_path).map_err(|err| {
        let _ = std::fs::remove_file(&tmp_path);
        VkError::Storage {
            details: format!(
                "Failed to rename {} to {}: {err}",
                tmp_path.display(),
                target_path.display()
            ),
        }
    })?;

    Ok(())
}

pub fn api_base_url() -> String {
    api_base_url_with_env(process_env)
}

pub fn api_base_url_with_env<F>(env: F) -> String
where
    F: Fn(&str) -> Option<String>,
{
    match non_empty_env(&env, "VK_API_BASE_URL") {
        Some(url) => {
            if url.ends_with('/') {
                url
            } else {
                format!("{url}/")
            }
        }
        None => DEFAULT_API_BASE_URL.to_string(),
    }
}

pub fn oauth_token_url() -> String {
    oauth_token_url_with_env(process_env)
}

pub fn oauth_token_url_with_env<F>(env: F) -> String
where
    F: Fn(&str) -> Option<String>,
{
    match non_empty_env(&env, "VK_OAUTH_TOKEN_URL") {
        Some(url) => url.trim_end_matches('/').to_string(),
        None => DEFAULT_OAUTH_TOKEN_URL.to_string(),
    }
}

pub fn oauth_authorize_url() -> String {
    oauth_authorize_url_with_env(process_env)
}

pub fn oauth_authorize_url_with_env<F>(env: F) -> String
where
    F: Fn(&str) -> Option<String>,
{
    match non_empty_env(&env, "VK_OAUTH_AUTHORIZE_URL") {
        Some(url) => url.trim_end_matches('/').to_string(),
        None => DEFAULT_OAUTH_AUTHORIZE_URL.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tempfile::TempDir;

    use super::*;

    fn map_env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |key| map.get(key).cloned()
    }

    #[test]
    fn test_oauth_config_priority_and_fallbacks() {
        let dir = TempDir::new().unwrap();

        // Priority 3: official defaults when no file and no env vars
        let cfg = resolve_oauth_config_with_env(dir.path(), map_env(&[]));
        assert_eq!(cfg.client_id, DEFAULT_VK_CLIENT_ID);
        assert_eq!(cfg.client_secret, DEFAULT_VK_CLIENT_SECRET);

        // Blank/partial env vars fall through to defaults
        let cfg_partial_env = resolve_oauth_config_with_env(
            dir.path(),
            map_env(&[("VK_CLIENT_ID", "999"), ("VK_CLIENT_SECRET", "   ")]),
        );
        assert_eq!(cfg_partial_env.client_id, DEFAULT_VK_CLIENT_ID);
        assert_eq!(cfg_partial_env.client_secret, DEFAULT_VK_CLIENT_SECRET);

        // Priority 2: env vars beat defaults
        let cfg_env = resolve_oauth_config_with_env(
            dir.path(),
            map_env(&[
                ("VK_CLIENT_ID", " 111222 "),
                ("VK_CLIENT_SECRET", " env_secret "),
            ]),
        );
        assert_eq!(
            cfg_env,
            OAuthConfig {
                client_id: "111222".to_string(),
                client_secret: "env_secret".to_string(),
            }
        );

        // Corrupt JSON falls through cleanly to env vars
        std::fs::write(dir.path().join(OAUTH_CONFIG_FILENAME), "{bad json").unwrap();
        let cfg_corrupt = resolve_oauth_config_with_env(
            dir.path(),
            map_env(&[("VK_CLIENT_ID", "111222"), ("VK_CLIENT_SECRET", "env_secret")]),
        );
        assert_eq!(cfg_corrupt, cfg_env);

        // Blank JSON values fall through cleanly to env vars
        std::fs::write(
            dir.path().join(OAUTH_CONFIG_FILENAME),
            r#"{"client_id":"  ","client_secret":"abc"}"#,
        )
        .unwrap();
        let cfg_blank_json = resolve_oauth_config_with_env(
            dir.path(),
            map_env(&[("VK_CLIENT_ID", "111222"), ("VK_CLIENT_SECRET", "env_secret")]),
        );
        assert_eq!(cfg_blank_json, cfg_env);

        // Priority 1: saved JSON beats env vars and defaults
        save_oauth_config(
            dir.path(),
            &OAuthConfig {
                client_id: " 777888 ".to_string(),
                client_secret: " file_secret ".to_string(),
            },
        )
        .unwrap();
        let cfg_file = resolve_oauth_config_with_env(
            dir.path(),
            map_env(&[("VK_CLIENT_ID", "111222"), ("VK_CLIENT_SECRET", "env_secret")]),
        );
        assert_eq!(
            cfg_file,
            OAuthConfig {
                client_id: "777888".to_string(),
                client_secret: "file_secret".to_string(),
            }
        );
        let leftover_tmp: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(
            leftover_tmp.is_empty(),
            "Unexpected temp files: {leftover_tmp:?}"
        );
    }

    #[test]
    fn test_save_oauth_config_validation() {
        let dir = TempDir::new().unwrap();

        let err_empty_id = save_oauth_config(
            dir.path(),
            &OAuthConfig {
                client_id: "   ".to_string(),
                client_secret: "sec".to_string(),
            },
        )
        .unwrap_err();
        assert!(matches!(err_empty_id, VkError::InvalidInput { .. }));

        let err_empty_secret = save_oauth_config(
            dir.path(),
            &OAuthConfig {
                client_id: "123".to_string(),
                client_secret: "".to_string(),
            },
        )
        .unwrap_err();
        assert!(matches!(err_empty_secret, VkError::InvalidInput { .. }));

        let err_ctrl = save_oauth_config(
            dir.path(),
            &OAuthConfig {
                client_id: "123\n456".to_string(),
                client_secret: "sec".to_string(),
            },
        )
        .unwrap_err();
        assert!(matches!(err_ctrl, VkError::InvalidInput { .. }));
    }

    #[test]
    fn test_resolve_data_dir_and_endpoint_urls_with_env() {
        let explicit = resolve_data_dir_with_env("/tmp/custom_vk", map_env(&[])).unwrap();
        assert_eq!(explicit, PathBuf::from("/tmp/custom_vk"));

        let from_home =
            resolve_data_dir_with_env("  ", map_env(&[("HOME", "/Users/alice")])).unwrap();
        assert_eq!(
            from_home,
            PathBuf::from("/Users/alice/Library/Application Support/VKMac")
        );

        let missing_home = resolve_data_dir_with_env("", map_env(&[])).unwrap_err();
        assert!(matches!(missing_home, VkError::InvalidInput { .. }));

        assert_eq!(api_base_url_with_env(map_env(&[])), DEFAULT_API_BASE_URL);
        assert_eq!(
            api_base_url_with_env(map_env(&[("VK_API_BASE_URL", "http://127.0.0.1:8080/method")])),
            "http://127.0.0.1:8080/method/"
        );
        assert_eq!(
            api_base_url_with_env(map_env(&[("VK_API_BASE_URL", "   ")])),
            DEFAULT_API_BASE_URL
        );

        assert_eq!(
            oauth_token_url_with_env(map_env(&[])),
            DEFAULT_OAUTH_TOKEN_URL
        );
        assert_eq!(
            oauth_token_url_with_env(map_env(&[(
                "VK_OAUTH_TOKEN_URL",
                "http://127.0.0.1:8080/token/"
            )])),
            "http://127.0.0.1:8080/token"
        );

        assert_eq!(
            oauth_authorize_url_with_env(map_env(&[])),
            DEFAULT_OAUTH_AUTHORIZE_URL
        );
        assert_eq!(
            oauth_authorize_url_with_env(map_env(&[(
                "VK_OAUTH_AUTHORIZE_URL",
                "http://127.0.0.1:8080/authorize/"
            )])),
            "http://127.0.0.1:8080/authorize"
        );
    }

    #[test]
    fn test_save_oauth_config_concurrent_writes_leave_valid_json_and_no_tmp() {
        use std::sync::{Arc, Barrier};
        use std::thread;

        const THREADS: usize = 8;
        const ITERATIONS: usize = 20;

        let dir = TempDir::new().unwrap();
        let barrier = Arc::new(Barrier::new(THREADS));

        let handles: Vec<_> = (0..THREADS)
            .map(|tid| {
                let dir_path = dir.path().to_path_buf();
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || -> Result<(), String> {
                    barrier.wait();
                    for iter in 0..ITERATIONS {
                        let cfg = OAuthConfig {
                            client_id: format!("cid_{tid}_{iter}"),
                            client_secret: format!("sec_{tid}_{iter}"),
                        };
                        save_oauth_config(&dir_path, &cfg)
                            .map_err(|err| format!("tid {tid} iter {iter}: {err}"))?;
                    }
                    Ok(())
                })
            })
            .collect();

        let errors: Vec<String> = handles
            .into_iter()
            .filter_map(|h| h.join().expect("config writer thread panicked").err())
            .collect();
        assert!(
            errors.is_empty(),
            "Concurrent save_oauth_config failures: {errors:?}"
        );

        let target_path = dir.path().join(OAUTH_CONFIG_FILENAME);
        let raw = std::fs::read_to_string(&target_path).unwrap();
        let parsed: OAuthConfigFile = serde_json::from_str(&raw).unwrap();
        assert!(parsed.client_id.starts_with("cid_"));
        assert!(parsed.client_secret.starts_with("sec_"));

        // Must resolve from file (not fall back to defaults)
        let resolved = resolve_oauth_config_with_env(dir.path(), map_env(&[]));
        assert_eq!(resolved.client_id, parsed.client_id);
        assert_eq!(resolved.client_secret, parsed.client_secret);

        // Zero leftover .tmp files in data_dir
        let entries: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(entries, vec![OAUTH_CONFIG_FILENAME.to_string()]);
    }
}
