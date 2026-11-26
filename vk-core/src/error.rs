#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum VkError {
    #[error("Invalid or expired access token")]
    InvalidToken,

    #[error("Two-factor validation required ({validation_type}): {phone_mask}")]
    ValidationRequired {
        validation_type: String,
        phone_mask: String,
    },

    #[error("Captcha required (sid: {sid})")]
    CaptchaRequired { sid: String, img_url: String },

    #[error("VK API error {code}: {message}")]
    ApiError { code: i32, message: String },

    #[error("Network error: {details}")]
    Network { details: String },

    #[error("Storage error: {details}")]
    Storage { details: String },

    #[error("Keychain error: {details}")]
    Keychain { details: String },

    #[error("Invalid input: {details}")]
    InvalidInput { details: String },

    #[error("Rate limited by VK API")]
    RateLimited,

    #[error("Internal error: {details}")]
    Internal { details: String },
}

impl From<rusqlite::Error> for VkError {
    fn from(err: rusqlite::Error) -> Self {
        Self::Storage {
            details: err.to_string(),
        }
    }
}

impl From<reqwest::Error> for VkError {
    fn from(err: reqwest::Error) -> Self {
        Self::Network {
            details: err.to_string(),
        }
    }
}

impl From<security_framework::base::Error> for VkError {
    fn from(err: security_framework::base::Error) -> Self {
        Self::Keychain {
            details: err.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::VkError;

    #[test]
    fn test_vk_error_display_formatting() {
        assert_eq!(
            VkError::InvalidToken.to_string(),
            "Invalid or expired access token"
        );
        assert_eq!(
            VkError::ValidationRequired {
                validation_type: "2fa_sms".to_string(),
                phone_mask: "+7 *** 12".to_string(),
            }
            .to_string(),
            "Two-factor validation required (2fa_sms): +7 *** 12"
        );
        assert_eq!(
            VkError::CaptchaRequired {
                sid: "9911".to_string(),
                img_url: "https://example.com/c.jpg".to_string(),
            }
            .to_string(),
            "Captcha required (sid: 9911)"
        );
        assert_eq!(
            VkError::ApiError {
                code: 5,
                message: "User authorization failed".to_string(),
            }
            .to_string(),
            "VK API error 5: User authorization failed"
        );
        assert_eq!(
            VkError::Network {
                details: "timeout".to_string(),
            }
            .to_string(),
            "Network error: timeout"
        );
        assert_eq!(
            VkError::Storage {
                details: "disk full".to_string(),
            }
            .to_string(),
            "Storage error: disk full"
        );
        assert_eq!(
            VkError::Keychain {
                details: "denied".to_string(),
            }
            .to_string(),
            "Keychain error: denied"
        );
        assert_eq!(
            VkError::InvalidInput {
                details: "empty".to_string(),
            }
            .to_string(),
            "Invalid input: empty"
        );
        assert_eq!(VkError::RateLimited.to_string(), "Rate limited by VK API");
        assert_eq!(
            VkError::Internal {
                details: "unexpected".to_string(),
            }
            .to_string(),
            "Internal error: unexpected"
        );
    }
}
