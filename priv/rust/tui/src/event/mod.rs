pub mod backend;
pub mod terminal;

use backend::BackendEvent;
use crossterm::event::Event as CrosstermEvent;

/// Unified event type — all event sources merge into this
#[derive(Debug)]
pub enum Event {
    /// Terminal input (keys, mouse, resize)
    Terminal(CrosstermEvent),
    /// Backend SSE or HTTP response events
    Backend(BackendEvent),
    /// App-internal timer events
    Tick,
    /// Health retry
    HealthRetry,
}
