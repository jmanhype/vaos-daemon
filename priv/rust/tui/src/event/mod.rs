pub mod backend;
pub mod terminal;

use backend::BackendEvent;
use crossterm::event::Event as CrosstermEvent;

/// Voice subsystem events
#[derive(Debug)]
#[allow(dead_code)]
pub enum VoiceEvent {
    /// Transcription completed successfully
    TranscriptionReady(String),
    /// Transcription failed
    TranscriptionError(String),
    /// Recording hit a time/size limit (kept for future use)
    RecordingStopped,
    /// Download progress for whisper binary or model
    DownloadProgress {
        label: String,
        downloaded: u64,
        total: u64,
    },
    /// Audio input level (RMS 0.0..1.0) from mic capture
    AudioLevel(f32),
    /// Hands-free mode: restart recording after transcription
    HandsFreeRestart,
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
