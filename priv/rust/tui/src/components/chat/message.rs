use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, BorderType, Paragraph, Wrap};
use crate::client::types::Signal;
use crate::style;

/// Message types
#[derive(Debug, Clone)]
pub enum MessageType {
    User,
    Agent,
    SystemInfo,
    SystemWarning,
    SystemError,
}

/// A chat message
pub struct Message {
    pub msg_type: MessageType,
    pub content: String,
    pub signal: Option<Signal>,
    /// Cached height for given width
    cached_height: Option<(u16, u16)>,
}

impl Message {
    pub fn new(msg_type: MessageType, content: String, signal: Option<Signal>) -> Self {
        Self {
            msg_type,
            content,
            signal,
            cached_height: None,
        }
    }

    pub fn invalidate_cache(&mut self) {
        self.cached_height = None;
    }

    pub fn height(&self, width: u16) -> u16 {
        if let Some((cached_w, cached_h)) = self.cached_height {
            if cached_w == width {
                return cached_h;
            }
        }

        let content_width = width.saturating_sub(4); // borders + padding
        if content_width == 0 {
            return 1;
        }

        let lines: Vec<&str> = self.content.lines().collect();
        let mut height: u16 = 0;
        for line in &lines {
            let line_len = unicode_width::UnicodeWidthStr::width(*line) as u16;
            let wrapped_lines = if content_width > 0 {
                (line_len / content_width) + 1
            } else {
                1
            };
            height += wrapped_lines;
        }
        if lines.is_empty() {
            height = 1;
        }

        // Label line for user/agent messages
        match self.msg_type {
            MessageType::User | MessageType::Agent => height += 1,
            _ => {}
        }

        height.max(2)
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        match self.msg_type {
            MessageType::User => self.draw_user(frame, area, &theme),
            MessageType::Agent => self.draw_agent(frame, area, &theme),
            MessageType::SystemInfo => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_system)
            }
            MessageType::SystemWarning => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_warning)
            }
            MessageType::SystemError => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_error)
            }
        }
    }

    fn draw_user(&self, frame: &mut Frame, area: Rect, theme: &style::Theme) {
        if area.height == 0 {
            return;
        }

        let label_area = Rect::new(area.x, area.y, area.width, 1);
        let label = Line::from(vec![
            Span::styled("❯  ", theme.prompt_char()),
            Span::styled("You", theme.user_label()),
        ]);
        frame.render_widget(Paragraph::new(label), label_area);

        if area.height > 1 {
            let content_area = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_user));

            let paragraph = Paragraph::new(self.content.as_str())
                .block(block)
                .wrap(Wrap { trim: false });
            frame.render_widget(paragraph, content_area);
        }
    }

    fn draw_agent(&self, frame: &mut Frame, area: Rect, theme: &style::Theme) {
        if area.height == 0 {
            return;
        }

        let label_area = Rect::new(area.x, area.y, area.width, 1);
        let mut label_spans = vec![
            Span::styled("◈ ", theme.agent_label()),
            Span::styled("OSA", theme.agent_label()),
        ];

        if let Some(ref signal) = self.signal {
            if !signal.mode.is_empty() {
                label_spans.push(Span::styled("  ", Style::default()));
                label_spans.push(Span::styled(
                    format!("[{}/{}]", signal.mode, signal.genre),
                    theme.status_signal(),
                ));
            }
        }

        frame.render_widget(Paragraph::new(Line::from(label_spans)), label_area);

        if area.height > 1 {
            let content_area = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_agent));

            let paragraph = Paragraph::new(self.content.as_str())
                .block(block)
                .wrap(Wrap { trim: false });
            frame.render_widget(paragraph, content_area);
        }
    }

    fn draw_system(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &style::Theme,
        border_color: Color,
    ) {
        let block = Block::default()
            .borders(Borders::LEFT)
            .border_type(BorderType::Plain)
            .border_style(Style::default().fg(border_color));

        let style = match self.msg_type {
            MessageType::SystemError => theme.error_text(),
            MessageType::SystemWarning => theme.prefix_thinking(),
            _ => theme.faint(),
        };

        let paragraph = Paragraph::new(Span::styled(self.content.as_str(), style))
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(paragraph, area);
    }
}
