use ratatui::prelude::*;
use ratatui::widgets::{Clear, Paragraph};

use crate::style;

/// Block-letter ASCII art logo (same as welcome)
const LOGO_ART: &[&str] = &[
    " \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} ",
    "\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}",
    "\u{255a}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}  \u{2588}\u{2588}\u{2551}",
    " \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}  \u{255a}\u{2550}\u{255d}",
    "        a g e n t  \u{25c8}",
];

pub fn draw_connecting(frame: &mut Frame, area: Rect) {
    let theme = style::theme();

    // Fill background
    frame.render_widget(Clear, area);

    // Content: logo + blank + spinner
    let content_height = (LOGO_ART.len() + 3) as u16; // logo + blank + spinner + blank
    let y_offset = area.height.saturating_sub(content_height) / 2;

    let mut lines: Vec<Line<'static>> = Vec::new();

    // Block-letter logo with gradient
    for art_line in LOGO_ART {
        lines.push(style::gradient::theme_gradient(art_line, true));
    }

    lines.push(Line::from(""));

    // Spinner + status
    let dots = match (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        / 400)
        % 4
    {
        0 => "   ",
        1 => ".  ",
        2 => ".. ",
        _ => "...",
    };

    lines.push(Line::from(vec![
        Span::styled("\u{25ce} ", Style::default().fg(theme.colors.primary)),
        Span::styled("Connecting", Style::default().fg(theme.colors.muted)),
        Span::styled(dots, Style::default().fg(theme.colors.dim)),
    ]));

    let content_area = Rect::new(
        area.x,
        area.y + y_offset,
        area.width,
        content_height.min(area.height),
    );

    let text = Text::from(lines);
    let paragraph = Paragraph::new(text).alignment(Alignment::Center);
    frame.render_widget(paragraph, content_area);
}
