use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::style;

pub fn draw_connecting(frame: &mut Frame, area: Rect) {
    let theme = style::theme();

    // Fill background
    frame.render_widget(Clear, area);
    let bg = Block::default().style(Style::default().bg(theme.colors.dialog_bg));
    frame.render_widget(bg, area);

    // Centered card: 40w x 9h
    let card_w: u16 = 40;
    let card_h: u16 = 9;
    let x = area.x + area.width.saturating_sub(card_w) / 2;
    let y = area.y + area.height.saturating_sub(card_h) / 2;
    let card = Rect::new(x, y, card_w.min(area.width), card_h.min(area.height));

    // Card border
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(theme.colors.primary))
        .style(Style::default().bg(theme.colors.dialog_bg));
    frame.render_widget(block, card);

    let inner = Rect::new(
        card.x + 2,
        card.y + 1,
        card.width.saturating_sub(4),
        card.height.saturating_sub(2),
    );
    if inner.height < 5 {
        return;
    }

    let mut cy = inner.y;

    // Blank
    cy += 1;

    // Clean text logo
    let title = Line::from(vec![
        Span::styled("◈ ", Style::default().fg(theme.colors.secondary)),
        Span::styled("OSA", Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD)),
        Span::styled(" Agent", Style::default().fg(theme.colors.secondary).add_modifier(Modifier::BOLD)),
    ]);
    frame.render_widget(
        Paragraph::new(title).alignment(Alignment::Center),
        Rect::new(inner.x, cy, inner.width, 1),
    );
    cy += 1;

    // Tagline
    let tagline = Line::from(Span::styled(
        "Your OS, Supercharged",
        Style::default().fg(theme.colors.muted),
    ));
    frame.render_widget(
        Paragraph::new(tagline).alignment(Alignment::Center),
        Rect::new(inner.x, cy, inner.width, 1),
    );
    cy += 2;

    // Spinner + status
    if cy < inner.y + inner.height {
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

        let status = Line::from(vec![
            Span::styled("◎ ", Style::default().fg(theme.colors.primary)),
            Span::styled("Connecting", Style::default().fg(theme.colors.muted)),
            Span::styled(dots, Style::default().fg(theme.colors.dim)),
        ]);
        frame.render_widget(
            Paragraph::new(status).alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
    }
}
