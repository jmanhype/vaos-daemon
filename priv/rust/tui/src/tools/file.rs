use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

// ─── FileViewRenderer (Read) ──────────────────────────────────────────────────

pub struct FileViewRenderer;

impl ToolRenderer for FileViewRenderer {
    #[allow(dead_code)]
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(args, &["path", "file_path", "filename", "target_file"])
            .unwrap_or_else(|| "…".to_string());

        // Collapsed header with path in cyan+underline
        let (icon, icon_style) = super::status_icon(opts.status, opts.spinner_frame);
        let header = Line::from(vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled("Read".to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(
                path.clone(),
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            {
                let dur = super::format_duration(opts.duration_ms);
                if dur.is_empty() {
                    Span::raw("")
                } else {
                    Span::styled(format!("  {}", dur), theme.tool_duration())
                }
            },
        ]);

        if !opts.expanded {
            return vec![header];
        }

        // Expanded body: numbered lines
        let mut body: Vec<Line<'static>> = Vec::new();

        for (idx, line_content) in result.lines().enumerate() {
            let lineno = idx + 1;
            body.push(Line::from(vec![
                Span::styled(
                    format!("{:>4} ", lineno),
                    Style::default().fg(theme.colors.dim),
                ),
                Span::styled("│ ".to_string(), Style::default().fg(theme.colors.border)),
                Span::styled(line_content.to_string(), theme.faint()),
            ]));
        }

        let max_lines = if opts.compact { 6 } else { 10 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── FileWriteRenderer (Write) ────────────────────────────────────────────────

pub struct FileWriteRenderer;

impl ToolRenderer for FileWriteRenderer {
    #[allow(dead_code)]
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(args, &["path", "file_path", "filename", "target_file"])
            .unwrap_or_else(|| "…".to_string());

        let (icon, icon_style) = super::status_icon(opts.status, opts.spinner_frame);
        let header = Line::from(vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled("Write".to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(
                path,
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            {
                let dur = super::format_duration(opts.duration_ms);
                if dur.is_empty() {
                    Span::raw("")
                } else {
                    Span::styled(format!("  {}", dur), theme.tool_duration())
                }
            },
        ]);

        if !opts.expanded {
            return vec![header];
        }

        // Expanded body: diff-add style (green +)
        let diff_add_style = Style::default().fg(theme.colors.success);
        let content = {
            // Prefer content from args if available, fall back to result
            let from_args = parse_json_arg(args, &["content", "text", "body"]);
            from_args.unwrap_or_else(|| result.to_string())
        };

        let mut body: Vec<Line<'static>> = Vec::new();
        for line in content.lines() {
            body.push(Line::from(vec![
                Span::styled("+ ".to_string(), diff_add_style),
                Span::styled(line.to_string(), diff_add_style),
            ]));
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── FileEditRenderer (Edit / MultiEdit / Download) ───────────────────────────

pub struct FileEditRenderer;

impl ToolRenderer for FileEditRenderer {
    #[allow(dead_code)]
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(
            args,
            &["path", "file_path", "filename", "target_file", "file"],
        )
        .unwrap_or_else(|| "…".to_string());

        // Pick display name
        let display_name = match name.to_lowercase().as_str() {
            "download" => "Download",
            "multiedit" | "multi_edit" => "MultiEdit",
            _ => "Edit",
        };

        let (icon, icon_style) = super::status_icon(opts.status, opts.spinner_frame);
        let header = Line::from(vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled(display_name.to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(
                path,
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            {
                let dur = super::format_duration(opts.duration_ms);
                if dur.is_empty() {
                    Span::raw("")
                } else {
                    Span::styled(format!("  {}", dur), theme.tool_duration())
                }
            },
        ]);

        if !opts.expanded {
            return vec![header];
        }

        // Try to render unified diff from old_string / new_string
        let old = parse_json_arg(args, &["old_string", "old", "original", "before"]);
        let new = parse_json_arg(args, &["new_string", "new", "replacement", "after"]);

        let mut body: Vec<Line<'static>> = Vec::new();

        match (old, new) {
            (Some(old_text), Some(new_text)) => {
                body.extend(render_inline_diff(&old_text, &new_text, opts.width, &theme));
            }
            _ => {
                // Fallback: plain result text
                for line in result.lines() {
                    body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
                }
            }
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Simple inline unified diff renderer using the `similar` crate.
/// Produces green `+` / red `-` / muted context lines.
fn render_inline_diff(
    old: &str,
    new: &str,
    _width: u16,
    theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(old, new);
    let mut lines: Vec<Line<'static>> = Vec::new();

    for change in diff.iter_all_changes() {
        let (prefix, style) = match change.tag() {
            ChangeTag::Insert => (
                "+ ",
                Style::default().fg(theme.colors.success),
            ),
            ChangeTag::Delete => (
                "- ",
                Style::default().fg(theme.colors.error),
            ),
            ChangeTag::Equal => (
                "  ",
                Style::default().fg(theme.colors.muted),
            ),
        };
        let content = change.value().trim_end_matches('\n').to_string();
        lines.push(Line::from(vec![
            Span::styled(prefix.to_string(), style),
            Span::styled(content, style),
        ]));
    }

    lines
}
