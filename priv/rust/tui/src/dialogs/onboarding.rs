/// 8-step onboarding wizard dialog.
///
/// # Actions to add to `DialogAction` in mod.rs:
/// ```
/// OnboardingComplete(onboarding::OnboardingResult),
/// OnboardingCancel,
/// ```
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::client::types::{
    OnboardingChannel, OnboardingMachine, OnboardingProvider, OnboardingTemplate,
};

const DIALOG_W: u16 = 64;
const DIALOG_H: u16 = 28;

const STEP_LABELS: &[&str] = &[
    "1 Name",
    "2 Profile",
    "3 Template",
    "4 Provider",
    "5 API Key",
    "6 Machines",
    "7 Channels",
    "8 Confirm",
];

const TOTAL_STEPS: usize = 8;

// ── Result ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct OnboardingResult {
    pub provider: String,
    pub model: String,
    pub api_key: Option<String>,
    pub env_var: Option<String>,
    pub agent_name: String,
    pub user_name: Option<String>,
    pub user_context: Option<String>,
    pub machines: Vec<String>,
    pub channels: Vec<String>,
}

// ── Action ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum OnboardingAction {
    Complete(OnboardingResult),
    Cancel,
}

// ── Data ──────────────────────────────────────────────────────────────────────

pub struct OnboardingData {
    pub providers: Vec<OnboardingProvider>,
    pub templates: Vec<OnboardingTemplate>,
    pub machines: Vec<OnboardingMachine>,
    pub channels: Vec<OnboardingChannel>,
    pub system_info: std::collections::HashMap<String, serde_json::Value>,
}

// ── Which field is focused on a multi-field step ─────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProfileField {
    Name,
    Context,
}

// ── State ────────────────────────────────────────────────────────────────────

pub struct OnboardingWizard {
    step: usize,
    data: OnboardingData,

    // Step 0 — Name
    agent_name: String,

    // Step 1 — Profile
    user_name: String,
    user_context: String,
    profile_field: ProfileField,

    // Step 2 — Template
    selected_template: usize,

    // Step 3 — Provider
    selected_provider: usize,

    // Step 4 — API Key
    api_key: String,
    api_key_masked: bool,

    // Step 5 — Machines
    selected_machines: Vec<bool>,

    // Step 6 — Channels
    selected_channels: Vec<bool>,

    // Step 7 — Confirm
    confirm_selected: usize, // 0 = Confirm, 1 = Back
}

impl OnboardingWizard {
    pub fn new(data: OnboardingData) -> Self {
        let machine_count = data.machines.len();
        let channel_count = data.channels.len();
        Self {
            step: 0,
            data,
            agent_name: "OSA Agent".to_string(),
            user_name: String::new(),
            user_context: String::new(),
            profile_field: ProfileField::Name,
            selected_template: 0,
            selected_provider: 0,
            api_key: String::new(),
            api_key_masked: true,
            selected_machines: vec![false; machine_count],
            selected_channels: vec![false; channel_count],
            confirm_selected: 0,
        }
    }

    // ── Step skip logic ───────────────────────────────────────────────────────

    /// Whether step 4 (API key) should be skipped.
    fn skip_api_key(&self) -> bool {
        self.data
            .providers
            .get(self.selected_provider)
            .map(|p| p.env_var.is_empty())
            .unwrap_or(true)
    }

    fn advance(&mut self) -> Option<OnboardingAction> {
        let mut next = self.step + 1;
        // Skip API key step when provider has no env_var
        if next == 4 && self.skip_api_key() {
            next = 5;
        }
        if next >= TOTAL_STEPS {
            return self.build_result().map(OnboardingAction::Complete);
        }
        self.step = next;
        None
    }

    fn retreat(&mut self) -> Option<OnboardingAction> {
        if self.step == 0 {
            return Some(OnboardingAction::Cancel);
        }
        let mut prev = self.step - 1;
        if prev == 4 && self.skip_api_key() {
            if prev == 0 {
                return Some(OnboardingAction::Cancel);
            }
            prev = prev.saturating_sub(1);
        }
        self.step = prev;
        None
    }

    fn build_result(&self) -> Option<OnboardingResult> {
        let provider = self.data.providers.get(self.selected_provider)?;
        let machines: Vec<String> = self
            .data
            .machines
            .iter()
            .enumerate()
            .filter(|(i, _)| self.selected_machines.get(*i).copied().unwrap_or(false))
            .map(|(_, m)| m.key.clone())
            .collect();
        let channels: Vec<String> = self
            .data
            .channels
            .iter()
            .enumerate()
            .filter(|(i, _)| self.selected_channels.get(*i).copied().unwrap_or(false))
            .map(|(_, c)| c.key.clone())
            .collect();

        Some(OnboardingResult {
            provider: provider.key.clone(),
            model: provider.default_model.clone(),
            api_key: if self.api_key.is_empty() {
                None
            } else {
                Some(self.api_key.clone())
            },
            env_var: if provider.env_var.is_empty() {
                None
            } else {
                Some(provider.env_var.clone())
            },
            agent_name: self.agent_name.trim().to_string(),
            user_name: if self.user_name.trim().is_empty() {
                None
            } else {
                Some(self.user_name.trim().to_string())
            },
            user_context: if self.user_context.trim().is_empty() {
                None
            } else {
                Some(self.user_context.trim().to_string())
            },
            machines,
            channels,
        })
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match self.step {
            0 => self.handle_step_name(key),
            1 => self.handle_step_profile(key),
            2 => self.handle_step_template(key),
            3 => self.handle_step_provider(key),
            4 => self.handle_step_api_key(key),
            5 => self.handle_step_machines(key),
            6 => self.handle_step_channels(key),
            7 => self.handle_step_confirm(key),
            _ => None,
        }
    }

    fn handle_step_name(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => Some(OnboardingAction::Cancel),
            KeyCode::Backspace => {
                self.agent_name.pop();
                None
            }
            KeyCode::Char(c) => {
                self.agent_name.push(c);
                None
            }
            _ => None,
        }
    }

    fn handle_step_profile(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Tab | KeyCode::BackTab => {
                self.profile_field = match self.profile_field {
                    ProfileField::Name => ProfileField::Context,
                    ProfileField::Context => ProfileField::Name,
                };
                None
            }
            KeyCode::Backspace => {
                match self.profile_field {
                    ProfileField::Name => {
                        self.user_name.pop();
                    }
                    ProfileField::Context => {
                        self.user_context.pop();
                    }
                }
                None
            }
            KeyCode::Char(c) => {
                match self.profile_field {
                    ProfileField::Name => self.user_name.push(c),
                    ProfileField::Context => self.user_context.push(c),
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_template(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        let count = self.data.templates.len() + 1; // +1 for Blank
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Up | KeyCode::Char('k') => {
                self.selected_template =
                    self.selected_template.checked_sub(1).unwrap_or(count - 1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.selected_template = (self.selected_template + 1) % count;
                None
            }
            _ => None,
        }
    }

    fn handle_step_provider(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        let count = self.data.providers.len();
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Up | KeyCode::Char('k') => {
                if count > 0 {
                    self.selected_provider =
                        self.selected_provider.checked_sub(1).unwrap_or(count - 1);
                }
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if count > 0 {
                    self.selected_provider = (self.selected_provider + 1) % count;
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_api_key(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Tab => {
                self.api_key_masked = !self.api_key_masked;
                None
            }
            KeyCode::Backspace => {
                self.api_key.pop();
                None
            }
            KeyCode::Char(c) => {
                self.api_key.push(c);
                None
            }
            _ => None,
        }
    }

    fn handle_step_machines(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        let count = self.selected_machines.len();
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                // is_ascii_digit() guarantees to_digit(10) returns Some; 0 is a safe fallback.
                let n = c.to_digit(10).unwrap_or(0) as usize;
                let idx = if n == 0 { 9 } else { n - 1 };
                if idx < count {
                    self.selected_machines[idx] = !self.selected_machines[idx];
                }
                None
            }
            KeyCode::Char(' ') => {
                // Toggle current (first available)
                if count > 0 {
                    self.selected_machines[0] = !self.selected_machines[0];
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_channels(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        let count = self.selected_channels.len();
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                // is_ascii_digit() guarantees to_digit(10) returns Some; 0 is a safe fallback.
                let n = c.to_digit(10).unwrap_or(0) as usize;
                let idx = if n == 0 { 9 } else { n - 1 };
                if idx < count {
                    self.selected_channels[idx] = !self.selected_channels[idx];
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_confirm(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Left | KeyCode::Right | KeyCode::Tab => {
                self.confirm_selected = (self.confirm_selected + 1) % 2;
                None
            }
            KeyCode::Enter => {
                if self.confirm_selected == 0 {
                    self.build_result().map(OnboardingAction::Complete)
                } else {
                    self.retreat()
                }
            }
            KeyCode::Esc => self.retreat(),
            _ => None,
        }
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = DIALOG_W.min(area.width);
        let h = DIALOG_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 5 {
            return;
        }

        let mut cy = inner.y;

        // Step indicator
        let step_line = self.render_step_indicator(inner.width);
        frame.render_widget(
            Paragraph::new(step_line).alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Separator
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Content area
        let content_area = Rect::new(inner.x, cy, inner.width, inner.height - (cy - inner.y) - 2);

        match self.step {
            0 => self.draw_step_name(frame, content_area, &theme),
            1 => self.draw_step_profile(frame, content_area, &theme),
            2 => self.draw_step_template(frame, content_area, &theme),
            3 => self.draw_step_provider(frame, content_area, &theme),
            4 => self.draw_step_api_key(frame, content_area, &theme),
            5 => self.draw_step_machines(frame, content_area, &theme),
            6 => self.draw_step_channels(frame, content_area, &theme),
            7 => self.draw_step_confirm(frame, content_area, &theme),
            _ => {}
        }

        // Help bar
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = self.render_help_bar(&theme);
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }

    fn render_step_indicator(&self, width: u16) -> Line<'static> {
        let mut spans = Vec::new();
        for (i, label) in STEP_LABELS.iter().enumerate() {
            if i > 0 {
                spans.push(Span::styled(" · ", Style::default().fg(Color::DarkGray)));
            }
            let style = if i == self.step {
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD)
            } else if i < self.step {
                Style::default().fg(Color::DarkGray)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            // Truncate if too wide
            let _ = width;
            spans.push(Span::styled(label.to_string(), style));
        }
        Line::from(spans)
    }

    fn render_help_bar<'a>(&self, theme: &crate::style::Theme) -> Line<'a> {
        match self.step {
            1 => Line::from(vec![
                Span::styled("Tab", theme.dialog_help_key()),
                Span::styled(" toggle field  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            2 | 3 => Line::from(vec![
                Span::styled("↑↓", theme.dialog_help_key()),
                Span::styled(" select  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            4 => Line::from(vec![
                Span::styled("Tab", theme.dialog_help_key()),
                Span::styled(" show/hide  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            5 | 6 => Line::from(vec![
                Span::styled("1-9", theme.dialog_help_key()),
                Span::styled(" toggle  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            7 => Line::from(vec![
                Span::styled("←→/Tab", theme.dialog_help_key()),
                Span::styled(" focus  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" confirm", theme.dialog_help()),
            ]),
            _ => Line::from(vec![
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
        }
    }

    // ── Per-step draw methods ─────────────────────────────────────────────────

    fn draw_step_name(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        // Welcome header
        frame.render_widget(
            Paragraph::new("Welcome to OSA Agent")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // System info (2 lines max)
        let mut info_lines: Vec<Line> = Vec::new();
        if let Some(os) = self.data.system_info.get("os") {
            info_lines.push(Line::from(vec![
                Span::styled("  OS: ", Style::default().fg(theme.colors.muted)),
                Span::styled(
                    os.as_str().unwrap_or("unknown").to_string(),
                    Style::default().fg(theme.colors.secondary),
                ),
            ]));
        }
        if let Some(shell) = self.data.system_info.get("shell") {
            info_lines.push(Line::from(vec![
                Span::styled("  Shell: ", Style::default().fg(theme.colors.muted)),
                Span::styled(
                    shell.as_str().unwrap_or("unknown").to_string(),
                    Style::default().fg(theme.colors.secondary),
                ),
            ]));
        }
        for line in &info_lines {
            if cy >= area.y + area.height {
                break;
            }
            frame.render_widget(
                Paragraph::new(line.clone()),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }

        cy += 1;

        // Agent name input
        frame.render_widget(
            Paragraph::new("  Agent Name:")
                .style(Style::default().fg(theme.colors.muted)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let name_display = format!("  {}_", self.agent_name);
        frame.render_widget(
            Paragraph::new(name_display).style(
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
            Rect::new(area.x, cy, area.width, 1),
        );
    }

    fn draw_step_profile(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Your Profile")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Name field
        let name_label_style = if self.profile_field == ProfileField::Name {
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme.colors.muted)
        };
        frame.render_widget(
            Paragraph::new("  Your Name (optional):").style(name_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let name_display = if self.profile_field == ProfileField::Name {
            format!("  {}_", self.user_name)
        } else {
            format!("  {}", self.user_name)
        };
        frame.render_widget(
            Paragraph::new(name_display).style(name_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Context field
        let ctx_label_style = if self.profile_field == ProfileField::Context {
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme.colors.muted)
        };
        frame.render_widget(
            Paragraph::new("  Work Context (optional):").style(ctx_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let ctx_display = if self.profile_field == ProfileField::Context {
            format!("  {}_", self.user_context)
        } else {
            format!("  {}", self.user_context)
        };
        frame.render_widget(
            Paragraph::new(ctx_display).style(ctx_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
    }

    fn draw_step_template(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Select Template")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Blank option
        let is_blank = self.selected_template == 0;
        let blank_style = if is_blank {
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme.colors.muted)
        };
        let blank_dot = if is_blank { "●" } else { "○" };
        frame.render_widget(
            Paragraph::new(format!("  {} Blank", blank_dot)).style(blank_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        // Discovered templates
        for (i, tmpl) in self.data.templates.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let is_selected = self.selected_template == i + 1;
            let style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let dot = if is_selected { "●" } else { "○" };
            let label = format!("  {} {}  ({} modules)", dot, tmpl.name, tmpl.modules);
            frame.render_widget(
                Paragraph::new(label).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_provider(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Select Provider")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        if self.data.providers.is_empty() {
            frame.render_widget(
                Paragraph::new("  No providers available.")
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            return;
        }

        // Detect local vs cloud: ollama is local
        let mut last_was_local: Option<bool> = None;
        for (i, p) in self.data.providers.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let is_local = p.key == "ollama";
            // Group header
            if last_was_local != Some(is_local) {
                let group_label = if is_local { "  ── Local ──" } else { "  ── Cloud ──" };
                frame.render_widget(
                    Paragraph::new(group_label)
                        .style(Style::default().fg(theme.colors.dim)),
                    Rect::new(area.x, cy, area.width, 1),
                );
                cy += 1;
                last_was_local = Some(is_local);
            }

            let is_selected = self.selected_provider == i;
            let style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let dot = if is_selected { "●" } else { "○" };
            let label = format!("    {} {}  ({})", dot, p.name, p.default_model);
            frame.render_widget(
                Paragraph::new(label).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_api_key(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("API Key")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        if let Some(provider) = self.data.providers.get(self.selected_provider) {
            let prompt = format!("  Enter {} ({}):", provider.name, provider.env_var);
            frame.render_widget(
                Paragraph::new(prompt).style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;

            let display = if self.api_key_masked {
                format!("  {}_", "•".repeat(self.api_key.len()))
            } else {
                format!("  {}_", self.api_key)
            };
            frame.render_widget(
                Paragraph::new(display).style(
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 2;

            let toggle_hint = if self.api_key_masked {
                "  Tab to reveal"
            } else {
                "  Tab to hide"
            };
            frame.render_widget(
                Paragraph::new(toggle_hint)
                    .style(Style::default().fg(theme.colors.dim)),
                Rect::new(area.x, cy, area.width, 1),
            );
        }
    }

    fn draw_step_machines(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Enable Machines")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        for (i, machine) in self.data.machines.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let checked = self.selected_machines.get(i).copied().unwrap_or(false);
            let checkbox = if checked { "[x]" } else { "[ ]" };
            let style = if checked {
                Style::default().fg(theme.colors.primary)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let key_num = if i < 9 { (i + 1).to_string() } else { "0".to_string() };
            let label = format!("  {} {}  {}  — {}", key_num, checkbox, machine.name, machine.description);
            // Truncate to width
            let truncated = if label.len() > area.width as usize {
                format!("{}…", &label[..area.width.saturating_sub(1) as usize])
            } else {
                label
            };
            frame.render_widget(
                Paragraph::new(truncated).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_channels(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Enable Channels")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        for (i, channel) in self.data.channels.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let checked = self.selected_channels.get(i).copied().unwrap_or(false);
            let checkbox = if checked { "[x]" } else { "[ ]" };
            let style = if checked {
                Style::default().fg(theme.colors.primary)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let key_num = if i < 9 { (i + 1).to_string() } else { "0".to_string() };
            let label = format!("  {} {} {}  — {}", key_num, checkbox, channel.name, channel.description);
            let truncated = if label.len() > area.width as usize {
                format!("{}…", &label[..area.width.saturating_sub(1) as usize])
            } else {
                label
            };
            frame.render_widget(
                Paragraph::new(truncated).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_confirm(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        frame.render_widget(
            Paragraph::new("Confirm Setup")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Summary items
        let provider_name = self
            .data
            .providers
            .get(self.selected_provider)
            .map(|p| p.name.as_str())
            .unwrap_or("—");
        let model_name = self
            .data
            .providers
            .get(self.selected_provider)
            .map(|p| p.default_model.as_str())
            .unwrap_or("—");
        let template_name = if self.selected_template == 0 {
            "Blank".to_string()
        } else {
            self.data
                .templates
                .get(self.selected_template - 1)
                .map(|t| t.name.clone())
                .unwrap_or_else(|| "—".to_string())
        };

        let machine_count = self.selected_machines.iter().filter(|&&b| b).count();
        let channel_count = self.selected_channels.iter().filter(|&&b| b).count();

        let summary = vec![
            ("Agent", self.agent_name.clone()),
            ("Provider", format!("{} ({})", provider_name, model_name)),
            ("Template", template_name),
            ("API Key", if self.api_key.is_empty() { "not set".to_string() } else { "set".to_string() }),
            ("Machines", format!("{} enabled", machine_count)),
            ("Channels", format!("{} enabled", channel_count)),
        ];

        for (label, value) in &summary {
            if cy >= area.y + area.height.saturating_sub(3) {
                break;
            }
            let line = Line::from(vec![
                Span::styled(format!("  {:10} ", label), Style::default().fg(theme.colors.muted)),
                Span::styled(value.clone(), Style::default().fg(theme.colors.secondary)),
            ]);
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }

        // Buttons
        let btn_y = area.y + area.height.saturating_sub(2);
        let confirm_style = if self.confirm_selected == 0 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        let back_style = if self.confirm_selected == 1 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };

        let buttons = Line::from(vec![
            Span::styled("[ Confirm ]", confirm_style),
            Span::raw("   "),
            Span::styled("[ Back ]", back_style),
        ]);
        frame.render_widget(
            Paragraph::new(buttons).alignment(Alignment::Center),
            Rect::new(area.x, btn_y, area.width, 1),
        );
    }
}
