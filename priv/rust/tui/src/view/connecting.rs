use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::style;

pub fn draw_connecting(frame: &mut Frame, area: Rect) {
    let theme = style::theme();

    // Center the content vertically
    let content_height = 8u16;
    let y_offset = area.height.saturating_sub(content_height) / 2;
    let content_area = Rect::new(
        area.x,
        area.y + y_offset,
        area.width,
        content_height.min(area.height),
    );

    let lines = vec![
        style::gradient::theme_gradient("  \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557}  ", true),
        style::gradient::theme_gradient("  \u{2551}   \u{2551} \u{2551}     \u{2551}   \u{2551}  ", true),
        style::gradient::theme_gradient("  \u{2551}   \u{2551}  \u{2550}\u{2550}\u{2550}\u{2557} \u{2560}\u{2550}\u{2550}\u{2550}\u{2563}  ", true),
        style::gradient::theme_gradient("  \u{2551}   \u{2551}     \u{2551} \u{2551}   \u{2551}  ", true),
        style::gradient::theme_gradient("  \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{2551}   \u{2551}  ", true),
        Line::from(""),
        Line::from(Span::styled(
            "Connecting to OSA backend...",
            theme.faint(),
        )),
    ];

    let text = Text::from(lines);
    let paragraph = Paragraph::new(text).alignment(Alignment::Center);
    frame.render_widget(paragraph, content_area);
}
