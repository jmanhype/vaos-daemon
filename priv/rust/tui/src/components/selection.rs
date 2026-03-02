/// Text selection with clipboard support via `arboard`.
///
/// Tracks a rectangular (x, y) selection from `start` to `end`.
/// The `content` field is populated externally by the caller after
/// the selection region is finalized — this component just tracks
/// the coordinates and provides the clipboard bridge.
#[allow(dead_code)]
pub struct Selection {
    active: bool,
    start: (u16, u16), // (col, row)
    end: (u16, u16),
    content: String,
}

impl Selection {
    pub fn new() -> Self {
        Self {
            active: false,
            start: (0, 0),
            end: (0, 0),
            content: String::new(),
        }
    }

    // ─── Lifecycle ────────────────────────────────────────────────────────

    /// Begin a new selection at terminal coordinates (x, y).
    #[allow(dead_code)]
    pub fn start_at(&mut self, x: u16, y: u16) {
        self.active = true;
        self.start = (x, y);
        self.end = (x, y);
        self.content.clear();
    }

    /// Extend the live selection to (x, y) — called on mouse drag.
    #[allow(dead_code)]
    pub fn extend_to(&mut self, x: u16, y: u16) {
        if self.active {
            self.end = (x, y);
        }
    }

    /// Finalize the selection.  Caller should populate `set_content` next.
    #[allow(dead_code)]
    pub fn finish(&mut self) {
        // Normalize so start <= end
        if self.end.1 < self.start.1 || (self.end.1 == self.start.1 && self.end.0 < self.start.0) {
            std::mem::swap(&mut self.start, &mut self.end);
        }
    }

    /// Supply the selected text content (extracted by the caller from the
    /// rendered buffer — we do not have direct buffer access here).
    #[allow(dead_code)]
    pub fn set_content(&mut self, text: impl Into<String>) {
        self.content = text.into();
    }

    /// Reset all selection state.
    #[allow(dead_code)]
    pub fn clear(&mut self) {
        self.active = false;
        self.start = (0, 0);
        self.end = (0, 0);
        self.content.clear();
    }

    // ─── Queries ──────────────────────────────────────────────────────────

    #[allow(dead_code)]
    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Normalized start coordinate (top-left of selection).
    #[allow(dead_code)]
    pub fn start(&self) -> (u16, u16) {
        self.start
    }

    /// Normalized end coordinate (bottom-right of selection).
    #[allow(dead_code)]
    pub fn end(&self) -> (u16, u16) {
        self.end
    }

    #[allow(dead_code)]
    pub fn content(&self) -> &str {
        &self.content
    }

    // ─── Clipboard ────────────────────────────────────────────────────────

    /// Copy the selection content to the system clipboard.
    ///
    /// Returns `Ok(())` on success, or a human-readable error string.
    #[allow(dead_code)]
    pub fn copy_to_clipboard(&self) -> Result<(), String> {
        arboard::Clipboard::new()
            .and_then(|mut cb| cb.set_text(&self.content))
            .map_err(|e| e.to_string())
    }
}
