pub mod backend;
pub mod terminal;

use backend::BackendEvent;
use crossterm::event::Event as CrosstermEvent;

/// Voice subsystem events
#[derive(Debug)]
pub enum VoiceEvent {
    /// Transcription completed successfully
    TranscriptionReady(String),
    /// Transcription failed
    TranscriptionError(String),
    /// Recording hit the 60s limit
    RecordingStopped,
    /// Download progress for whisper binary or model
    DownloadProgress {
        label: String,
        downloaded: u64,
        total: u64,
    },
    /// Audio input level (RMS 0.0..1.0) from mic capture
    AudioLevel(f32),
}

/// Unified event type — all event sources merge into this
#[derive(Debug)]
pub enum Event {
    /// Terminal input (keys, mouse, resize)
    Terminal(CrosstermEvent),
    /// Backend SSE or HTTP response events
    Backend(BackendEvent),
    /// Voice input events
    Voice(VoiceEvent),
    /// App-internal timer events
    Tick,
    /// Health retry
    HealthRetry,
}
