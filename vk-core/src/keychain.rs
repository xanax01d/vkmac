use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};

use crate::error::VkError;

pub const KEYCHAIN_SERVICE: &str = "com.vkmac.client";
const ACCOUNT_SESSION: &str = "session";
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;
const ERR_SEC_DUPLICATE_ITEM: i32 = -25299;

pub trait TokenStore: Send + Sync {
    fn get_session(&self) -> Result<Option<(String, i64)>, VkError>;
    fn save_session(&self, token: &str, user_id: i64) -> Result<(), VkError>;
    fn clear_session(&self) -> Result<(), VkError>;
    fn list_account_ids(&self) -> Result<Vec<i64>, VkError> {
        Ok(self.get_session()?.map(|(_, id)| vec![id]).unwrap_or_default())
    }
    fn switch_account(&self, _user_id: i64) -> Result<Option<(String, i64)>, VkError> {
        self.get_session()
    }
    fn remove_account(&self, _user_id: i64) -> Result<(), VkError> {
        self.clear_session()
    }
}

#[derive(Debug, Clone)]
pub struct KeychainStore {
    service: String,
    cached: Arc<Mutex<Option<MultiAccountPayload>>>,
}

impl Default for KeychainStore {
    fn default() -> Self {
        Self::new(KEYCHAIN_SERVICE)
    }
}

impl KeychainStore {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            cached: Arc::new(Mutex::new(None)),
        }
    }

    fn read_item(&self, account: &str) -> Result<Option<String>, VkError> {
        match get_generic_password(&self.service, account) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|err| VkError::Keychain {
                    details: format!("Invalid UTF-8 for keychain item {account}: {err}"),
                }),
            Err(err) if err.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
            Err(err) => Err(VkError::Keychain {
                details: format!(
                    "Keychain read failed for {account} (code {}): {err}",
                    err.code()
                ),
            }),
        }
    }

    fn write_item(&self, account: &str, value: &[u8]) -> Result<(), VkError> {
        match set_generic_password(&self.service, account, value) {
            Ok(()) => Ok(()),
            Err(err) if err.code() == ERR_SEC_DUPLICATE_ITEM => {
                let _ = self.delete_item(account);
                set_generic_password(&self.service, account, value).map_err(|retry_err| {
                    VkError::Keychain {
                        details: format!(
                            "Keychain write retry failed for {account} (code {}): {retry_err}",
                            retry_err.code()
                        ),
                    }
                })
            }
            Err(err) => Err(VkError::Keychain {
                details: format!(
                    "Keychain write failed for {account} (code {}): {err}",
                    err.code()
                ),
            }),
        }
    }

    fn delete_item(&self, account: &str) -> Result<(), VkError> {
        match delete_generic_password(&self.service, account) {
            Ok(()) => Ok(()),
            Err(err) if err.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
            Err(err) => Err(VkError::Keychain {
                details: format!(
                    "Keychain delete failed for {account} (code {}): {err}",
                    err.code()
                ),
            }),
        }
    }
}

fn validate_session_inputs(token: &str, user_id: i64) -> Result<(), VkError> {
    if token.trim().is_empty() {
        return Err(VkError::InvalidInput {
            details: "access_token cannot be empty".to_string(),
        });
    }
    if user_id <= 0 {
        return Err(VkError::InvalidInput {
            details: "user_id must be positive".to_string(),
        });
    }
    Ok(())
}

pub(crate) fn decode_session_parts(
    token_opt: Option<String>,
    uid_opt: Option<String>,
) -> Result<Option<(String, i64)>, VkError> {
    match (token_opt, uid_opt) {
        (None, None) => Ok(None),
        (Some(_), None) | (None, Some(_)) => {
            tracing::warn!("Partial keychain session detected; treating as logged out");
            Ok(None)
        }
        (Some(token), Some(_)) if token.trim().is_empty() => {
            tracing::warn!("Empty access_token in keychain; treating as logged out");
            Ok(None)
        }
        (Some(token), Some(uid_str)) => match uid_str.trim().parse::<i64>() {
            Ok(uid) if uid > 0 => Ok(Some((token, uid))),
            _ => Err(VkError::Keychain {
                details: "Corrupt user_id in keychain".to_string(),
            }),
        },
    }
}

#[allow(dead_code)]
fn encode_session(token: &str, user_id: i64) -> String {
    format!("{user_id}:{token}")
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct MultiAccountPayload {
    active: i64,
    accounts: BTreeMap<i64, String>,
}

fn decode_multi_payload(raw: &str) -> Result<MultiAccountPayload, VkError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(MultiAccountPayload::default());
    }
    if trimmed.starts_with('{') {
        if let Ok(payload) = serde_json::from_str::<MultiAccountPayload>(trimmed) {
            return Ok(payload);
        }
    }
    if let Some((token, uid)) = decode_single_session(trimmed)? {
        let mut accounts = BTreeMap::new();
        accounts.insert(uid, token);
        return Ok(MultiAccountPayload { active: uid, accounts });
    }
    Ok(MultiAccountPayload::default())
}

fn encode_multi_payload(payload: &MultiAccountPayload) -> Result<String, VkError> {
    serde_json::to_string(payload).map_err(|err| VkError::Keychain {
        details: format!("Failed to serialize keychain session: {err}"),
    })
}

fn decode_single_session(raw: &str) -> Result<Option<(String, i64)>, VkError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if trimmed.starts_with('{') {
        let payload = decode_multi_payload(trimmed)?;
        if let Some(tok) = payload.accounts.get(&payload.active) {
            return Ok(Some((tok.clone(), payload.active)));
        }
        return Ok(payload.accounts.into_iter().next().map(|(id, tok)| (tok, id)));
    }
    let Some((uid_str, token)) = trimmed.split_once(':') else {
        return Ok(None);
    };
    decode_session_parts(Some(token.to_string()), Some(uid_str.to_string()))
}

fn payload_active_session(payload: &MultiAccountPayload) -> Option<(String, i64)> {
    if let Some(tok) = payload.accounts.get(&payload.active) {
        return Some((tok.clone(), payload.active));
    }
    payload
        .accounts
        .iter()
        .next()
        .map(|(&id, tok)| (tok.clone(), id))
}

impl KeychainStore {
    fn load_payload(&self) -> Result<MultiAccountPayload, VkError> {
        {
            let guard = self.cached.lock().map_err(|_| VkError::Keychain {
                details: "Keychain cache mutex poisoned".to_string(),
            })?;
            if let Some(ref cached) = *guard {
                return Ok(cached.clone());
            }
        }

        let payload = match self.read_item(ACCOUNT_SESSION)? {
            Some(raw) => decode_multi_payload(&raw)?,
            None => MultiAccountPayload::default(),
        };

        let mut guard = self.cached.lock().map_err(|_| VkError::Keychain {
            details: "Keychain cache mutex poisoned".to_string(),
        })?;
        *guard = Some(payload.clone());
        Ok(payload)
    }

    fn store_cached_payload(&self, payload: MultiAccountPayload) -> Result<(), VkError> {
        let mut guard = self.cached.lock().map_err(|_| VkError::Keychain {
            details: "Keychain cache mutex poisoned".to_string(),
        })?;
        *guard = Some(payload);
        Ok(())
    }
}

impl TokenStore for KeychainStore {
    fn get_session(&self) -> Result<Option<(String, i64)>, VkError> {
        let payload = self.load_payload()?;
        Ok(payload_active_session(&payload))
    }

    fn save_session(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        validate_session_inputs(token, user_id)?;
        let mut payload = self.load_payload()?;
        payload.active = user_id;
        payload.accounts.insert(user_id, token.to_string());
        let encoded = encode_multi_payload(&payload)?;
        self.write_item(ACCOUNT_SESSION, encoded.as_bytes())?;
        self.store_cached_payload(payload)?;
        Ok(())
    }

    fn list_account_ids(&self) -> Result<Vec<i64>, VkError> {
        let payload = self.load_payload()?;
        Ok(payload.accounts.keys().copied().collect())
    }

    fn switch_account(&self, user_id: i64) -> Result<Option<(String, i64)>, VkError> {
        let mut payload = self.load_payload()?;
        let Some(tok) = payload.accounts.get(&user_id).cloned() else {
            return Ok(None);
        };
        payload.active = user_id;
        let encoded = encode_multi_payload(&payload)?;
        self.write_item(ACCOUNT_SESSION, encoded.as_bytes())?;
        let _ = self.store_cached_payload(payload);
        Ok(Some((tok, user_id)))
    }

    fn remove_account(&self, user_id: i64) -> Result<(), VkError> {
        let mut payload = self.load_payload()?;
        payload.accounts.remove(&user_id);
        if payload.accounts.is_empty() {
            return self.clear_session();
        }
        if payload.active == user_id {
            if let Some(&first_id) = payload.accounts.keys().next() {
                payload.active = first_id;
            }
        }
        let encoded = encode_multi_payload(&payload)?;
        self.write_item(ACCOUNT_SESSION, encoded.as_bytes())?;
        let _ = self.store_cached_payload(payload);
        Ok(())
    }

    fn clear_session(&self) -> Result<(), VkError> {
        let err = self.delete_item(ACCOUNT_SESSION).err();
        let _ = self.store_cached_payload(MultiAccountPayload::default());
        match err {
            Some(err) => Err(err),
            None => Ok(()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct FileTokenStore {
    path: PathBuf,
    lock: Arc<Mutex<()>>,
}

impl FileTokenStore {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            path: data_dir.join("session.json"),
            lock: Arc::new(Mutex::new(())),
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StoredSession {
    access_token: String,
    user_id: i64,
}

impl TokenStore for FileTokenStore {
    fn get_session(&self) -> Result<Option<(String, i64)>, VkError> {
        let _guard = self.lock.lock().map_err(|_| VkError::Storage {
            details: "Session file mutex poisoned".to_string(),
        })?;
        if !self.path.exists() {
            return Ok(None);
        }
        let raw = std::fs::read_to_string(&self.path).map_err(|err| VkError::Storage {
            details: format!("Failed to read {}: {err}", self.path.display()),
        })?;
        let parsed: StoredSession =
            serde_json::from_str(&raw).map_err(|err| VkError::Storage {
                details: format!("Failed to parse {}: {err}", self.path.display()),
            })?;
        if parsed.access_token.trim().is_empty() || parsed.user_id <= 0 {
            return Ok(None);
        }
        Ok(Some((parsed.access_token, parsed.user_id)))
    }

    fn save_session(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        validate_session_inputs(token, user_id)?;
        let _guard = self.lock.lock().map_err(|_| VkError::Storage {
            details: "Session file mutex poisoned".to_string(),
        })?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|err| VkError::Storage {
                details: format!("Failed to create {}: {err}", parent.display()),
            })?;
        }
        let payload = serde_json::to_string(&StoredSession {
            access_token: token.to_string(),
            user_id,
        })
        .map_err(|err| VkError::Storage {
            details: format!("Failed to serialize session: {err}"),
        })?;
        let tmp_path = self.path.with_extension("json.tmp");
        std::fs::write(&tmp_path, payload.as_bytes()).map_err(|err| VkError::Storage {
            details: format!("Failed to write {}: {err}", tmp_path.display()),
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp_path, &self.path).map_err(|err| VkError::Storage {
            details: format!("Failed to rename session file: {err}"),
        })?;
        Ok(())
    }

    fn clear_session(&self) -> Result<(), VkError> {
        let _guard = self.lock.lock().map_err(|_| VkError::Storage {
            details: "Session file mutex poisoned".to_string(),
        })?;
        if self.path.exists() {
            std::fs::remove_file(&self.path).map_err(|err| VkError::Storage {
                details: format!("Failed to remove {}: {err}", self.path.display()),
            })?;
        }
        Ok(())
    }
}

#[derive(Debug, Default)]
pub struct InMemoryTokenStore {
    state: Mutex<Option<(String, i64)>>,
}

impl InMemoryTokenStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_session(token: impl Into<String>, user_id: i64) -> Self {
        Self {
            state: Mutex::new(Some((token.into(), user_id))),
        }
    }
}

impl TokenStore for InMemoryTokenStore {
    fn get_session(&self) -> Result<Option<(String, i64)>, VkError> {
        let guard = self.state.lock().map_err(|_| VkError::Keychain {
            details: "InMemoryTokenStore mutex poisoned".to_string(),
        })?;
        Ok(guard.clone())
    }

    fn save_session(&self, token: &str, user_id: i64) -> Result<(), VkError> {
        validate_session_inputs(token, user_id)?;
        let mut guard = self.state.lock().map_err(|_| VkError::Keychain {
            details: "InMemoryTokenStore mutex poisoned".to_string(),
        })?;
        *guard = Some((token.to_string(), user_id));
        Ok(())
    }

    fn clear_session(&self) -> Result<(), VkError> {
        let mut guard = self.state.lock().map_err(|_| VkError::Keychain {
            details: "InMemoryTokenStore mutex poisoned".to_string(),
        })?;
        *guard = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_in_memory_token_store_lifecycle_and_validation() {
        let store = InMemoryTokenStore::new();
        assert_eq!(store.get_session().unwrap(), None);

        store.save_session("tok_1", 1001).unwrap();
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_1".to_string(), 1001))
        );

        store.save_session("tok_2", 2002).unwrap();
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_2".to_string(), 2002))
        );

        assert!(matches!(
            store.save_session("   ", 1001).unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(matches!(
            store.save_session("tok", 0).unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(matches!(
            store.save_session("tok", -42).unwrap_err(),
            VkError::InvalidInput { .. }
        ));

        // Failed validation must not alter existing session
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_2".to_string(), 2002))
        );

        store.clear_session().unwrap();
        assert_eq!(store.get_session().unwrap(), None);

        // Idempotent clear
        store.clear_session().unwrap();
        assert_eq!(store.get_session().unwrap(), None);
    }

    #[test]
    fn test_decode_session_parts_edge_cases() {
        assert_eq!(decode_session_parts(None, None).unwrap(), None);
        assert_eq!(
            decode_session_parts(Some("tok".to_string()), None).unwrap(),
            None
        );
        assert_eq!(
            decode_session_parts(None, Some("123".to_string())).unwrap(),
            None
        );
        assert_eq!(
            decode_session_parts(Some("  ".to_string()), Some("123".to_string())).unwrap(),
            None
        );
        assert_eq!(
            decode_session_parts(Some("tok".to_string()), Some(" 456 ".to_string())).unwrap(),
            Some(("tok".to_string(), 456))
        );
        assert!(matches!(
            decode_session_parts(Some("tok".to_string()), Some("abc".to_string())).unwrap_err(),
            VkError::Keychain { .. }
        ));
        assert!(matches!(
            decode_session_parts(Some("tok".to_string()), Some("0".to_string())).unwrap_err(),
            VkError::Keychain { .. }
        ));
    }

    #[test]
    #[ignore = "Touches real macOS Keychain; run manually in GUI session"]
    fn test_keychain_store_live_roundtrip() {
        let store = KeychainStore::new("com.vkmac.client.test");
        store.clear_session().unwrap();
        assert_eq!(store.get_session().unwrap(), None);
        store.save_session("test_tok", 999).unwrap();
        assert_eq!(
            store.get_session().unwrap(),
            Some(("test_tok".to_string(), 999))
        );
        store.clear_session().unwrap();
        assert_eq!(store.get_session().unwrap(), None);
    }

    #[test]
    fn test_multi_account_payload_encoding_and_legacy_decode() {
        let legacy = decode_multi_payload("12345:tok_legacy").unwrap();
        assert_eq!(legacy.active, 12345);
        assert_eq!(
            payload_active_session(&legacy),
            Some(("tok_legacy".to_string(), 12345))
        );

        let mut payload = legacy;
        payload.accounts.insert(67890, "tok_second".to_string());
        payload.active = 67890;
        let encoded = encode_multi_payload(&payload).unwrap();
        let decoded = decode_multi_payload(&encoded).unwrap();
        assert_eq!(decoded.active, 67890);
        assert_eq!(decoded.accounts.len(), 2);
        assert_eq!(
            payload_active_session(&decoded),
            Some(("tok_second".to_string(), 67890))
        );

        let empty = decode_multi_payload("   ").unwrap();
        assert!(empty.accounts.is_empty());
        assert_eq!(payload_active_session(&empty), None);
    }
}
