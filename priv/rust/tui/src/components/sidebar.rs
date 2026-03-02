use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

// ─── Types ────────────────────────────────────────────────────────────────────

#[allow(dead_code)]
struct SidebarSection {
    title: String,
    items: Vec<(String, String)>, // (label, value)
}

// ─── Sidebar ─────────────────────────────────────────────────────────────────

/// Vertical side panel displaying session and context metadata.
///
/// Layout (per section):
///   [title]
///   label  value
///   ...
///
/// A dim left-border character is drawn at x=0 of the area on each row.
#[allow(dead_code)]
pub struct Sidebar {
    provider: String,
    model: String,
    session_id: String,
    tool_count: usize,
    context_pct: f64,
    sections: Vec<SidebarSection>,
    width: u16,
}

impl Sidebar {
    pub fn new() -> Self {
        let mut s = Self {
            provider: String::new(),
            model: String::new(),
            session_id: String::new(),
            tool_count: 0,
            context_pct: 0.0,
            sections: Vec::new(),
            width: 24,
        };
        s.rebuild_sections();
        s
    }

    // ─── Configuration setters ────────────────────────────────────────────

    #[allow(dead_code)]
    pub fn set_width(&mut self, w: u16) {
        self.width = w;
    }

    #[allow(dead_code)]
    pub fn set_provider_info(&mut self, provider: impl Into<String>, model: impl Into<String>) {
        self.provider = provider.into();
        self.model = model.into();
        self.rebuild_sections();
    }

    #[allow(dead_code)]
    pub fn set_session(&mut self, id: impl Into<String>) {
        self.session_id = id.into();
        self.rebuild_sections();
    }

    #[allow(dead_code)]
    pub fn set_tool_count(&mut self, n: usize) {
        self.tool_count = n;
        self.rebuild_sections();
    }

    #[allow(dead_code)]
    pub fn set_context(&mut self, pct: f64) {
        self.context_pct = pct.clamp(0.0, 1.0);
        self.rebuild_sections();
    }

    // ─── Layout ───────────────────────────────────────────────────────────

    /// Total height occupied by all sections (title + items + gap).
    pub fn height(&self) -> u16 {
        let mut h = 0u16;
        for section in &self.sections {
            h += 1; // title
            h += section.items.len() as u16;
            h += 1; // blank gap between sections
        }
        h.saturating_sub(1) // no trailing blank after last section
    }

    // ─── Private helpers ──────────────────────────────────────────────────

    fn rebuild_sections(&mut self) {
        self.sections.clear();

        // ── Provider / Model ──────────────────────────────────────────────
        if !self.provider.is_empty() || !self.model.is_empty() {
            self.sections.push(SidebarSection {
                title: "Provider".into(),
                items: vec![
                    ("via".into(), self.provider.clone()),
                    ("model".into(), self.truncate_value(&self.model, 14)),
                ],
            });
        }

        // ── Session ───────────────────────────────────────────────────────
        if !self.session_id.is_empty() {
            let short_id = self.truncate_session_id(&self.session_id);
            self.sections.push(SidebarSection {
                title: "Session".into(),
                items: vec![("id".into(), short_id)],
            });
        }

        // ── Context window ────────────────────────────────────────────────
        {
            // Visual bar width = inner width - label prefix "ctx " (4)
            let bar_w = (self.width as usize).saturating_sub(8).max(4);
            let filled = ((self.context_pct * bar_w as f64).round() as usize).min(bar_w);
            let empty = bar_w - filled;
            let bar = format!("{}{}", "\u{2588}".repeat(filled), "\u{2591}".repeat(empty));
            let pct_str = format!("{}%", (self.context_pct * 100.0) as u32);

            self.sections.push(SidebarSection {
                title: "Context".into(),
                items: vec![
                    ("ctx".into(), bar),
                    ("use".into(), pct_str),
                ],
            });
        }

        // ── Tools ─────────────────────────────────────────────────────────
        self.sections.push(SidebarSection {
            title: "Tools".into(),
            items: vec![("count".into(), self.tool_count.to_string())],
        });
    }

    fn truncate_value(&self, s: &str, max: usize) -> String {
        if s.len() <= max {
            s.to_string()
        } else {
            format!("{}…", &s[..max.saturating_sub(1)])
        }
    }

    fn truncate_session_id(&self, id: &str) -> String {
        // Show last 12 chars prefixed with "…"
        if id.len() > 12 {
            format!("\u{2026}{}", &id[id.len() - 12..])
        } else {
            id.to_string()
        }
    }
}

impl Component for Sidebar {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width < 3 {
            return;
        }
        let theme = crate::style::theme();

        // Inner area for text (leave column 0 for the left border glyph).
        let inner_x = area.x + 2;
        let inner_w = area.width.saturating_sub(2);

        let mut y = area.y;

        let section_count = self.sections.len();
        for (si, section) in self.sections.iter().enumerate() {
            if y >= area.y + area.height {
                break;
            }

            // Left border on every row of this section (title + items + gap)
            let section_h = 1 + section.items.len() as u16 + if si + 1 < section_count { 1 } else { 0 };
            for row in 0..section_h {
                let ry = y + row;
                if ry >= area.y + area.height {
                    break;
                }
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        "\u{2502}",
                        theme.sidebar_separator(),
                    ))),
                    Rect::new(area.x, ry, 1, 1),
                );
            }

            // Section title
            if inner_w > 0 {
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        &section.title,
                        theme.sidebar_title(),
                    ))),
                    Rect::new(inner_x, y, inner_w, 1),
                );
            }
            y += 1;

            // Items: "label  value"
            for (label, value) in &section.items {
                if y >= area.y + area.height {
                    break;
                }

                // label column: 5 chars wide
                let label_col = 5usize;
                let label_trunc = self.truncate_value(label, label_col);
                let value_max = (inner_w as usize).saturating_sub(label_col + 1);
                let value_trunc = self.truncate_value(value, value_max);

                let line = Line::from(vec![
                    Span::styled(format!("{:<5} ", label_trunc), theme.sidebar_label()),
                    Span::styled(value_trunc, theme.sidebar_value()),
                ]);

                if inner_w > 0 {
                    frame.render_widget(
                        Paragraph::new(line),
                        Rect::new(inner_x, y, inner_w, 1),
                    );
                }
                y += 1;
            }

            // Gap between sections (except after the last one)
            if si + 1 < section_count {
                y += 1;
            }
        }
    }
}
