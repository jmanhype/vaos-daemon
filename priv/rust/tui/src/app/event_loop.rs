use anyhow::Result;
use ratatui::prelude::*;
use std::time::Duration;
use tokio::time;
use tracing::info;

use super::App;
use crate::event::{terminal, Event};

impl App {
    pub async fn run(
        &mut self,
        terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    ) -> Result<()> {
        // Spawn terminal event reader
        let term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());

        // Spawn tick timer
        let tick_tx = self.event_tx.clone();
        let tick_handle = tokio::spawn(async move {
            let mut interval = time::interval(Duration::from_millis(200));
            loop {
                interval.tick().await;
                if tick_tx.send(Event::Tick).is_err() {
                    break;
                }
            }
        });

        // Initial health check
        self.check_health();

        // Main loop
        loop {
            // Render
            terminal.draw(|frame| self.draw(frame))?;

            // Wait for next event
            match self.event_rx.recv().await {
                Some(event) => {
                    let should_quit = self.update(event);
                    if should_quit {
                        break;
                    }
                }
                None => break, // all senders dropped
            }
        }

        // Cleanup
        tick_handle.abort();
        term_handle.abort();
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        info!("App exiting cleanly");
        Ok(())
    }

    fn draw(&self, frame: &mut Frame) {
        let area = frame.area();

        match self.state {
            crate::app::state::AppState::Connecting => {
                crate::view::connecting::draw_connecting(frame, area);
            }
            crate::app::state::AppState::Banner => {
                // Show full banner + input
                let banner_height = area.height.saturating_sub(3);
                let banner_area = Rect::new(area.x, area.y, area.width, banner_height);
                self.header.draw_full(frame, banner_area);

                let input_area =
                    Rect::new(area.x, area.y + banner_height, area.width, 3);
                self.input.draw(frame, input_area);
            }
            _ => {
                // Normal layout
                let areas = crate::view::main_layout::LayoutAreas::compute(
                    area,
                    &self.layout,
                    self.tasks.height(),
                    self.agents.height(),
                );

                // Header
                self.header.draw_compact(frame, areas.header);

                // Chat
                self.chat.draw(frame, areas.chat);

                // Tasks
                if let Some(task_area) = areas.tasks {
                    self.tasks.draw(frame, task_area);
                }

                // Agents
                if let Some(agent_area) = areas.agents {
                    self.agents.draw(frame, agent_area);
                }

                // Activity (overlay on chat during processing)
                if self.activity.is_active() {
                    let activity_area = Rect::new(
                        areas.chat.x,
                        areas.chat.y + areas.chat.height.saturating_sub(2),
                        areas.chat.width,
                        2,
                    );
                    self.activity.draw(frame, activity_area);
                }

                // Status bar
                self.status.draw(frame, areas.status);

                // Input
                self.input.draw(frame, areas.input);

                // Toast overlay
                if self.toasts.has_toasts() {
                    self.toasts.draw(frame, areas.toast);
                }
            }
        }
    }
}

// Components implement the Component trait for draw/handle_event.
// We call draw methods directly on concrete types in draw() above.
use crate::components::Component;
