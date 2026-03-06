pub mod capture;
pub mod transcribe;

pub use capture::VoiceCapture;
pub use transcribe::{VoiceProvider, CloudTranscriber};

use std::time::Instant;

/// Voice recording state held by the App
pub struct VoiceState {
    /// Whether we are currently recording
    pub recording: bool,
    /// When recording started
    pub started_at: Option<Instant>,
    /// The active capture handle (holds the cpal stream)
    pub capture: Option<VoiceCapture>,
    /// Which transcription provider to use
    pub provider: VoiceProvider,
}

impl VoiceState {
    pub fn new() -> Self {
        let provider = match std::env::var("VOICE_PROVIDER").as_deref() {
            Ok("cloud") => {
                if let Ok(key) = std::env::var("OPENAI_API_KEY") {
                    VoiceProvider::Cloud(CloudTranscriber::new(key))
                } else {
                    tracing::warn!("VOICE_PROVIDER=cloud but no OPENAI_API_KEY, falling back to local");
                    VoiceProvider::local_or_unavailable()
                }
            }
            _ => VoiceProvider::local_or_unavailable(),
        };

        Self {
            recording: false,
            started_at: None,
            capture: None,
            provider,
        }
    }

    /// Elapsed recording time in seconds
    pub fn elapsed_secs(&self) -> u64 {
        self.started_at
            .map(|s| s.elapsed().as_secs())
            .unwrap_or(0)
    }
}
