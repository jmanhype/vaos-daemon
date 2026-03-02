use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};

pub struct Header {
    provider: String,
    model_name: String,
    version: String,
    tool_count: usize,
    workspace: String,
    width: u16,
}

impl Header {
    pub fn new() -> Self {
        Self {
            provider: String::new(),
            model_name: String::new(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            tool_count: 0,
            workspace: std::env::current_dir()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
            width: 0,
        }
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
    }

    pub fn set_tool_count(&mut self, count: usize) {
        self.tool_count = count;
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn tool_count(&self) -> usize {
        self.tool_count
    }

    pub fn provider(&self) -> &str {
        &self.provider
    }

    pub fn model_name(&self) -> &str {
        &self.model_name
    }

    /// Compact one-liner: "OSA v0.2.5 . provider / model . N tools"
    pub fn draw_compact(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        let mut spans = vec![
            Span::styled("OSA ", theme.banner_title()),
            Span::styled(format!("v{}", self.version), theme.header_version()),
        ];

        if !self.provider.is_empty() {
            spans.push(Span::styled(" \u{00b7} ", theme.header_separator()));
            spans.push(Span::styled(&self.provider, theme.header_provider()));
            spans.push(Span::styled(" / ", theme.header_separator()));
            spans.push(Span::styled(&self.model_name, theme.header_model()));
        }

        if self.tool_count > 0 {
            spans.push(Span::styled(" \u{00b7} ", theme.header_separator()));
            spans.push(Span::styled(
                format!("{} tools", self.tool_count),
                theme.faint(),
            ));
        }

        let line = Line::from(spans);
        let header = Paragraph::new(line);
        frame.render_widget(header, area);

        // Separator line
        if area.height > 1 {
            let sep_area = Rect::new(area.x, area.y + 1, area.width, 1);
            let separator = Paragraph::new("\u{2500}".repeat(area.width as usize))
                .style(theme.header_separator());
            frame.render_widget(separator, sep_area);
        }
    }

    /// Full banner view for startup (with logo in bordered box)
    pub fn draw_full(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        let mut lines = vec![
            style::gradient::theme_gradient(
                "  \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557}  ",
                true,
            ),
            style::gradient::theme_gradient(
                "  \u{2551}   \u{2551} \u{2551}     \u{2551}   \u{2551}  ",
                true,
            ),
            style::gradient::theme_gradient(
                "  \u{2551}   \u{2551}  \u{2550}\u{2550}\u{2550}\u{2557} \u{2560}\u{2550}\u{2550}\u{2550}\u{2563}  ",
                true,
            ),
            style::gradient::theme_gradient(
                "  \u{2551}   \u{2551}     \u{2551} \u{2551}   \u{2551}  ",
                true,
            ),
            style::gradient::theme_gradient(
                "  \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{2551}   \u{2551}  ",
                true,
            ),
            Line::from(""),
            Line::from(vec![
                Span::styled("\u{25c8} ", theme.banner_title()),
                Span::styled("OSA Agent  ", theme.banner_title()),
                Span::styled(format!("v{}", self.version), theme.header_version()),
            ]),
            Line::from(Span::styled("Your OS, Supercharged", theme.banner_detail())),
        ];

        if !self.workspace.is_empty() {
            // Truncate long paths
            let cwd = if self.workspace.len() > 60 {
                format!("...{}", &self.workspace[self.workspace.len() - 57..])
            } else {
                self.workspace.clone()
            };
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(cwd, theme.welcome_cwd())));
        }

        let text = Text::from(lines);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(ratatui::widgets::BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary));

        let paragraph = Paragraph::new(text)
            .block(block)
            .alignment(Alignment::Center);
        frame.render_widget(paragraph, area);
    }
}

impl Component for Header {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        self.draw_compact(frame, area);
    }
}
