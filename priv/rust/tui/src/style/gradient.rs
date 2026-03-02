use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

/// Linear interpolation between two RGB colors
pub fn lerp_color(a: Color, b: Color, t: f64) -> Color {
    let t = t.clamp(0.0, 1.0);
    match (a, b) {
        (Color::Rgb(r1, g1, b1), Color::Rgb(r2, g2, b2)) => {
            let r = (r1 as f64 + (r2 as f64 - r1 as f64) * t) as u8;
            let g = (g1 as f64 + (g2 as f64 - g1 as f64) * t) as u8;
            let b = (b1 as f64 + (b2 as f64 - b1 as f64) * t) as u8;
            Color::Rgb(r, g, b)
        }
        _ => {
            if t < 0.5 {
                a
            } else {
                b
            }
        }
    }
}

/// Render text with per-character gradient
pub fn gradient_line(text: &str, from: Color, to: Color, bold: bool) -> Line<'static> {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len().max(1);

    let spans: Vec<Span<'static>> = chars
        .into_iter()
        .enumerate()
        .map(|(i, ch)| {
            let t = if len > 1 {
                i as f64 / (len - 1) as f64
            } else {
                0.0
            };
            let color = lerp_color(from, to, t);
            let mut style = Style::default().fg(color);
            if bold {
                style = style.add_modifier(Modifier::BOLD);
            }
            Span::styled(ch.to_string(), style)
        })
        .collect();

    Line::from(spans)
}

/// Apply theme gradient using the current theme's grad_a and grad_b colors
pub fn theme_gradient(text: &str, bold: bool) -> Line<'static> {
    let theme = super::theme();
    gradient_line(text, theme.colors.grad_a, theme.colors.grad_b, bold)
}
