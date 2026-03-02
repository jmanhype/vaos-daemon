use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::style;

/// Braille-art diamond/circuit symbol (OSA identity)
const LOGO_ART: &[&str] = &[
    "          \u{2800}\u{2840}\u{2844}\u{2846}\u{2847}\u{2847}\u{2847}\u{2847}\u{2846}\u{2844}\u{2840}\u{2800}          ",
    "        \u{2840}\u{2847}\u{281b}\u{2800}\u{2800}\u{2800}\u{2800}\u{2800}\u{2800}\u{281b}\u{2847}\u{2840}        ",
    "      \u{2844}\u{281b}\u{2800}\u{2800}\u{2800}\u{28c0}\u{28e4}\u{28c0}\u{2800}\u{2800}\u{2800}\u{281b}\u{2844}      ",
    "    \u{2846}\u{2800}\u{2800}\u{2800}\u{28c0}\u{28f6}\u{28ff}\u{28ff}\u{28f6}\u{28c0}\u{2800}\u{2800}\u{2800}\u{2846}    ",
    "    \u{2847}\u{2800}\u{2800}\u{28e0}\u{28ff}\u{28ff}\u{28ff}\u{28ff}\u{28ff}\u{28ff}\u{28e0}\u{2800}\u{2800}\u{2847}    ",
    "    \u{2846}\u{2800}\u{2800}\u{2800}\u{2819}\u{283b}\u{28ff}\u{28ff}\u{283b}\u{2819}\u{2800}\u{2800}\u{2800}\u{2846}    ",
    "      \u{2843}\u{2819}\u{2800}\u{2800}\u{2800}\u{2819}\u{283b}\u{2819}\u{2800}\u{2800}\u{2800}\u{2819}\u{2843}      ",
    "        \u{2819}\u{2846}\u{2819}\u{2800}\u{2800}\u{2800}\u{2800}\u{2800}\u{2800}\u{2819}\u{2846}\u{2819}        ",
    "          \u{2800}\u{2819}\u{2843}\u{2843}\u{2846}\u{2846}\u{2846}\u{2846}\u{2843}\u{2843}\u{2819}\u{2800}          ",
];

pub fn draw_welcome(frame: &mut Frame, area: Rect) {
    draw_welcome_with_tools(frame, area, 0, None, None);
}

pub fn draw_welcome_with_tools(
    frame: &mut Frame,
    area: Rect,
    tool_count: usize,
    provider: Option<&str>,
    model: Option<&str>,
) {
    let theme = style::theme();

    let version = env!("CARGO_PKG_VERSION");

    let cwd = std::env::current_dir()
        .map(|p| {
            let s = p.display().to_string();
            if s.len() > 60 {
                format!("...{}", &s[s.len() - 57..])
            } else {
                s
            }
        })
        .unwrap_or_default();

    // Build the display lines
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Braille art logo with gradient
    for art_line in LOGO_ART {
        lines.push(style::gradient::theme_gradient(art_line, true));
    }

    lines.push(Line::from(""));

    // Box-drawing text logo
    lines.push(style::gradient::theme_gradient(
        "  \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557} \u{2554}\u{2550}\u{2550}\u{2550}\u{2557}  ",
        true,
    ));
    lines.push(style::gradient::theme_gradient(
        "  \u{2551}   \u{2551} \u{2551}     \u{2551}   \u{2551}  ",
        true,
    ));
    lines.push(style::gradient::theme_gradient(
        "  \u{2551}   \u{2551}  \u{2550}\u{2550}\u{2550}\u{2557} \u{2560}\u{2550}\u{2550}\u{2550}\u{2563}  ",
        true,
    ));
    lines.push(style::gradient::theme_gradient(
        "  \u{2551}   \u{2551}     \u{2551} \u{2551}   \u{2551}  ",
        true,
    ));
    lines.push(style::gradient::theme_gradient(
        "  \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{255d} \u{2551}   \u{2551}  ",
        true,
    ));

    lines.push(Line::from(""));

    // Title + version
    lines.push(Line::from(vec![
        Span::styled("\u{25c8} ", theme.welcome_title()),
        Span::styled("OSA Agent  ", theme.welcome_title()),
        Span::styled(format!("v{}", version), theme.welcome_meta()),
    ]));
    lines.push(Line::from(Span::styled(
        "Your OS, Supercharged",
        theme.welcome_meta(),
    )));

    lines.push(Line::from(""));

    // Provider/model info (Hermes-inspired inventory)
    if let (Some(prov), Some(mdl)) = (provider, model) {
        lines.push(Line::from(vec![
            Span::styled("\u{25b8} ", theme.faint()),
            Span::styled(format!("{}", prov), theme.header_provider()),
            Span::styled(" / ", theme.faint()),
            Span::styled(format!("{}", mdl), theme.header_model()),
            if tool_count > 0 {
                Span::styled(
                    format!("  \u{00b7}  {} tools", tool_count),
                    theme.faint(),
                )
            } else {
                Span::raw("")
            },
        ]));
    } else if tool_count > 0 {
        lines.push(Line::from(Span::styled(
            format!("{} tools loaded", tool_count),
            theme.faint(),
        )));
    }

    // Working directory
    lines.push(Line::from(Span::styled(cwd, theme.welcome_cwd())));

    lines.push(Line::from(""));

    // Help tips
    lines.push(Line::from(Span::styled(
        "Type a message to get started  \u{00b7}  /help for commands  \u{00b7}  Ctrl+K for palette",
        theme.welcome_tip(),
    )));

    let content_height = lines.len() as u16;
    let y_offset = area.height.saturating_sub(content_height) / 2;
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
