use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use std::path::Path;

// ─── Types ────────────────────────────────────────────────────────────────────

#[allow(dead_code)]
struct AttachedFile {
    name: String,
    path: String,
    size: u64,
}

// ─── Attachments ─────────────────────────────────────────────────────────────

/// Horizontal chip row rendered just above the input box.
///
/// Renders as:  📎 file.rs (2.1KB)  📎 other.go (4.3KB)
/// When empty: renders nothing (height = 0).
#[allow(dead_code)]
pub struct Attachments {
    files: Vec<AttachedFile>,
}

impl Attachments {
    pub fn new() -> Self {
        Self { files: Vec::new() }
    }

    // ─── Mutation ──────────────────────────────────────────────────────────

    /// Add a file by its filesystem path.
    ///
    /// If the path cannot be stat'd the size is recorded as 0.
    #[allow(dead_code)]
    pub fn add(&mut self, path: String) {
        let name = Path::new(&path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.clone());

        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);

        self.files.push(AttachedFile { name, path, size });
    }

    #[allow(dead_code)]
    pub fn remove(&mut self, index: usize) {
        if index < self.files.len() {
            self.files.remove(index);
        }
    }

    #[allow(dead_code)]
    pub fn clear(&mut self) {
        self.files.clear();
    }

    // ─── Queries ───────────────────────────────────────────────────────────

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// Height is either 0 (no attachments) or 1 (chip row).
    pub fn height(&self) -> u16 {
        if self.files.is_empty() { 0 } else { 1 }
    }

    // ─── Draw ──────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if self.files.is_empty() || area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();
        let mut spans: Vec<Span<'_>> = Vec::new();

        for (i, file) in self.files.iter().enumerate() {
            if i > 0 {
                // Two-space separator between chips
                spans.push(Span::raw("  "));
            }

            let size_str = Self::fmt_size(file.size);

            // 📎 name (size)
            spans.push(Span::styled("\u{1f4ce} ", theme.faint()));
            spans.push(Span::styled(&file.name, theme.bold()));
            spans.push(Span::styled(
                format!(" ({})", size_str),
                theme.faint(),
            ));
        }

        let line = Line::from(spans);
        frame.render_widget(Paragraph::new(line), area);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    fn fmt_size(bytes: u64) -> String {
        if bytes >= 1_048_576 {
            format!("{:.1}MB", bytes as f64 / 1_048_576.0)
        } else if bytes >= 1024 {
            format!("{:.1}KB", bytes as f64 / 1024.0)
        } else {
            format!("{}B", bytes)
        }
    }
}
