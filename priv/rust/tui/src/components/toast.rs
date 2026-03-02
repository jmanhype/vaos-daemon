use std::time::Instant;

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

pub enum ToastLevel {
    Info,
    Warning,
    Error,
}

struct Toast {
    message: String,
    level: ToastLevel,
    created: Instant,
}

pub struct Toasts {
    queue: Vec<Toast>,
}

impl Toasts {
    pub fn new() -> Self {
        Self { queue: Vec::new() }
    }

    pub fn push(&mut self, message: String, level: ToastLevel) {
        self.queue.push(Toast {
            message,
            level,
            created: Instant::now(),
        });
        if self.queue.len() > 3 {
            self.queue.remove(0);
        }
    }

    pub fn tick(&mut self) {
        self.queue.retain(|t| t.created.elapsed().as_secs() < 4);
    }

    pub fn has_toasts(&self) -> bool {
        !self.queue.is_empty()
    }
}

impl Component for Toasts {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        for (i, toast) in self.queue.iter().enumerate() {
            if i as u16 >= area.height {
                break;
            }
            let row = Rect::new(area.x, area.y + i as u16, area.width, 1);
            let (icon, style) = match toast.level {
                ToastLevel::Info => ("\u{2713}", theme.task_done()),
                ToastLevel::Warning => ("\u{26a0}", theme.prefix_thinking()),
                ToastLevel::Error => ("\u{2718}", theme.error_text()),
            };
            let text = format!("{} {}", icon, toast.message);
            let line = Line::from(Span::styled(text, style));
            let p = Paragraph::new(line).alignment(Alignment::Right);
            frame.render_widget(p, row);
        }
    }
}
