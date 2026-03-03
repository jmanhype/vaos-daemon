use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::style;

/// Block-letter ASCII art logo
const LOGO_ART: &[&str] = &[
    " \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} ",
    "\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}",
    "\u{255a}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}  \u{2588}\u{2588}\u{2551}",
    " \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}  \u{255a}\u{2550}\u{255d}",
    "        a g e n t  \u{25c8}",
];

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

    // Block-letter logo with gradient
    for art_line in LOGO_ART {
        lines.push(style::gradient::theme_gradient(art_line, true));
    }

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
