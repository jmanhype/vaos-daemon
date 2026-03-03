use ratatui::style::Style;
use ratatui::text::{Line, Span};
use similar::{ChangeTag, TextDiff};

/// Render a unified diff between `old_text` and `new_text`.
/// Returns `Vec<Line<'static>>` with coloured +/- lines.
///
/// Format:
///   `@@ -old_start,old_count +new_start,new_count @@`  — cyan italic
///   `+ added line`   — green (theme.colors.success)
///   `- removed line` — red   (theme.colors.error)
///   ` context line`  — muted (theme.colors.muted)
#[allow(dead_code)]
pub fn render_diff(old_text: &str, new_text: &str, _width: u16) -> Vec<Line<'static>> {
    let theme = crate::style::theme();

    let add_style = Style::default().fg(theme.colors.success);
    let del_style = Style::default().fg(theme.colors.error);
    let ctx_style = Style::default().fg(theme.colors.muted);
    let hunk_style = theme.diff_hunk_label();

    let diff = TextDiff::from_lines(old_text, new_text);
    let mut lines: Vec<Line<'static>> = Vec::new();

    for group in diff.grouped_ops(3) {
        // Compute hunk header coordinates from the op group.
        let first = group.first().unwrap();

        let old_start = first.old_range().start + 1; // 1-indexed
        let old_count: usize = group.iter().map(|op| op.old_range().len()).sum();
        let new_start = first.new_range().start + 1;
        let new_count: usize = group.iter().map(|op| op.new_range().len()).sum();

        let hunk_header = format!(
            "@@ -{},{} +{},{} @@",
            old_start, old_count, new_start, new_count
        );
        lines.push(Line::from(Span::styled(hunk_header, hunk_style)));

        for op in &group {
            for change in diff.iter_changes(op) {
                let (prefix, style) = match change.tag() {
                    ChangeTag::Insert => ("+", add_style),
                    ChangeTag::Delete => ("-", del_style),
                    ChangeTag::Equal => (" ", ctx_style),
                };

                // Strip the trailing newline that similar includes.
                let value = change.value().trim_end_matches('\n').to_owned();
                let content = format!("{}{}", prefix, value);

                lines.push(Line::from(Span::styled(content, style)));
            }
        }
    }

    // If there are no hunks (texts are identical), emit a brief notice.
    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "(no differences)".to_owned(),
            ctx_style,
        )));
    }

    lines
}
