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

                // Sidebar
                if let Some(sidebar_area) = areas.sidebar {
                    self.sidebar.draw(frame, sidebar_area);
                }

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

                // Thinking box (collapsed indicator above status when thinking)
                if !self.thinking_box.is_empty() {
                    let tb_height = self.thinking_box.height(areas.chat.width).min(2);
                    let tb_y = areas.status.y.saturating_sub(tb_height);
                    let thinking_area = Rect::new(
                        areas.chat.x,
                        tb_y,
                        areas.chat.width,
                        tb_height,
                    );
                    self.thinking_box.draw(frame, thinking_area);
                }

                // Status bar
                self.status.draw(frame, areas.status);

                // Input
                self.input.draw(frame, areas.input);

                // Toast overlay
                if self.toasts.has_toasts() {
                    self.toasts.draw(frame, areas.toast);
                }

                // Dialog overlays (drawn last = on top)
                if self.state.is_overlay() {
                    match self.state {
                        crate::app::state::AppState::Quit => {
                            self.quit_dialog.draw(frame, area);
                        }
                        crate::app::state::AppState::Palette => {
                            self.palette.draw(frame, area);
                        }
                        crate::app::state::AppState::ModelPicker => {
                            if let Some(ref picker) = self.model_picker {
                                picker.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::Sessions => {
                            if let Some(ref browser) = self.session_browser {
                                browser.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::Onboarding => {
                            if let Some(ref wizard) = self.onboarding {
                                wizard.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::Permissions => {
                            if let Some(ref dialog) = self.permissions {
                                dialog.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::PlanReview => {
                            if let Some(ref review) = self.plan_review {
                                review.draw(frame, area);
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

// Components implement the Component trait for draw/handle_event.
// We call draw methods directly on concrete types in draw() above.
use crate::components::Component;
