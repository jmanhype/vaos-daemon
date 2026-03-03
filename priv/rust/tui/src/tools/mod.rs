pub mod agent;
pub mod bash;
pub mod diagnostics;
pub mod file;
pub mod generic;
pub mod mcp;
pub mod references;
pub mod search;
pub mod todos;
pub mod web;

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

// ─── Status ───────────────────────────────────────────────────────────────────

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ToolStatus {
    Pending,
    AwaitingPermission,
    Running,
    Success,
    Error,
    Canceled,
}

// ─── RenderOpts ───────────────────────────────────────────────────────────────

pub struct RenderOpts {
    pub status: ToolStatus,
    pub width: u16,
    pub expanded: bool,
    pub compact: bool,
    pub spinner_frame: Option<char>,
    pub duration_ms: u64,
    pub truncated: bool,
}

// ─── Trait ────────────────────────────────────────────────────────────────────

pub trait ToolRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>>;
}

// ─── Registry ─────────────────────────────────────────────────────────────────

pub fn render_tool(name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
    let lower = name.to_lowercase();

    // MCP prefix: mcp__server__tool
    if lower.starts_with("mcp__") || lower == "mcp" || lower == "mcp_tool" {
        return mcp::McpRenderer.render(name, args, result, opts);
    }

    match lower.as_str() {
        // Bash
        "bash" | "run_bash_command" => {
            bash::BashRenderer.render(name, args, result, opts)
        }

        // File: Read
        "read" | "read_file" | "file_read" => {
            file::FileViewRenderer.render(name, args, result, opts)
        }

        // File: Write
        "write" | "write_file" => {
            file::FileWriteRenderer.render(name, args, result, opts)
        }

        // File: Edit / MultiEdit / Download
        "edit" | "edit_file" | "file_edit" | "str_replace_editor"
        | "multiedit" | "multi_edit" | "download" => {
            file::FileEditRenderer.render(name, args, result, opts)
        }

        // Search: Glob
        "glob" | "file_glob" => {
            search::GlobRenderer.render(name, args, result, opts)
        }

        // Search: Grep
        "grep" | "file_grep" => {
            search::GrepRenderer.render(name, args, result, opts)
        }

        // Search: LS
        "ls" | "list_directory" => {
            search::LsRenderer.render(name, args, result, opts)
        }

        // Web
        "web_fetch" | "webfetch" | "fetch" => {
            web::WebFetchRenderer.render(name, args, result, opts)
        }
        "web_search" | "websearch" => {
            web::WebSearchRenderer.render(name, args, result, opts)
        }

        // Agent / Task
        "task" | "agent" | "sub_agent" | "orchestrate" => {
            agent::AgentRenderer.render(name, args, result, opts)
        }
        "delegate" => {
            agent::DelegateRenderer.render(name, args, result, opts)
        }

        // Todos
        "todoread" | "todowrite" | "todos" | "task_write" => {
            todos::TodosRenderer.render(name, args, result, opts)
        }

        // Diagnostics
        "diagnostics" => {
            diagnostics::DiagnosticsRenderer.render(name, args, result, opts)
        }

        // References
        "references" => {
            references::ReferencesRenderer.render(name, args, result, opts)
        }

        // Generic fallback
        _ => generic::GenericRenderer.render(name, args, result, opts),
    }
}

// ─── Shared Helpers ───────────────────────────────────────────────────────────

/// Returns `(icon_string, icon_style)` for a given status.
pub(crate) fn status_icon(status: ToolStatus, spinner: Option<char>) -> (String, Style) {
    let theme = crate::style::theme();
    match status {
        ToolStatus::Pending => (
            "○".to_string(),
            Style::default().fg(theme.colors.muted),
        ),
        ToolStatus::AwaitingPermission => (
            "◐".to_string(),
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Running => {
            let icon = spinner
                .map(|c| c.to_string())
                .unwrap_or_else(|| "⏺".to_string());
            (
                icon,
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            )
        }
        ToolStatus::Success => (
            "✓".to_string(),
            Style::default()
                .fg(theme.colors.success)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Error => (
            "✘".to_string(),
            Style::default()
                .fg(theme.colors.error)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Canceled => (
            "⊘".to_string(),
            Style::default().fg(theme.colors.muted),
        ),
    }
}

/// Human-readable duration: "55ms", "1.2s", "2m 3s".
pub(crate) fn format_duration(ms: u64) -> String {
    if ms == 0 {
        return String::new();
    }
    if ms < 1000 {
        return format!("{}ms", ms);
    }
    let secs = ms as f64 / 1000.0;
    if secs < 60.0 {
        return format!("{:.1}s", secs);
    }
    let minutes = (secs / 60.0) as u64;
    let remaining = secs as u64 % 60;
    format!("{}m {}s", minutes, remaining)
}

/// Truncate `lines` to `max`, appending a dim "... (N more lines)" hint.
pub(crate) fn truncate_lines(mut lines: Vec<Line<'static>>, max: usize) -> Vec<Line<'static>> {
    if lines.len() <= max {
        return lines;
    }
    let total = lines.len();
    lines.truncate(max);
    let theme = crate::style::theme();
    lines.push(Line::from(Span::styled(
        format!("  … ({} more lines)", total - max),
        Style::default().fg(theme.colors.dim),
    )));
    lines
}

/// Wrap each body line with a `│ ` left-border prefix.
/// Returns `[header_line, │ body_line, …]`.
pub(crate) fn render_tool_box(
    header: Line<'static>,
    body: Vec<Line<'static>>,
) -> Vec<Line<'static>> {
    let theme = crate::style::theme();
    let border_style = Style::default().fg(theme.colors.border);

    let mut out: Vec<Line<'static>> = Vec::with_capacity(body.len() + 1);
    out.push(header);

    for line in body {
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
        spans.push(Span::styled("│ ".to_string(), border_style));
        spans.extend(line.spans);
        out.push(Line::from(spans));
    }

    out
}

/// Extract the first matching key value from a JSON string (args).
/// Handles string and number values.
pub(crate) fn parse_json_arg(args: &str, keys: &[&str]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(args).ok()?;
    for key in keys {
        if let Some(val) = v.get(*key) {
            match val {
                serde_json::Value::String(s) => return Some(s.clone()),
                serde_json::Value::Number(n) => return Some(n.to_string()),
                serde_json::Value::Bool(b) => return Some(b.to_string()),
                _ => {}
            }
        }
    }
    None
}

/// Build a standard single-line collapsed header:
///   `<icon> <tool_name>  <detail>  <duration>`
pub(crate) fn make_header(
    status: ToolStatus,
    spinner: Option<char>,
    tool_display: &str,
    detail: &str,
    duration_ms: u64,
) -> Line<'static> {
    let theme = crate::style::theme();
    let (icon, icon_style) = status_icon(status, spinner);

    let mut spans = vec![
        Span::styled(icon, icon_style),
        Span::raw(" "),
        Span::styled(tool_display.to_string(), theme.tool_name()),
    ];

    if !detail.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(detail.to_string(), theme.tool_arg()));
    }

    let dur = format_duration(duration_ms);
    if !dur.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(dur, theme.tool_duration()));
    }

    Line::from(spans)
}
