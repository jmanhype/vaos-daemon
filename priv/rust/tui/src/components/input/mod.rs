pub mod completions;
pub mod history;
pub mod textarea;

use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyModifiers};
use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;
use crate::style;

use super::{AppAction, Component, ComponentAction};

pub struct InputComponent {
    /// The text content
    content: String,
    /// Cursor position within content
    cursor: usize,
    /// Command history
    history: history::History,
    /// Whether the input is focused
    focused: bool,
    /// Width for rendering
    width: u16,
    /// Multiline mode
    multiline: bool,
    /// Available commands for tab completion
    commands: Vec<String>,
    /// Tab completion state
    tab_matches: Vec<String>,
    tab_index: usize,
}

impl InputComponent {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            cursor: 0,
            history: history::History::new(100),
            focused: true,
            width: 80,
            multiline: false,
            commands: Vec::new(),
            tab_matches: Vec::new(),
            tab_index: 0,
        }
    }

    pub fn value(&self) -> &str {
        &self.content
    }

    pub fn is_empty(&self) -> bool {
        self.content.trim().is_empty()
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn set_commands(&mut self, commands: Vec<String>) {
        self.commands = commands;
    }

    pub fn submit(&mut self) -> String {
        let text = self.content.clone();
        if !text.trim().is_empty() {
            self.history.push(text.clone());
        }
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
        text
    }

    pub fn reset(&mut self) {
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
    }

    pub fn set_content(&mut self, text: &str) {
        self.content = text.to_string();
        self.cursor = self.content.len();
    }

    fn insert_char(&mut self, ch: char) {
        self.content.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
        self.tab_matches.clear();
    }

    fn delete_char(&mut self) {
        if self.cursor > 0 {
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.content.drain(self.cursor - prev..self.cursor);
            self.cursor -= prev;
            self.tab_matches.clear();
        }
    }

    fn move_left(&mut self) {
        if self.cursor > 0 {
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor -= prev;
        }
    }

    fn move_right(&mut self) {
        if self.cursor < self.content.len() {
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor += next;
        }
    }

    fn handle_tab(&mut self) {
        if !self.content.starts_with('/') {
            return;
        }

        if self.tab_matches.is_empty() {
            // Build matches
            let prefix = &self.content[1..]; // skip the /
            self.tab_matches = self
                .commands
                .iter()
                .filter(|cmd| cmd.starts_with(prefix))
                .map(|cmd| format!("/{}", cmd))
                .collect();
            self.tab_index = 0;
        } else if !self.tab_matches.is_empty() {
            self.tab_index = (self.tab_index + 1) % self.tab_matches.len();
        }

        if let Some(match_) = self.tab_matches.get(self.tab_index) {
            self.content = match_.clone();
            self.cursor = self.content.len();
        }
    }
}

impl Component for InputComponent {
    fn handle_event(&mut self, event: &Event) -> ComponentAction {
        if !self.focused {
            return ComponentAction::Ignored;
        }

        match event {
            Event::Terminal(CrosstermEvent::Key(key)) => {
                match (key.code, key.modifiers) {
                    // Submit (single-line mode)
                    (KeyCode::Enter, KeyModifiers::NONE) if !self.multiline => {
                        if self.content.trim().is_empty() {
                            return ComponentAction::Consumed;
                        }
                        let text = self.submit();
                        return ComponentAction::Emit(AppAction::Submit(text));
                    }
                    // Alt+Enter: insert newline (enters multiline mode)
                    (KeyCode::Enter, m) if m == KeyModifiers::ALT => {
                        self.multiline = true;
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // Enter in multiline: also newline
                    (KeyCode::Enter, KeyModifiers::NONE) if self.multiline => {
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // Backspace
                    (KeyCode::Backspace, KeyModifiers::NONE) => {
                        self.delete_char();
                        if !self.content.contains('\n') {
                            self.multiline = false;
                        }
                        return ComponentAction::Consumed;
                    }
                    // Arrow keys
                    (KeyCode::Left, KeyModifiers::NONE) => {
                        self.move_left();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Right, KeyModifiers::NONE) => {
                        self.move_right();
                        return ComponentAction::Consumed;
                    }
                    // Home/End within input
                    (KeyCode::Home, KeyModifiers::NONE) if !self.is_empty() => {
                        self.cursor = 0;
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::End, KeyModifiers::NONE) if !self.is_empty() => {
                        self.cursor = self.content.len();
                        return ComponentAction::Consumed;
                    }
                    // History up/down (only in single-line mode)
                    (KeyCode::Up, KeyModifiers::NONE) if !self.multiline => {
                        if let Some(text) = self.history.prev() {
                            self.content = text.to_string();
                            self.cursor = self.content.len();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE) if !self.multiline => {
                        if let Some(text) = self.history.next() {
                            self.content = text.to_string();
                            self.cursor = self.content.len();
                        } else {
                            self.content.clear();
                            self.cursor = 0;
                        }
                        return ComponentAction::Consumed;
                    }
                    // Tab completion
                    (KeyCode::Tab, KeyModifiers::NONE) => {
                        self.handle_tab();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+U: clear
                    (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                        self.reset();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+A: move to start
                    (KeyCode::Char('a'), KeyModifiers::CONTROL) => {
                        self.cursor = 0;
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+E: move to end
                    (KeyCode::Char('e'), KeyModifiers::CONTROL) => {
                        self.cursor = self.content.len();
                        return ComponentAction::Consumed;
                    }
                    // Regular character input
                    (KeyCode::Char(ch), m)
                        if m == KeyModifiers::NONE || m == KeyModifiers::SHIFT =>
                    {
                        self.insert_char(ch);
                        return ComponentAction::Consumed;
                    }
                    _ => {}
                }
                ComponentAction::Ignored
            }
            _ => ComponentAction::Ignored,
        }
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        if area.height < 2 {
            return;
        }

        // Separator line
        let sep_area = Rect::new(area.x, area.y, area.width, 1);
        let separator =
            Paragraph::new("\u{2500}".repeat(area.width as usize)).style(theme.header_separator());
        frame.render_widget(separator, sep_area);

        // Input line
        let input_area = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
        let prompt = if self.focused { "\u{276f} " } else { "  " };
        let prompt_style = if self.focused {
            theme.prompt_char()
        } else {
            theme.faint()
        };

        if self.content.is_empty() {
            let line = Line::from(vec![
                Span::styled(prompt, prompt_style),
                Span::styled("Type a message...", theme.input_placeholder()),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);
        } else {
            let line = Line::from(vec![
                Span::styled(prompt, prompt_style),
                Span::raw(&self.content),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);

            // Right-aligned hints for multiline
            if self.multiline {
                let line_count = self.content.lines().count();
                let hint = format!("[{} lines \u{00b7} alt+enter newline]", line_count);
                let hint_width = hint.len() as u16;
                if input_area.width > hint_width + 10 {
                    let hint_area = Rect::new(
                        input_area.x + input_area.width - hint_width,
                        input_area.y,
                        hint_width,
                        1,
                    );
                    frame.render_widget(
                        Paragraph::new(Span::styled(hint, theme.hint())),
                        hint_area,
                    );
                }
            }
        }

        // Show cursor
        if self.focused {
            let cursor_x = area.x + 2 + self.cursor as u16; // 2 for prompt
            let cursor_y = area.y + 1;
            if cursor_x < area.x + area.width {
                frame.set_cursor_position(Position::new(cursor_x, cursor_y));
            }
        }
    }

    fn set_focused(&mut self, focused: bool) {
        self.focused = focused;
    }
}
