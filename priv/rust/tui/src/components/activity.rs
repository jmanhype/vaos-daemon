use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

// Hermes-inspired contextual thinking verbs
const THINKING_PHRASES: &[&str] = &[
    "pondering",
    "reasoning",
    "analyzing",
    "processing",
    "synthesizing",
    "contemplating",
    "computing",
    "formulating",
    "deliberating",
    "reflecting",
    "brainstorming",
    "mulling",
    "cogitating",
];

/// Tool emoji + verb mapping (Hermes-inspired activity feed)
fn tool_display(name: &str) -> (&'static str, &'static str) {
    match name {
        // Search tools
        "web_search" | "WebSearch" => ("\u{1f50d}", "searching"),
        "grep" | "Grep" | "file_grep" => ("\u{1f50d}", "searching"),
        "glob" | "Glob" => ("\u{1f50d}", "finding"),

        // Read tools
        "read" | "Read" | "file_read" => ("\u{1f4d6}", "reading"),
        "web_fetch" | "WebFetch" => ("\u{1f310}", "browsing"),

        // Write tools
        "write" | "Write" | "file_write" => ("\u{270f}\u{fe0f}", "writing"),
        "file_edit" | "Edit" => ("\u{270f}\u{fe0f}", "editing"),

        // Execute tools
        "bash" | "Bash" | "terminal" | "shell_execute" => ("\u{1f4bb}", "executing"),

        // Agent tools
        "delegate" | "Delegate" | "Task" => ("\u{1f500}", "delegating"),
        "orchestrate" => ("\u{1f3af}", "orchestrating"),

        // Task tools
        "task_write" | "TaskWrite" | "TaskCreate" => ("\u{2611}\u{fe0f}", "planning"),
        "task_read" | "TaskRead" | "TaskList" => ("\u{1f4cb}", "checking"),

        // Diagnostics
        "diagnostics" | "doctor" => ("\u{1fa7a}", "diagnosing"),

        // Memory
        "memory" | "recall" | "session_search" => ("\u{1f9e0}", "recalling"),

        // MCP
        _ if name.starts_with("mcp__") => ("\u{1f527}", "extending"),

        // Fallback
        _ => ("\u{2699}\u{fe0f}", "running"),
    }
}

/// Tool activity entry in the feed
struct ToolEntry {
    name: String,
    emoji: &'static str,
    verb: &'static str,
    detail: String,
    start: std::time::Instant,
    duration_ms: Option<u64>,
    success: Option<bool>,
}

/// Verbosity level for tool display (Hermes-inspired 4-level toggle)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verbosity {
    Off,
    New,
    All,
    Verbose,
}

impl Verbosity {
    pub fn cycle(self) -> Self {
        match self {
            Self::Off => Self::New,
            Self::New => Self::All,
            Self::All => Self::Verbose,
            Self::Verbose => Self::Off,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::New => "new",
            Self::All => "all",
            Self::Verbose => "verbose",
        }
    }
}

/// Activity panel showing processing spinner, tool feed, and thinking
pub struct Activity {
    active: bool,
    thinking: bool,
    tool_feed: Vec<ToolEntry>,
    last_tool_name: String,
    input_tokens: u64,
    output_tokens: u64,
    expanded: bool,
    phrase_index: usize,
    phrase_tick: u32,
    start_time: Option<std::time::Instant>,
    pub verbosity: Verbosity,
}

impl Activity {
    pub fn new() -> Self {
        Self {
            active: false,
            thinking: false,
            tool_feed: Vec::new(),
            last_tool_name: String::new(),
            input_tokens: 0,
            output_tokens: 0,
            expanded: false,
            phrase_index: 0,
            phrase_tick: 0,
            start_time: None,
            verbosity: Verbosity::All,
        }
    }

    pub fn start(&mut self) {
        self.active = true;
        self.thinking = false;
        self.tool_feed.clear();
        self.last_tool_name.clear();
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.phrase_index = 0;
        self.phrase_tick = 0;
        self.start_time = Some(std::time::Instant::now());
    }

    pub fn stop(&mut self) {
        self.active = false;
        self.thinking = false;
        self.start_time = None;
    }

    /// Enable thinking indicator (model is reasoning before responding)
    pub fn set_thinking(&mut self, thinking: bool) {
        self.thinking = thinking;
        if thinking && !self.active {
            self.active = true;
            self.start_time = Some(std::time::Instant::now());
        }
    }

    pub fn is_thinking(&self) -> bool {
        self.thinking
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Record a tool call start
    pub fn tool_start(&mut self, name: &str, args: &str) {
        let (emoji, verb) = tool_display(name);
        // Truncate args for detail preview
        let detail = if args.len() > 60 {
            format!("{}...", &args[..57])
        } else {
            args.to_string()
        };
        self.tool_feed.push(ToolEntry {
            name: name.to_string(),
            emoji,
            verb,
            detail,
            start: std::time::Instant::now(),
            duration_ms: None,
            success: None,
        });
        self.last_tool_name = name.to_string();
        // Keep feed bounded
        if self.tool_feed.len() > 20 {
            self.tool_feed.remove(0);
        }
    }

    /// Record a tool call end
    pub fn tool_end(&mut self, name: &str, duration_ms: u64, success: bool) {
        // Find the last matching entry without a duration
        if let Some(entry) = self
            .tool_feed
            .iter_mut()
            .rev()
            .find(|e| e.name == name && e.duration_ms.is_none())
        {
            entry.duration_ms = Some(duration_ms);
            entry.success = Some(success);
        }
    }

    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
    }

    /// Call on each tick to advance the thinking phrase
    pub fn tick(&mut self) {
        if self.active {
            self.phrase_tick += 1;
            // Rotate phrase every ~3 seconds (15 ticks at 200ms)
            if self.phrase_tick % 15 == 0 {
                self.phrase_index = (self.phrase_index + 1) % THINKING_PHRASES.len();
            }
        }
    }

    pub fn height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        match self.verbosity {
            Verbosity::Off => 1,
            Verbosity::New => 2,
            Verbosity::All => {
                let feed_lines = self.visible_feed_count().min(4) as u16;
                1 + feed_lines // spinner + feed
            }
            Verbosity::Verbose => {
                let feed_lines = self.visible_feed_count().min(8) as u16;
                1 + feed_lines
            }
        }
    }

    fn visible_feed_count(&self) -> usize {
        match self.verbosity {
            Verbosity::Off => 0,
            Verbosity::New => {
                // Only show if tool changed
                if self.tool_feed.is_empty() {
                    0
                } else {
                    1
                }
            }
            Verbosity::All => self.tool_feed.len().min(4),
            Verbosity::Verbose => self.tool_feed.len().min(8),
        }
    }

    fn current_phrase(&self) -> &'static str {
        THINKING_PHRASES[self.phrase_index % THINKING_PHRASES.len()]
    }
}

impl Component for Activity {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.active || area.height == 0 {
            return;
        }
        let theme = crate::style::theme();
        let elapsed = self
            .start_time
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(0);

        // Spinner line with contextual phrase
        let spinner_frames = ["\u{25cb}", "\u{25d4}", "\u{25d1}", "\u{25d5}", "\u{25cf}"];
        let spinner_char = spinner_frames[(self.phrase_tick as usize / 2) % spinner_frames.len()];

        let mut spinner_spans = if self.thinking {
            // Thinking mode: brain icon + rotating thinking verb
            vec![
                Span::styled(format!("\u{1f9e0} {} ", spinner_char), theme.spinner()),
                Span::styled(self.current_phrase(), theme.prefix_active()),
                Span::styled(format!(" ({}s)", elapsed), theme.faint()),
            ]
        } else {
            vec![
                Span::styled(format!("{} ", spinner_char), theme.spinner()),
                Span::styled(self.current_phrase(), theme.prefix_active()),
                Span::styled(format!(" ({}s)", elapsed), theme.faint()),
            ]
        };

        if self.input_tokens > 0 || self.output_tokens > 0 {
            spinner_spans.push(Span::styled(
                format!(
                    "  \u{25b8} {}in/{}out",
                    self.input_tokens, self.output_tokens
                ),
                theme.faint(),
            ));
        }

        let spinner_line = Line::from(spinner_spans);
        frame.render_widget(Paragraph::new(spinner_line), Rect::new(area.x, area.y, area.width, 1));

        if self.verbosity == Verbosity::Off || area.height < 2 {
            return;
        }

        // Tool feed lines (Hermes-style: ┊ emoji verb  detail  duration)
        let max_lines = (area.height - 1) as usize;
        let feed_start = if self.tool_feed.len() > max_lines {
            self.tool_feed.len() - max_lines
        } else {
            0
        };

        for (i, entry) in self.tool_feed[feed_start..].iter().enumerate() {
            if i >= max_lines {
                break;
            }
            let y = area.y + 1 + i as u16;
            if y >= area.y + area.height {
                break;
            }

            let mut spans: Vec<Span<'_>> = vec![
                Span::styled("\u{2506} ", theme.faint()),
                Span::raw(format!("{} ", entry.emoji)),
                Span::styled(format!("{:<10}", entry.verb), theme.prefix_active()),
            ];

            if !entry.detail.is_empty() && self.verbosity != Verbosity::New {
                spans.push(Span::styled(&entry.detail, theme.faint()));
                spans.push(Span::raw("  "));
            }

            // Duration / status
            match (entry.duration_ms, entry.success) {
                (Some(ms), Some(true)) => {
                    spans.push(Span::styled(
                        format!("{:.1}s", ms as f64 / 1000.0),
                        theme.task_done(),
                    ));
                }
                (Some(ms), Some(false)) => {
                    spans.push(Span::styled(
                        format!("{:.1}s [error]", ms as f64 / 1000.0),
                        theme.error_text(),
                    ));
                }
                _ => {
                    // Still running
                    let running_ms = entry.start.elapsed().as_millis();
                    spans.push(Span::styled(
                        format!("{:.1}s...", running_ms as f64 / 1000.0),
                        theme.faint(),
                    ));
                }
            }

            let line = Line::from(spans);
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(area.x, y, area.width, 1),
            );
        }
    }
}
