pub mod entry;
mod render;

use ratatui::prelude::*;

use crate::event::Event;
use crate::event::backend::SpawningAgent;

use super::{Component, ComponentAction};
use entry::{AgentEntry, SwarmInfo, SwarmStatus, SynthesisState, WaveInfo};
pub use entry::AgentStatus;

// ─── Component ────────────────────────────────────────────────────────────────

pub struct Agents {
    active: bool,
    task_id: Option<String>,
    entries: Vec<AgentEntry>,
    wave: Option<WaveInfo>,
    swarm: Option<SwarmInfo>,
    collapsed: bool,
    synthesis: SynthesisState,
    tick: u64,
}

impl Agents {
    pub fn new() -> Self {
        Self {
            active: false,
            task_id: None,
            entries: Vec::new(),
            wave: None,
            swarm: None,
            collapsed: false,
            synthesis: SynthesisState::Idle,
            tick: 0,
        }
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Total render height: 0 when inactive, else header + 2*agents + optional synth + swarm.
    /// Capped at 24 to prevent degenerate cases.
    pub fn height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        if self.collapsed {
            return 1;
        }
        let agent_lines = (self.entries.len() as u16) * 2; // 2 rows per agent
        let synth_lines = if matches!(self.synthesis, SynthesisState::Synthesizing { .. }) {
            1u16
        } else {
            0
        };
        let swarm_lines = if self.swarm.is_some() { 1u16 } else { 0 };
        // 1 header + agents + synth + swarm
        let total = 1 + agent_lines + synth_lines + swarm_lines;
        total.min(24)
    }

    /// Advance spinner animation frame.
    pub fn tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
    }

    // ─── Public mutation API ─────────────────────────────────────────────────

    pub fn task_started(&mut self, task_id: impl Into<String>) {
        self.active = true;
        self.task_id = Some(task_id.into());
        self.entries.clear();
        self.wave = None;
        self.swarm = None;
        self.synthesis = SynthesisState::Idle;
        self.collapsed = false;
    }

    pub fn on_agents_spawning(&mut self, agents: &[SpawningAgent]) {
        // Pre-populate entries in Spawning state
        for agent in agents {
            if !self.entries.iter().any(|e| e.name == agent.name) {
                self.entries.push(AgentEntry {
                    name: agent.name.clone(),
                    role: agent.role.clone(),
                    model: String::new(),
                    subject: String::new(),
                    status: AgentStatus::Spawning,
                    current_action: String::new(),
                    tool_uses: 0,
                    tokens_used: 0,
                });
            }
        }
        self.active = true;
    }

    pub fn agent_started(
        &mut self,
        name: impl Into<String>,
        role: impl Into<String>,
        model: impl Into<String>,
        subject: impl Into<String>,
    ) {
        let name = name.into();
        let subject = subject.into();
        // Upgrade Spawning→Running by name match, or insert new
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Running;
            entry.model = model.into();
            entry.role = role.into();
            if !subject.is_empty() {
                entry.subject = subject;
            }
            entry.current_action = String::new();
            entry.tool_uses = 0;
            entry.tokens_used = 0;
        } else {
            self.entries.push(AgentEntry {
                name,
                role: role.into(),
                model: model.into(),
                subject,
                status: AgentStatus::Running,
                current_action: String::new(),
                tool_uses: 0,
                tokens_used: 0,
            });
        }
        self.active = true;
    }

    pub fn agent_progress(
        &mut self,
        name: &str,
        action: impl Into<String>,
        tool_uses: u32,
        tokens: u32,
        subject: impl Into<String>,
    ) {
        let subject = subject.into();
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.current_action = action.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
            if !subject.is_empty() && entry.subject.is_empty() {
                entry.subject = subject;
            }
        }
    }

    pub fn agent_completed(&mut self, name: &str, tool_uses: u32, tokens: u32) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Completed;
            entry.current_action = "complete".into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
        }
    }

    pub fn agent_failed(
        &mut self,
        name: &str,
        error: impl Into<String>,
        tool_uses: u32,
        tokens: u32,
    ) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Failed;
            entry.current_action = error.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
        }
    }

    pub fn wave_started(&mut self, current: u32, total: u32) {
        self.wave = Some(WaveInfo { current, total });
    }

    pub fn on_synthesizing(&mut self, count: usize) {
        self.synthesis = SynthesisState::Synthesizing { count };
    }

    pub fn task_completed(&mut self) {
        self.synthesis = SynthesisState::Idle;
        // Keep active briefly so the user can see final state; caller hides.
        self.active = false;
    }

    pub fn toggle_collapse(&mut self) {
        self.collapsed = !self.collapsed;
    }

    pub fn swarm_started(
        &mut self,
        id: impl Into<String>,
        pattern: impl Into<String>,
        count: u32,
    ) {
        self.swarm = Some(SwarmInfo {
            id: id.into(),
            pattern: pattern.into(),
            agent_count: count,
            status: SwarmStatus::Running,
        });
        self.active = true;
    }

    pub fn swarm_completed(&mut self, id: &str) {
        if let Some(ref mut s) = self.swarm {
            if s.id == id {
                s.status = SwarmStatus::Completed;
            }
        }
    }

    pub fn swarm_failed(&mut self, id: &str, _reason: &str) {
        if let Some(ref mut s) = self.swarm {
            if s.id == id {
                s.status = SwarmStatus::Failed;
            }
        }
    }

    #[allow(dead_code)]
    pub fn clear(&mut self) {
        self.active = false;
        self.task_id = None;
        self.entries.clear();
        self.wave = None;
        self.swarm = None;
        self.synthesis = SynthesisState::Idle;
        self.collapsed = false;
    }
}

impl Component for Agents {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.active || area.height == 0 || area.width == 0 {
            return;
        }
        self.draw_tree(frame, area);
    }
}
