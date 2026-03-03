use ratatui::prelude::*;

use crate::app::layout::Layout;

/// Computed sub-areas from the layout for the main screen
pub struct LayoutAreas {
    pub header: Rect,
    pub chat: Rect,
    pub sidebar: Option<Rect>,
    pub tasks: Option<Rect>,
    pub agents: Option<Rect>,
    pub status: Rect,
    pub input: Rect,
    pub toast: Rect,
}

impl LayoutAreas {
    pub fn compute(area: Rect, layout: &Layout, task_lines: u16, agent_lines: u16) -> Self {
        let mut y = area.y;

        // Header (2 lines: header + separator)
        let header = Rect::new(area.x, y, area.width, layout.header_height.min(area.height));
        y += layout.header_height;

        // Compute fixed bottom sections first, give remainder to chat
        let bottom_height = task_lines + agent_lines + layout.status_height + layout.input_height;
        let main_height = area
            .height
            .saturating_sub(layout.header_height + bottom_height)
            .max(5); // min 5 lines for chat

        let (sidebar, chat) = if layout.sidebar_width > 0 {
            let sb = Rect::new(area.x, y, layout.sidebar_width, main_height);
            let ch = Rect::new(
                area.x + layout.sidebar_width,
                y,
                layout.chat_width,
                main_height,
            );
            (Some(sb), ch)
        } else {
            let ch = Rect::new(area.x, y, layout.chat_width, main_height);
            (None, ch)
        };
        y += main_height;

        // Tasks
        let tasks = if task_lines > 0 {
            let r = Rect::new(area.x, y, area.width, task_lines);
            y += task_lines;
            Some(r)
        } else {
            None
        };

        // Agents
        let agents = if agent_lines > 0 {
            let r = Rect::new(area.x, y, area.width, agent_lines);
            y += agent_lines;
            Some(r)
        } else {
            None
        };

        // Status bar
        let status = Rect::new(area.x, y, area.width, layout.status_height);
        y += layout.status_height;

        // Input (separator + prompt) — pinned height, no excess
        let input = Rect::new(area.x, y, area.width, layout.input_height);

        // Toast overlay (top-right corner)
        let toast = Rect::new(
            area.x + area.width.saturating_sub(40),
            area.y + 1,
            40.min(area.width),
            3,
        );

        Self {
            header,
            chat,
            sidebar,
            tasks,
            agents,
            status,
            input,
            toast,
        }
    }
}
