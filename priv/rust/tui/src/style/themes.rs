use ratatui::style::Color;

use super::{Theme, ThemeColors};

fn hex(s: &str) -> Color {
    let s = s.trim_start_matches('#');
    let r = u8::from_str_radix(&s[0..2], 16).unwrap();
    let g = u8::from_str_radix(&s[2..4], 16).unwrap();
    let b = u8::from_str_radix(&s[4..6], 16).unwrap();
    Color::Rgb(r, g, b)
}

pub fn dark() -> Theme {
    Theme {
        name: "dark".to_string(),
        colors: ThemeColors {
            primary: hex("#E5E7EB"),
            secondary: hex("#06B6D4"),
            success: hex("#22C55E"),
            warning: hex("#F59E0B"),
            error: hex("#EF4444"),
            muted: hex("#6B7280"),
            dim: hex("#374151"),
            border: hex("#4B5563"),
            msg_border_user: hex("#06B6D4"),
            msg_border_agent: hex("#E5E7EB"),
            msg_border_system: hex("#374151"),
            msg_border_warning: hex("#F59E0B"),
            msg_border_error: hex("#EF4444"),
            sidebar_bg: hex("#1F2937"),
            modal_bg: hex("#111827"),
            tooltip_bg: hex("#1F2937"),
            input_bg: hex("#111827"),
            selection_bg: hex("#374151"),
            dialog_bg: hex("#1F2937"),
            button_active_bg: hex("#E5E7EB"),
            button_active_text: hex("#111827"),
            grad_a: hex("#E5E7EB"),
            grad_b: hex("#06B6D4"),
        },
    }
}

pub fn light() -> Theme {
    Theme {
        name: "light".to_string(),
        colors: ThemeColors {
            primary: hex("#6D28D9"),
            secondary: hex("#0891B2"),
            success: hex("#16A34A"),
            warning: hex("#D97706"),
            error: hex("#DC2626"),
            muted: hex("#9CA3AF"),
            dim: hex("#D1D5DB"),
            border: hex("#9CA3AF"),
            msg_border_user: hex("#0891B2"),
            msg_border_agent: hex("#6D28D9"),
            msg_border_system: hex("#D1D5DB"),
            msg_border_warning: hex("#D97706"),
            msg_border_error: hex("#DC2626"),
            sidebar_bg: hex("#F3F4F6"),
            modal_bg: hex("#FFFFFF"),
            tooltip_bg: hex("#F3F4F6"),
            input_bg: hex("#FFFFFF"),
            selection_bg: hex("#C4B5FD"),
            dialog_bg: hex("#F3F4F6"),
            button_active_bg: hex("#6D28D9"),
            button_active_text: hex("#FFFFFF"),
            grad_a: hex("#6D28D9"),
            grad_b: hex("#0891B2"),
        },
    }
}

pub fn catppuccin() -> Theme {
    Theme {
        name: "catppuccin".to_string(),
        colors: ThemeColors {
            primary: hex("#CBA6F7"),
            secondary: hex("#89DCEB"),
            success: hex("#A6E3A1"),
            warning: hex("#F9E2AF"),
            error: hex("#F38BA8"),
            muted: hex("#6C7086"),
            dim: hex("#45475A"),
            border: hex("#6C7086"),
            msg_border_user: hex("#89DCEB"),
            msg_border_agent: hex("#CBA6F7"),
            msg_border_system: hex("#45475A"),
            msg_border_warning: hex("#F9E2AF"),
            msg_border_error: hex("#F38BA8"),
            sidebar_bg: hex("#1E1E2E"),
            modal_bg: hex("#181825"),
            tooltip_bg: hex("#1E1E2E"),
            input_bg: hex("#181825"),
            selection_bg: hex("#45475A"),
            dialog_bg: hex("#1E1E2E"),
            button_active_bg: hex("#CBA6F7"),
            button_active_text: hex("#1E1E2E"),
            grad_a: hex("#CBA6F7"),
            grad_b: hex("#89DCEB"),
        },
    }
}

pub fn tokyo_night() -> Theme {
    Theme {
        name: "tokyo-night".to_string(),
        colors: ThemeColors {
            primary: hex("#7AA2F7"),
            secondary: hex("#7DCFFF"),
            success: hex("#9ECE6A"),
            warning: hex("#E0AF68"),
            error: hex("#F7768E"),
            muted: hex("#565F89"),
            dim: hex("#3B4261"),
            border: hex("#565F89"),
            msg_border_user: hex("#7DCFFF"),
            msg_border_agent: hex("#7AA2F7"),
            msg_border_system: hex("#3B4261"),
            msg_border_warning: hex("#E0AF68"),
            msg_border_error: hex("#F7768E"),
            sidebar_bg: hex("#1A1B26"),
            modal_bg: hex("#16161E"),
            tooltip_bg: hex("#1A1B26"),
            input_bg: hex("#16161E"),
            selection_bg: hex("#283457"),
            dialog_bg: hex("#1A1B26"),
            button_active_bg: hex("#7AA2F7"),
            button_active_text: hex("#1A1B26"),
            grad_a: hex("#7AA2F7"),
            grad_b: hex("#7DCFFF"),
        },
    }
}

/// Get theme by name
pub fn by_name(name: &str) -> Option<Theme> {
    match name {
        "dark" => Some(dark()),
        "light" => Some(light()),
        "catppuccin" => Some(catppuccin()),
        "tokyo-night" => Some(tokyo_night()),
        _ => None,
    }
}

/// List all available theme names
pub fn available() -> Vec<&'static str> {
    vec!["dark", "light", "catppuccin", "tokyo-night"]
}
