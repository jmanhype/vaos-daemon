use anyhow::Result;
use std::path::PathBuf;
use tracing::debug;

/// Authentication state with compile-time enforcement.
///
/// Callers must pattern-match or call `require_token()` before using
/// authenticated endpoints, making "forgot to login" a compile-time concept.
// Auth utility methods kept for API completeness
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum AuthState {
    Unauthenticated,
    Authenticated {
        token: String,
        refresh_token: String,
    },
}

impl AuthState {
    /// Returns token or error -- compile-time enforces auth check.
    pub fn require_token(&self) -> Result<&str> {
        match self {
            AuthState::Authenticated { token, .. } => Ok(token),
            AuthState::Unauthenticated => anyhow::bail!("Not authenticated - call login() first"),
        }
    }

    pub fn refresh_token(&self) -> Option<&str> {
        match self {
            AuthState::Authenticated { refresh_token, .. } => Some(refresh_token),
            AuthState::Unauthenticated => None,
        }
    }

    pub fn is_authenticated(&self) -> bool {
        matches!(self, AuthState::Authenticated { .. })
    }
}

/// Persist tokens to the profile directory for session resumption.
pub fn save_tokens(profile_dir: &PathBuf, token: &str, refresh_token: &str) -> Result<()> {
    std::fs::create_dir_all(profile_dir)?;
    let token_path = profile_dir.join("token");
    let refresh_path = profile_dir.join("refresh_token");
    std::fs::write(&token_path, token)?;
    std::fs::write(&refresh_path, refresh_token)?;
    debug!("Tokens saved to {:?}", profile_dir);
    Ok(())
}

/// Load saved tokens from the profile directory.
/// Returns None if tokens are missing or empty.
pub fn load_tokens(profile_dir: &PathBuf) -> Option<(String, String)> {
    let token_path = profile_dir.join("token");
    let refresh_path = profile_dir.join("refresh_token");

    match (
        std::fs::read_to_string(&token_path),
        std::fs::read_to_string(&refresh_path),
    ) {
        (Ok(token), Ok(refresh)) => {
            let token = token.trim().to_string();
            let refresh = refresh.trim().to_string();
            if token.is_empty() {
                return None;
            }
            debug!("Loaded tokens from {:?}", profile_dir);
            Some((token, refresh))
        }
        _ => {
            debug!("No saved tokens found");
            None
        }
    }
}

/// Remove saved tokens from the profile directory.
pub fn clear_tokens(profile_dir: &PathBuf) {
    let _ = std::fs::remove_file(profile_dir.join("token"));
    let _ = std::fs::remove_file(profile_dir.join("refresh_token"));
    debug!("Tokens cleared");
}
