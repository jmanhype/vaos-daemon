use crossterm::event::EventStream;
use futures::StreamExt;
use tokio::sync::mpsc;
use tracing::debug;

use super::Event;

/// Spawn terminal event reader task.
/// Reads from crossterm's async EventStream and forwards into the unified mpsc channel.
pub fn spawn_terminal_reader(tx: mpsc::UnboundedSender<Event>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut reader = EventStream::new();
        loop {
            match reader.next().await {
                Some(Ok(event)) => {
                    if tx.send(Event::Terminal(event)).is_err() {
                        break; // receiver dropped
                    }
                }
                Some(Err(e)) => {
                    debug!("Terminal event error: {}", e);
                    break;
                }
                None => break,
            }
        }
    })
}
