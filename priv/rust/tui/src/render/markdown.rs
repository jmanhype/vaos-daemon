use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span, Text};

/// Convert a Markdown string to a ratatui [`Text`] value.
///
/// Supported constructs:
///   - Headers  `# H1`, `## H2`, `### H3`  — bold, primary color
///   - Fenced code blocks  ` ``` [lang] ` … ` ``` ` — syntax-highlighted via [`crate::render::syntax`]
///   - Inline code `` `expr` `` — dim style
///   - **Bold**  `**text**`
///   - *Italic*  `*text*`
///   - Unordered lists  `- item` / `* item`
///   - Ordered lists    `1. item`
///   - Links  `[text](url)` — text in cyan+underline, URL dropped
///   - Blockquotes  `> text` — muted italic with `│ ` prefix
///   - Horizontal rules  `---` / `***` — full-width `─`
///   - Plain text — unstyled
#[allow(dead_code)]
pub fn render_markdown(input: &str, width: u16) -> Text<'static> {
    let theme = crate::style::theme();
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Code-block accumulator state.
    let mut in_code_block = false;
    let mut code_lang = String::new();
    let mut code_lines: Vec<String> = Vec::new();

    for raw_line in input.lines() {
        // ── Fenced code block boundary ──────────────────────────────────────
        if raw_line.trim_start().starts_with("```") {
            if in_code_block {
                // Closing fence: flush accumulated code.
                in_code_block = false;
                let code = code_lines.join("\n");
                let highlighted = crate::render::syntax::highlight(&code, &code_lang);
                lines.extend(highlighted);
                code_lang.clear();
                code_lines.clear();
            } else {
                // Opening fence: extract optional language tag.
                in_code_block = true;
                let rest = raw_line.trim_start().trim_start_matches('`').trim();
                code_lang = rest.to_owned();
            }
            continue;
        }

        if in_code_block {
            code_lines.push(raw_line.to_owned());
            continue;
        }

        // ── Headers ─────────────────────────────────────────────────────────
        if raw_line.starts_with("### ") {
            let text = raw_line[4..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            lines.push(Line::from(Span::styled(text, style)));
            continue;
        }
        if raw_line.starts_with("## ") {
            let text = raw_line[3..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            lines.push(Line::from(Span::styled(text, style)));
            lines.push(Line::from(Span::raw(""))); // breathing room after h2
            continue;
        }
        if raw_line.starts_with("# ") {
            let text = raw_line[2..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
            lines.push(Line::from(Span::styled(text, style)));
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Horizontal rules ─────────────────────────────────────────────────
        let trimmed = raw_line.trim();
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            let rule = "─".repeat(width.saturating_sub(2) as usize);
            lines.push(Line::from(Span::styled(rule, theme.faint())));
            continue;
        }

        // ── Blockquotes ───────────────────────────────────────────────────────
        if raw_line.starts_with("> ") {
            let content = raw_line[2..].to_owned();
            let style = Style::default()
                .fg(theme.colors.muted)
                .add_modifier(Modifier::ITALIC);
            let border = Span::styled("│ ".to_owned(), Style::default().fg(theme.colors.dim));
            let text_span = Span::styled(content, style);
            lines.push(Line::from(vec![border, text_span]));
            continue;
        }

        // ── Unordered lists ───────────────────────────────────────────────────
        if raw_line.starts_with("- ") || raw_line.starts_with("* ") {
            let content = &raw_line[2..];
            let bullet = Span::styled("• ".to_owned(), Style::default().fg(theme.colors.muted));
            let mut spans = vec![bullet];
            spans.extend(parse_inline(content, &theme));
            lines.push(Line::from(spans));
            continue;
        }

        // ── Ordered lists ─────────────────────────────────────────────────────
        if let Some(rest) = strip_ordered_prefix(raw_line) {
            // Find the period to extract the number label.
            let dot = raw_line.find('.').unwrap_or(1);
            let num_str = format!("{}. ", &raw_line[..dot]);
            let num_span = Span::styled(num_str, Style::default().fg(theme.colors.muted));
            let mut spans = vec![num_span];
            spans.extend(parse_inline(rest, &theme));
            lines.push(Line::from(spans));
            continue;
        }

        // ── Empty lines ───────────────────────────────────────────────────────
        if raw_line.trim().is_empty() {
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Plain paragraph / inline formatting ───────────────────────────────
        let spans = parse_inline(raw_line, &theme);
        lines.push(Line::from(spans));
    }

    // If we hit EOF still inside a code block, flush what we have.
    if in_code_block && !code_lines.is_empty() {
        let code = code_lines.join("\n");
        let highlighted = crate::render::syntax::highlight(&code, &code_lang);
        lines.extend(highlighted);
    }

    Text::from(lines)
}

// ─── Ordered-list prefix detector ────────────────────────────────────────────

/// Returns `Some(rest)` when `line` starts with `<digits>. `, else `None`.
fn strip_ordered_prefix(line: &str) -> Option<&str> {
    let mut chars = line.char_indices().peekable();
    let mut digit_count = 0;
    while let Some((_, ch)) = chars.peek() {
        if ch.is_ascii_digit() {
            digit_count += 1;
            chars.next();
        } else {
            break;
        }
    }
    if digit_count == 0 {
        return None;
    }
    // Expect ". "
    if let Some((idx, '.')) = chars.next() {
        if let Some((_, ' ')) = chars.next() {
            return Some(&line[idx + 2..]);
        }
    }
    None
}

// ─── Inline span parser ───────────────────────────────────────────────────────

/// Walk `input` character-by-character, emitting styled [`Span`]s for inline
/// Markdown constructs: `` `code` ``, `**bold**`, `*italic*`, `[text](url)`.
/// Everything else is emitted as unstyled text.
fn parse_inline(input: &str, theme: &crate::style::Theme) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut chars = input.chars().peekable();
    let mut plain = String::new();

    // Helper to flush the accumulated plain buffer.
    macro_rules! flush_plain {
        () => {
            if !plain.is_empty() {
                spans.push(Span::raw(plain.clone()));
                plain.clear();
            }
        };
    }

    while let Some(&ch) = chars.peek() {
        match ch {
            // ── Inline code: `...` ────────────────────────────────────────
            '`' => {
                chars.next(); // consume opening backtick
                let mut code = String::new();
                for c in chars.by_ref() {
                    if c == '`' {
                        break;
                    }
                    code.push(c);
                }
                if !code.is_empty() {
                    flush_plain!();
                    let style = Style::default().fg(theme.colors.muted);
                    spans.push(Span::styled(code, style));
                } else {
                    // Lone backtick — treat as literal.
                    plain.push('`');
                }
            }

            // ── Bold / Italic: ** or * ────────────────────────────────────
            '*' => {
                chars.next(); // consume first `*`
                if chars.peek() == Some(&'*') {
                    // Possible **bold**
                    chars.next(); // consume second `*`
                    let mut content = String::new();
                    let mut closed = false;
                    // Collect until closing `**`. Use `while let` so that the
                    // mutable borrow from `.next()` is released between
                    // iterations, allowing `.peek()` on the next iteration.
                    while let Some(&nc) = chars.peek() {
                        if nc == '*' {
                            chars.next(); // consume this `*`
                            // Check the character after it.
                            if chars.peek() == Some(&'*') {
                                chars.next(); // consume second closing `*`
                                closed = true;
                                break;
                            }
                            // Single `*` inside bold — treat as literal.
                            content.push('*');
                        } else {
                            chars.next();
                            content.push(nc);
                        }
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        let style = Style::default().add_modifier(Modifier::BOLD);
                        spans.push(Span::styled(content, style));
                    } else {
                        // Not a valid bold span — emit literally.
                        plain.push_str("**");
                        plain.push_str(&content);
                    }
                } else {
                    // Possible *italic*
                    let mut content = String::new();
                    let mut closed = false;
                    for c in chars.by_ref() {
                        if c == '*' {
                            closed = true;
                            break;
                        }
                        content.push(c);
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        let style = Style::default().add_modifier(Modifier::ITALIC);
                        spans.push(Span::styled(content, style));
                    } else {
                        plain.push('*');
                        plain.push_str(&content);
                    }
                }
            }

            // ── Links: [text](url) ────────────────────────────────────────
            '[' => {
                chars.next(); // consume `[`
                let mut link_text = String::new();
                let mut found_bracket = false;
                for c in chars.by_ref() {
                    if c == ']' {
                        found_bracket = true;
                        break;
                    }
                    link_text.push(c);
                }
                // Check for `(url)` following the `]`.
                if found_bracket && chars.peek() == Some(&'(') {
                    chars.next(); // consume `(`
                    let mut _url = String::new();
                    for c in chars.by_ref() {
                        if c == ')' {
                            break;
                        }
                        _url.push(c);
                    }
                    // Emit the link text in cyan+underline; drop the URL.
                    if !link_text.is_empty() {
                        flush_plain!();
                        let style = Style::default()
                            .fg(theme.colors.secondary)
                            .add_modifier(Modifier::UNDERLINED);
                        spans.push(Span::styled(link_text, style));
                    }
                } else {
                    // Not a valid link — emit literally.
                    plain.push('[');
                    plain.push_str(&link_text);
                    if found_bracket {
                        plain.push(']');
                    }
                }
            }

            // ── Everything else ───────────────────────────────────────────
            other => {
                chars.next();
                plain.push(other);
            }
        }
    }

    flush_plain!();
    spans
}
