use std::sync::{Arc, Mutex, RwLock};

use reqwest::StatusCode;
use serde::Deserialize;
use url::{form_urlencoded, Url};

use crate::config::{
    DEFAULT_OAUTH_AUTHORIZE_URL, DEFAULT_OAUTH_TOKEN_URL, OAUTH_REDIRECT_URI, VK_API_VERSION,
};
use crate::error::VkError;
use crate::keychain::TokenStore;
use crate::models::{AuthState, OAuthConfig};

pub const VK_OAUTH_SCOPE: &str = "audio,messages,wall,friends,offline";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedirectToken {
    pub access_token: String,
    pub user_id: i64,
    pub expires_in: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct OAuthTokenRawResponse {
    access_token: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    expires_in: Option<i64>,
    user_id: Option<i64>,
    error: Option<String>,
    error_description: Option<String>,
    validation_type: Option<String>,
    phone_mask: Option<String>,
    validation_sid: Option<String>,
    #[allow(dead_code)]
    redirect_uri: Option<String>,
    captcha_sid: Option<String>,
    captcha_img: Option<String>,
}

pub struct AuthManager {
    http: reqwest::Client,
    token_store: Arc<dyn TokenStore>,
    oauth_config: RwLock<OAuthConfig>,
    token_url: String,
    authorize_url: String,
    validation_sid: Mutex<Option<String>>,
}

impl AuthManager {
    pub fn new(
        http: reqwest::Client,
        token_store: Arc<dyn TokenStore>,
        oauth_config: OAuthConfig,
        token_url: impl Into<String>,
        authorize_url: impl Into<String>,
    ) -> Self {
        let token_url = token_url.into();
        let authorize_url = authorize_url.into();
        Self {
            http,
            token_store,
            oauth_config: RwLock::new(oauth_config),
            token_url: if token_url.trim().is_empty() {
                DEFAULT_OAUTH_TOKEN_URL.to_string()
            } else {
                token_url
            },
            authorize_url: if authorize_url.trim().is_empty() {
                DEFAULT_OAUTH_AUTHORIZE_URL.to_string()
            } else {
                authorize_url
            },
            validation_sid: Mutex::new(None),
        }
    }

    pub fn restore_session(&self) -> AuthState {
        match self.token_store.get_session() {
            Ok(Some((token, user_id))) if !token.trim().is_empty() && user_id > 0 => {
                AuthState::Authenticated { user_id }
            }
            Ok(Some(_)) | Ok(None) => AuthState::LoggedOut,
            Err(err) => {
                tracing::warn!(error = %err, "Failed to restore session from TokenStore");
                AuthState::LoggedOut
            }
        }
    }

    pub fn current_session(&self) -> Result<Option<(String, i64)>, VkError> {
        self.token_store.get_session()
    }

    pub fn oauth_config(&self) -> OAuthConfig {
        self.oauth_config
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn set_oauth_config(&self, config: OAuthConfig) {
        let mut guard = self
            .oauth_config
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard = config;
    }

    pub fn authorize_url(&self) -> String {
        let cfg = self.oauth_config();
        build_authorize_url(&cfg, &self.authorize_url).unwrap_or_else(|_| {
            build_authorize_url(&cfg, DEFAULT_OAUTH_AUTHORIZE_URL)
                .unwrap_or_else(|_| DEFAULT_OAUTH_AUTHORIZE_URL.to_string())
        })
    }

    pub async fn login_password(
        &self,
        login: &str,
        password: &str,
        code_2fa: Option<&str>,
        captcha_sid: Option<&str>,
        captcha_key: Option<&str>,
    ) -> Result<AuthState, VkError> {
        let trimmed_login = login.trim();
        if trimmed_login.is_empty() || password.is_empty() {
            return Err(VkError::InvalidInput {
                details: "Login and password must not be empty".to_string(),
            });
        }

        let cfg = self.oauth_config();
        let client_id = cfg.client_id.trim();
        if client_id.is_empty() {
            return Err(VkError::InvalidInput {
                details: "OAuth client_id must not be empty".to_string(),
            });
        }

        let normalized_code_2fa = code_2fa
            .map(str::trim)
            .filter(|code| !code.is_empty())
            .map(ToString::to_string);

        // Lock synchronously and drop before any .await
        let active_validation_sid: Option<String> = {
            let mut sid_guard = self.validation_sid.lock().map_err(|_| VkError::Internal {
                details: "validation_sid mutex poisoned".to_string(),
            })?;
            if normalized_code_2fa.is_some() {
                sid_guard.clone()
            } else {
                *sid_guard = None;
                None
            }
        };

        let mut form: Vec<(&str, String)> = vec![
            ("grant_type", "password".to_string()),
            ("client_id", client_id.to_string()),
            ("client_secret", cfg.client_secret.trim().to_string()),
            ("username", trimmed_login.to_string()),
            ("password", password.to_string()),
            ("v", VK_API_VERSION.to_string()),
            ("2fa_supported", "1".to_string()),
            ("libverify_support", "0".to_string()),
            ("scope", VK_OAUTH_SCOPE.to_string()),
        ];

        if let Some(ref code) = normalized_code_2fa {
            form.push(("code", code.clone()));
            if let Some(ref sid) = active_validation_sid {
                form.push(("validation_sid", sid.clone()));
            }
        } else {
            form.push(("force_sms", "1".to_string()));
        }

        if let (Some(sid), Some(key)) = (
            captcha_sid.map(str::trim).filter(|s| !s.is_empty()),
            captcha_key.map(str::trim).filter(|s| !s.is_empty()),
        ) {
            form.push(("captcha_sid", sid.to_string()));
            if let Some(success_tok) = key.strip_prefix("success_token:") {
                form.push(("success_token", success_tok.to_string()));
            } else {
                form.push(("captcha_key", key.to_string()));
            }
        }

        let response = self.http.post(&self.token_url).form(&form).send().await?;
        let status = response.status();
        let body = response.text().await?;

        // VK OAuth returns HTTP 400/401 for need_validation and need_captcha JSON payloads,
        // so we MUST parse JSON before checking HTTP status.
        match serde_json::from_str::<OAuthTokenRawResponse>(&body) {
            Ok(raw) => self.handle_oauth_raw_response(status, raw),
            Err(_) => {
                if status == StatusCode::TOO_MANY_REQUESTS {
                    Err(VkError::RateLimited)
                } else {
                    let snippet: String = body.chars().take(200).collect();
                    Err(VkError::Network {
                        details: format!("OAuth HTTP {status}: {snippet}"),
                    })
                }
            }
        }
    }

    fn handle_oauth_raw_response(
        &self,
        status: StatusCode,
        raw: OAuthTokenRawResponse,
    ) -> Result<AuthState, VkError> {
        if let Some(err_code) = raw
            .error
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let desc = raw
                .error_description
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("OAuth authentication error");

            return match err_code {
                "need_validation" => {
                    let validation_type = raw
                        .validation_type
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "unknown".to_string());
                    let phone_mask = raw.phone_mask.unwrap_or_default();
                    let next_sid = raw
                        .validation_sid
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());

                    let redirect_uri = raw
                        .redirect_uri
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());

                    let mut sid_guard =
                        self.validation_sid.lock().map_err(|_| VkError::Internal {
                            details: "validation_sid mutex poisoned".to_string(),
                        })?;
                    *sid_guard = next_sid;

                    Ok(AuthState::Needs2FA {
                        validation_type,
                        phone_mask,
                        redirect_uri,
                    })
                }
                "need_captcha" => {
                    let sid = raw
                        .captcha_sid
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| VkError::Internal {
                            details: "OAuth need_captcha missing captcha_sid".to_string(),
                        })?;
                    let img_url = raw.captcha_img.unwrap_or_default();
                    let redirect_uri = raw
                        .redirect_uri
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());
                    Ok(AuthState::NeedsCaptcha {
                        sid,
                        img_url,
                        redirect_uri,
                    })
                }
                "too_many_requests" => Err(VkError::RateLimited),
                "invalid_grant" | "invalid_client" | "invalid_request" | "unauthorized_client" => {
                    Err(VkError::InvalidInput {
                        details: format!("{err_code}: {desc}"),
                    })
                }
                other => {
                    if status == StatusCode::TOO_MANY_REQUESTS {
                        Err(VkError::RateLimited)
                    } else {
                        Err(VkError::ApiError {
                            code: i32::from(status.as_u16()),
                            message: format!("{other}: {desc}"),
                        })
                    }
                }
            };
        }

        match (raw.access_token, raw.user_id) {
            (Some(token), Some(user_id)) if !token.trim().is_empty() && user_id > 0 => {
                self.token_store.save_session(&token, user_id)?;
                let mut sid_guard = self.validation_sid.lock().map_err(|_| VkError::Internal {
                    details: "validation_sid mutex poisoned".to_string(),
                })?;
                *sid_guard = None;
                Ok(AuthState::Authenticated { user_id })
            }
            _ => Err(VkError::Internal {
                details: "OAuth response missing valid access_token or user_id".to_string(),
            }),
        }
    }

    pub fn login_with_redirect_url(&self, url: &str) -> Result<AuthState, VkError> {
        let parsed = parse_redirect_url(url)?;
        self.save_direct_token(&parsed.access_token, parsed.user_id)
    }

    pub fn save_direct_token(&self, token: &str, user_id: i64) -> Result<AuthState, VkError> {
        let trimmed = token.trim();
        if trimmed.is_empty() || user_id <= 0 {
            return Err(VkError::InvalidInput {
                details: "Token must not be empty and user_id must be positive".to_string(),
            });
        }
        self.token_store.save_session(trimmed, user_id)?;

        let mut sid_guard = self.validation_sid.lock().map_err(|_| VkError::Internal {
            details: "validation_sid mutex poisoned".to_string(),
        })?;
        *sid_guard = None;

        Ok(AuthState::Authenticated { user_id })
    }

    pub fn logout(&self) -> Result<(), VkError> {
        {
            let mut sid_guard = self.validation_sid.lock().map_err(|_| VkError::Internal {
                details: "validation_sid mutex poisoned".to_string(),
            })?;
            *sid_guard = None;
        }
        self.token_store.clear_session()
    }

    pub fn list_account_ids(&self) -> Result<Vec<i64>, VkError> {
        self.token_store.list_account_ids()
    }

    pub fn switch_account(&self, user_id: i64) -> Result<Option<(String, i64)>, VkError> {
        self.token_store.switch_account(user_id)
    }

    pub fn remove_account(&self, user_id: i64) -> Result<(), VkError> {
        self.token_store.remove_account(user_id)
    }

    pub async fn request_2fa_sms(&self, api_base_url: &str) -> Result<(), VkError> {
        let sid = {
            let guard = self.validation_sid.lock().map_err(|_| VkError::Internal {
                details: "validation_sid mutex poisoned".to_string(),
            })?;
            guard.clone()
        }
        .ok_or_else(|| VkError::InvalidInput {
            details: "No active 2FA validation_sid; submit login and password first".to_string(),
        })?;

        let base = api_base_url.trim_end_matches('/');
        let url = format!("{base}/auth.validatePhone");
        let form = [
            ("sid", sid.as_str()),
            ("allow_callreset", "0"),
            ("v", VK_API_VERSION),
        ];
        let body: serde_json::Value = self.http.post(&url).form(&form).send().await?.json().await?;
        if let Some(err) = body.get("error") {
            let code = err.get("error_code").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let message = err
                .get("error_msg")
                .and_then(|v| v.as_str())
                .unwrap_or("auth.validatePhone failed")
                .to_string();
            return Err(VkError::ApiError { code, message });
        }
        Ok(())
    }
}

fn format_oauth_error(err: &str, desc: Option<&str>) -> String {
    match desc.map(str::trim).filter(|s| !s.is_empty()) {
        Some(description) => format!("{err}: {description}"),
        None => err.to_string(),
    }
}

pub fn parse_redirect_url(url_str: &str) -> Result<RedirectToken, VkError> {
    let trimmed = url_str.trim();
    let parsed = Url::parse(trimmed).map_err(|err| VkError::InvalidInput {
        details: format!("Invalid OAuth redirect URL: {err}"),
    })?;

    // Check query parameters for OAuth errors first (e.g., ?error=access_denied)
    let mut query_error: Option<String> = None;
    let mut query_error_desc: Option<String> = None;
    for (k, v) in parsed.query_pairs() {
        match k.as_ref() {
            "error" if !v.trim().is_empty() => query_error = Some(v.into_owned()),
            "error_description" => query_error_desc = Some(v.into_owned()),
            _ => {}
        }
    }
    if let Some(err) = query_error {
        return Err(VkError::InvalidInput {
            details: format_oauth_error(&err, query_error_desc.as_deref()),
        });
    }

    let fragment = parsed.fragment().ok_or_else(|| VkError::InvalidInput {
        details: "Missing fragment in OAuth redirect URL".to_string(),
    })?;
    if fragment.trim().is_empty() {
        return Err(VkError::InvalidInput {
            details: "Empty fragment in OAuth redirect URL".to_string(),
        });
    }

    let mut access_token: Option<String> = None;
    let mut user_id_raw: Option<String> = None;
    let mut expires_in_raw: Option<String> = None;
    let mut frag_error: Option<String> = None;
    let mut frag_error_desc: Option<String> = None;

    for (k, v) in form_urlencoded::parse(fragment.as_bytes()) {
        match k.as_ref() {
            "access_token" => access_token = Some(v.into_owned()),
            "user_id" => user_id_raw = Some(v.into_owned()),
            "expires_in" => expires_in_raw = Some(v.into_owned()),
            "error" if !v.trim().is_empty() => frag_error = Some(v.into_owned()),
            "error_description" => frag_error_desc = Some(v.into_owned()),
            _ => {}
        }
    }

    if let Some(err) = frag_error {
        return Err(VkError::InvalidInput {
            details: format_oauth_error(&err, frag_error_desc.as_deref()),
        });
    }

    let access_token = access_token
        .filter(|t| !t.trim().is_empty())
        .ok_or_else(|| VkError::InvalidInput {
            details: "Missing or empty access_token in redirect URL".to_string(),
        })?;

    let user_id_str = user_id_raw.ok_or_else(|| VkError::InvalidInput {
        details: "Missing user_id in redirect URL".to_string(),
    })?;
    let user_id = user_id_str
        .trim()
        .parse::<i64>()
        .map_err(|_| VkError::InvalidInput {
            details: format!("Invalid user_id in redirect URL: {user_id_str}"),
        })?;
    if user_id <= 0 {
        return Err(VkError::InvalidInput {
            details: "user_id in redirect URL must be positive".to_string(),
        });
    }

    let expires_in = expires_in_raw.and_then(|v| v.trim().parse::<i64>().ok());

    Ok(RedirectToken {
        access_token,
        user_id,
        expires_in,
    })
}

pub fn build_authorize_url(
    config: &OAuthConfig,
    base_authorize_url: &str,
) -> Result<String, VkError> {
    let client_id = config.client_id.trim();
    if client_id.is_empty() {
        return Err(VkError::InvalidInput {
            details: "OAuth client_id must not be empty".to_string(),
        });
    }

    let mut url = Url::parse(base_authorize_url.trim()).map_err(|err| VkError::InvalidInput {
        details: format!("Invalid OAuth authorize URL: {err}"),
    })?;

    url.query_pairs_mut()
        .append_pair("client_id", client_id)
        .append_pair("display", "page")
        .append_pair("redirect_uri", OAUTH_REDIRECT_URI)
        .append_pair("scope", VK_OAUTH_SCOPE)
        .append_pair("response_type", "token")
        .append_pair("v", VK_API_VERSION);

    Ok(url.to_string())
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, VecDeque};

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;
    use crate::keychain::InMemoryTokenStore;

    #[derive(Debug, Clone)]
    struct CapturedOAuthRequest {
        params: BTreeMap<String, String>,
    }

    struct MockOAuthServer {
        url: String,
        requests: Arc<tokio::sync::Mutex<Vec<CapturedOAuthRequest>>>,
        handle: tokio::task::JoinHandle<()>,
    }

    impl Drop for MockOAuthServer {
        fn drop(&mut self) {
            self.handle.abort();
        }
    }

    impl MockOAuthServer {
        async fn start(responses: Vec<(u16, &'static str, String)>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let url = format!("http://127.0.0.1:{port}/token");

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

                        let body =
                            &buf[header_end..(header_end + content_length).min(buf.len())];
                        let params: BTreeMap<String, String> = form_urlencoded::parse(body)
                            .map(|(k, v)| (k.into_owned(), v.into_owned()))
                            .collect();
                        req_ref.lock().await.push(CapturedOAuthRequest { params });

                        let (status, ct, resp_body) = resp_ref
                            .lock()
                            .await
                            .pop_front()
                            .unwrap_or((500, "text/plain", "no queued mock response".to_string()));
                        let reason = match status {
                            200 => "OK",
                            400 => "Bad Request",
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
                url,
                requests,
                handle,
            }
        }

        async fn requests(&self) -> Vec<CapturedOAuthRequest> {
            self.requests.lock().await.clone()
        }
    }

    struct FailingTokenStore;

    impl TokenStore for FailingTokenStore {
        fn get_session(&self) -> Result<Option<(String, i64)>, VkError> {
            Err(VkError::Keychain {
                details: "simulated keychain failure".to_string(),
            })
        }

        fn save_session(&self, _token: &str, _user_id: i64) -> Result<(), VkError> {
            Err(VkError::Keychain {
                details: "simulated keychain failure".to_string(),
            })
        }

        fn clear_session(&self) -> Result<(), VkError> {
            Err(VkError::Keychain {
                details: "simulated keychain failure".to_string(),
            })
        }
    }

    fn test_http() -> reqwest::Client {
        reqwest::Client::builder().no_proxy().build().unwrap()
    }

    fn test_config() -> OAuthConfig {
        OAuthConfig {
            client_id: "2274003".to_string(),
            client_secret: "test_secret".to_string(),
        }
    }

    #[tokio::test]
    async fn test_login_password_success() {
        let server = MockOAuthServer::start(vec![(
            200,
            "application/json",
            r#"{"access_token":"tok_abc","expires_in":0,"user_id":4242}"#.to_string(),
        )])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let state = auth
            .login_password("user@example.com", "pw123", None, None, None)
            .await
            .unwrap();
        assert_eq!(state, AuthState::Authenticated { user_id: 4242 });
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_abc".to_string(), 4242))
        );

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].params.get("grant_type").unwrap(), "password");
        assert_eq!(reqs[0].params.get("client_id").unwrap(), "2274003");
        assert_eq!(reqs[0].params.get("client_secret").unwrap(), "test_secret");
        assert_eq!(reqs[0].params.get("username").unwrap(), "user@example.com");
        assert_eq!(reqs[0].params.get("password").unwrap(), "pw123");
        assert_eq!(reqs[0].params.get("v").unwrap(), VK_API_VERSION);
        assert_eq!(reqs[0].params.get("2fa_supported").unwrap(), "1");
        assert_eq!(reqs[0].params.get("scope").unwrap(), VK_OAUTH_SCOPE);
    }

    #[tokio::test]
    async fn test_login_password_2fa_flow_sends_and_clears_validation_sid() {
        let server = MockOAuthServer::start(vec![
            (
                401,
                "application/json",
                r#"{"error":"need_validation","validation_type":"2fa_sms","phone_mask":"+7 *** *** ** 12","validation_sid":"sid_777"}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"access_token":"tok_2fa","expires_in":0,"user_id":555}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"access_token":"tok_2fa_2","expires_in":0,"user_id":555}"#.to_string(),
            ),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let step1 = auth
            .login_password("u", "p", None, None, None)
            .await
            .unwrap();
        assert_eq!(
            step1,
            AuthState::Needs2FA {
                validation_type: "2fa_sms".to_string(),
                phone_mask: "+7 *** *** ** 12".to_string(),
                redirect_uri: None,
            }
        );

        let step2 = auth
            .login_password("u", "p", Some("654321"), None, None)
            .await
            .unwrap();
        assert_eq!(step2, AuthState::Authenticated { user_id: 555 });

        let step3 = auth
            .login_password("u", "p", Some("999999"), None, None)
            .await
            .unwrap();
        assert_eq!(step3, AuthState::Authenticated { user_id: 555 });

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 3);
        assert_eq!(reqs[1].params.get("code").unwrap(), "654321");
        assert_eq!(reqs[1].params.get("validation_sid").unwrap(), "sid_777");
        assert!(!reqs[2].params.contains_key("validation_sid"));
    }

    #[tokio::test]
    async fn test_login_password_2fa_app_without_phone_mask() {
        let server = MockOAuthServer::start(vec![(
            401,
            "application/json",
            r#"{"error":"need_validation","validation_type":"2fa_app"}"#.to_string(),
        )])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store,
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let state = auth
            .login_password("u", "p", None, None, None)
            .await
            .unwrap();
        assert_eq!(
            state,
            AuthState::Needs2FA {
                validation_type: "2fa_app".to_string(),
                phone_mask: String::new(),
                redirect_uri: None,
            }
        );
    }

    #[tokio::test]
    async fn test_login_password_new_login_without_code_clears_stale_validation_sid() {
        let server = MockOAuthServer::start(vec![
            (
                401,
                "application/json",
                r#"{"error":"need_validation","validation_type":"2fa_sms","phone_mask":"+7 ***","validation_sid":"stale_sid"}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"access_token":"tok_new","expires_in":0,"user_id":12}"#.to_string(),
            ),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store,
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let _ = auth
            .login_password("u", "p", None, None, None)
            .await
            .unwrap();
        let _ = auth
            .login_password("u2", "p2", None, None, None)
            .await
            .unwrap();

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 2);
        assert!(!reqs[1].params.contains_key("validation_sid"));
    }

    #[tokio::test]
    async fn test_login_password_captcha_and_retry() {
        let server = MockOAuthServer::start(vec![
            (
                401,
                "application/json",
                r#"{"error":"need_captcha","captcha_sid":"cap_123","captcha_img":"https://api.vk.com/captcha.php?sid=cap_123"}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"access_token":"tok_cap","expires_in":0,"user_id":77}"#.to_string(),
            ),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store,
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let s1 = auth
            .login_password("u", "p", None, None, None)
            .await
            .unwrap();
        assert_eq!(
            s1,
            AuthState::NeedsCaptcha {
                sid: "cap_123".to_string(),
                img_url: "https://api.vk.com/captcha.php?sid=cap_123".to_string(),
                redirect_uri: None,
            }
        );

        let s2 = auth
            .login_password("u", "p", None, Some("cap_123"), Some("xyzw"))
            .await
            .unwrap();
        assert_eq!(s2, AuthState::Authenticated { user_id: 77 });

        let reqs = server.requests().await;
        assert_eq!(reqs[1].params.get("captcha_sid").unwrap(), "cap_123");
        assert_eq!(reqs[1].params.get("captcha_key").unwrap(), "xyzw");
    }

    #[tokio::test]
    async fn test_login_password_error_mappings() {
        let server = MockOAuthServer::start(vec![
            (
                401,
                "application/json",
                r#"{"error":"invalid_grant","error_description":"Username or password is incorrect"}"#.to_string(),
            ),
            (
                401,
                "application/json",
                r#"{"error":"invalid_client","error_description":"client_id is incorrect"}"#.to_string(),
            ),
            (
                429,
                "application/json",
                r#"{"error":"too_many_requests","error_description":"Too many requests"}"#.to_string(),
            ),
            (429, "text/plain", "Too Many Requests".to_string()),
            (502, "text/html", "<html>Bad Gateway</html>".to_string()),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        assert!(matches!(
            auth.login_password("u", "p", None, None, None)
                .await
                .unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(matches!(
            auth.login_password("u", "p", None, None, None)
                .await
                .unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(matches!(
            auth.login_password("u", "p", None, None, None)
                .await
                .unwrap_err(),
            VkError::RateLimited
        ));
        assert!(matches!(
            auth.login_password("u", "p", None, None, None)
                .await
                .unwrap_err(),
            VkError::RateLimited
        ));
        assert!(matches!(
            auth.login_password("u", "p", None, None, None)
                .await
                .unwrap_err(),
            VkError::Network { .. }
        ));
        assert_eq!(store.get_session().unwrap(), None);
    }

    #[tokio::test]
    async fn test_login_password_empty_credentials_rejected_locally() {
        let server = MockOAuthServer::start(vec![]).await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store,
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        assert!(matches!(
            auth.login_password("   ", "pw", None, None, None)
                .await
                .unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(matches!(
            auth.login_password("user", "", None, None, None)
                .await
                .unwrap_err(),
            VkError::InvalidInput { .. }
        ));
        assert!(server.requests().await.is_empty());
    }

    #[test]
    fn test_login_with_redirect_url_restore_and_logout() {
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            DEFAULT_OAUTH_TOKEN_URL,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );
        assert_eq!(auth.restore_session(), AuthState::LoggedOut);

        let state = auth
            .login_with_redirect_url(
                "https://oauth.vk.com/blank.html#access_token=vk1.a.test_tok&expires_in=86400&user_id=987654",
            )
            .unwrap();
        assert_eq!(state, AuthState::Authenticated { user_id: 987654 });
        assert_eq!(auth.restore_session(), AuthState::Authenticated { user_id: 987654 });
        assert_eq!(
            auth.current_session().unwrap(),
            Some(("vk1.a.test_tok".to_string(), 987654))
        );

        auth.logout().unwrap();
        assert_eq!(auth.restore_session(), AuthState::LoggedOut);
        assert_eq!(store.get_session().unwrap(), None);
    }

    #[test]
    fn test_parse_redirect_url_valid_and_url_encoded() {
        let parsed = parse_redirect_url(
            "https://oauth.vk.com/blank.html#access_token=tok%2B123%20abc&expires_in=0&user_id=123456",
        )
        .unwrap();
        assert_eq!(parsed.access_token, "tok+123 abc");
        assert_eq!(parsed.user_id, 123456);
        assert_eq!(parsed.expires_in, Some(0));
    }

    #[test]
    fn test_parse_redirect_url_error_in_fragment_and_query() {
        let err_query = parse_redirect_url(
            "https://oauth.vk.com/blank.html?error=access_denied&error_description=User+denied",
        )
        .unwrap_err();
        assert!(matches!(err_query, VkError::InvalidInput { .. }));
        assert!(err_query.to_string().contains("access_denied"));

        let err_frag = parse_redirect_url(
            "https://oauth.vk.com/blank.html#error=access_denied&error_description=Cancelled",
        )
        .unwrap_err();
        assert!(matches!(err_frag, VkError::InvalidInput { .. }));
        assert!(err_frag.to_string().contains("access_denied"));
    }

    #[test]
    fn test_parse_redirect_url_edge_cases() {
        for bad in [
            "not a url",
            "https://oauth.vk.com/blank.html",
            "https://oauth.vk.com/blank.html#",
            "https://oauth.vk.com/blank.html#user_id=123",
            "https://oauth.vk.com/blank.html#access_token=&user_id=123",
            "https://oauth.vk.com/blank.html#access_token=abc",
            "https://oauth.vk.com/blank.html#access_token=abc&user_id=not_num",
            "https://oauth.vk.com/blank.html#access_token=abc&user_id=0",
            "https://oauth.vk.com/blank.html#access_token=abc&user_id=-10",
        ] {
            assert!(
                matches!(
                    parse_redirect_url(bad).unwrap_err(),
                    VkError::InvalidInput { .. }
                ),
                "Expected InvalidInput for {bad}"
            );
        }
    }

    #[test]
    fn test_build_authorize_url_params_and_scopes() {
        let url_str = build_authorize_url(&test_config(), DEFAULT_OAUTH_AUTHORIZE_URL).unwrap();
        let parsed = Url::parse(&url_str).unwrap();
        let pairs: BTreeMap<String, String> = parsed
            .query_pairs()
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();

        assert_eq!(pairs.get("client_id").unwrap(), "2274003");
        assert_eq!(pairs.get("display").unwrap(), "page");
        assert_eq!(pairs.get("redirect_uri").unwrap(), OAUTH_REDIRECT_URI);
        assert_eq!(pairs.get("response_type").unwrap(), "token");
        assert_eq!(pairs.get("v").unwrap(), VK_API_VERSION);
        let scope = pairs.get("scope").unwrap();
        for required in ["audio", "messages", "wall", "friends", "offline"] {
            assert!(scope.contains(required));
        }

        assert!(matches!(
            build_authorize_url(&test_config(), "not a valid url").unwrap_err(),
            VkError::InvalidInput { .. }
        ));
    }

    #[test]
    fn test_restore_session_handles_failing_store_and_dynamic_config() {
        let auth = AuthManager::new(
            test_http(),
            Arc::new(FailingTokenStore),
            test_config(),
            DEFAULT_OAUTH_TOKEN_URL,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );
        assert_eq!(auth.restore_session(), AuthState::LoggedOut);

        auth.set_oauth_config(OAuthConfig {
            client_id: "555555".to_string(),
            client_secret: "new_sec".to_string(),
        });
        assert!(auth.authorize_url().contains("client_id=555555"));
    }

    #[tokio::test]
    async fn test_login_password_empty_error_field_with_valid_token_succeeds() {
        let server = MockOAuthServer::start(vec![
            (
                200,
                "application/json",
                r#"{"error":"","error_description":"","access_token":"tok_empty_err","expires_in":0,"user_id":1337}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"error":"   ","access_token":"tok_ws_err","expires_in":0,"user_id":1338}"#.to_string(),
            ),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let s1 = auth
            .login_password("u1", "p1", None, None, None)
            .await
            .unwrap();
        assert_eq!(s1, AuthState::Authenticated { user_id: 1337 });
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_empty_err".to_string(), 1337))
        );

        let s2 = auth
            .login_password("u2", "p2", None, None, None)
            .await
            .unwrap();
        assert_eq!(s2, AuthState::Authenticated { user_id: 1338 });
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_ws_err".to_string(), 1338))
        );
    }

    #[tokio::test]
    async fn test_login_password_2fa_then_captcha_preserves_validation_sid() {
        let server = MockOAuthServer::start(vec![
            (
                401,
                "application/json",
                r#"{"error":"need_validation","validation_type":"2fa_sms","phone_mask":"+7 *** 99","validation_sid":"vs_keep_1"}"#.to_string(),
            ),
            (
                401,
                "application/json",
                r#"{"error":"need_captcha","captcha_sid":"cap_42","captcha_img":"https://api.vk.com/captcha.php?sid=cap_42"}"#.to_string(),
            ),
            (
                200,
                "application/json",
                r#"{"access_token":"tok_2fa_cap","expires_in":0,"user_id":8080}"#.to_string(),
            ),
        ])
        .await;
        let store = Arc::new(InMemoryTokenStore::new());
        let auth = AuthManager::new(
            test_http(),
            store.clone(),
            test_config(),
            &server.url,
            DEFAULT_OAUTH_AUTHORIZE_URL,
        );

        let step1 = auth
            .login_password("u", "p", None, None, None)
            .await
            .unwrap();
        assert_eq!(
            step1,
            AuthState::Needs2FA {
                validation_type: "2fa_sms".to_string(),
                phone_mask: "+7 *** 99".to_string(),
                redirect_uri: None,
            }
        );

        let step2 = auth
            .login_password("u", "p", Some("123456"), None, None)
            .await
            .unwrap();
        assert_eq!(
            step2,
            AuthState::NeedsCaptcha {
                sid: "cap_42".to_string(),
                img_url: "https://api.vk.com/captcha.php?sid=cap_42".to_string(),
                redirect_uri: None,
            }
        );

        let step3 = auth
            .login_password("u", "p", Some("123456"), Some("cap_42"), Some("abcd"))
            .await
            .unwrap();
        assert_eq!(step3, AuthState::Authenticated { user_id: 8080 });
        assert_eq!(
            store.get_session().unwrap(),
            Some(("tok_2fa_cap".to_string(), 8080))
        );

        let reqs = server.requests().await;
        assert_eq!(reqs.len(), 3);
        assert_eq!(reqs[2].params.get("code").unwrap(), "123456");
        assert_eq!(reqs[2].params.get("validation_sid").unwrap(), "vs_keep_1");
        assert_eq!(reqs[2].params.get("captcha_sid").unwrap(), "cap_42");
        assert_eq!(reqs[2].params.get("captcha_key").unwrap(), "abcd");
    }
}
