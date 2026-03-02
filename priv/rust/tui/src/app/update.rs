use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyModifiers, MouseEventKind};
use tracing::{debug, error, info, warn};

use super::App;
use crate::app::state::AppState;
use crate::components::{AppAction, Component, ComponentAction};
use crate::dialogs::command_palette::PaletteItem;
use crate::dialogs::DialogAction;
use crate::event::backend::BackendEvent;
use crate::event::Event;

impl App {
    /// Main update function. Returns true if the app should quit.
    pub fn update(&mut self, event: Event) -> bool {
        match event {
            Event::Terminal(CrosstermEvent::Resize(w, h)) => {
                self.width = w;
                self.height = h;
                self.recompute_layout();
                false
            }
            Event::Terminal(CrosstermEvent::Key(key)) => self.handle_key(key),
            Event::Terminal(CrosstermEvent::Mouse(mouse)) => {
                self.handle_mouse(mouse);
                false
            }
            Event::Terminal(_) => false, // FocusGained, FocusLost, Paste
            Event::Backend(backend_event) => self.handle_backend_event(backend_event),
            Event::Tick => {
                self.handle_tick();
                false
            }
            Event::BannerTimeout => {
                if self.state == AppState::Banner {
                    self.transition(AppState::Idle);
                }
                false
            }
            Event::HealthRetry => {
                self.check_health();
                false
            }
        }
    }

    fn handle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        match self.state {
            AppState::Quit => self.handle_quit_dialog_key(key),
            AppState::Palette => self.handle_palette_key(key),
            AppState::ModelPicker => self.handle_model_picker_key(key),
            AppState::Sessions => self.handle_session_browser_key(key),
            AppState::Idle => self.handle_idle_key(key),
            AppState::Processing => self.handle_processing_key(key),
            AppState::Banner => {
                // Any key during banner -> skip to idle
                self.transition(AppState::Idle);
                false
            }
            _ => false,
        }
    }

    fn handle_idle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let input_empty = self.input.is_empty();

        match (key.code, key.modifiers) {
            // Ctrl+C with empty input -> quit dialog
            (KeyCode::Char('c'), KeyModifiers::CONTROL) if input_empty => {
                self.transition(AppState::Quit);
                false
            }
            // Ctrl+C with content -> clear input
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.input.reset();
                false
            }
            // Ctrl+D with empty input -> immediate quit
            (KeyCode::Char('d'), KeyModifiers::CONTROL) if input_empty => true,
            // F1 -> help
            (KeyCode::F(1), _) => {
                self.show_help();
                false
            }
            // Ctrl+N -> new session
            (KeyCode::Char('n'), KeyModifiers::CONTROL) => {
                self.create_session();
                false
            }
            // Ctrl+L -> toggle sidebar
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            // Ctrl+K -> command palette
            (KeyCode::Char('k'), KeyModifiers::CONTROL) => {
                self.open_command_palette();
                false
            }
            // Scroll keys (only when input is empty)
            (KeyCode::Char('j'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_down(1);
                false
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_up(1);
                false
            }
            (KeyCode::Char('u'), KeyModifiers::NONE) if input_empty => {
                let half = self.height / 2;
                self.chat.scroll_up(half);
                false
            }
            (KeyCode::Char('d'), KeyModifiers::NONE) if input_empty => {
                let half = self.height / 2;
                self.chat.scroll_down(half);
                false
            }
            (KeyCode::PageUp, _) => {
                self.chat.scroll_up(self.height.saturating_sub(2));
                false
            }
            (KeyCode::PageDown, _) => {
                self.chat.scroll_down(self.height.saturating_sub(2));
                false
            }
            (KeyCode::Home, _) if input_empty => {
                self.chat.scroll_to_top();
                false
            }
            (KeyCode::End, _) if input_empty => {
                self.chat.scroll_to_bottom();
                false
            }
            // Copy last message
            (KeyCode::Char('y'), KeyModifiers::NONE) if input_empty => {
                self.copy_last_message();
                false
            }
            // Forward to input component
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        self.submit_input(&text);
                        false
                    }
                    _ => false,
                }
            }
        }
    }

    fn handle_processing_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        match (key.code, key.modifiers) {
            // Cancel
            (KeyCode::Esc, _) | (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.cancel_processing();
                false
            }
            // Background task
            (KeyCode::Char('b'), KeyModifiers::CONTROL) => {
                self.background_task();
                false
            }
            // Toggle sidebar
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            _ => false,
        }
    }

    fn handle_quit_dialog_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        self.quit_dialog.reset();
        if let Some(action) = self.quit_dialog.handle_key(key) {
            match action {
                DialogAction::QuitConfirmed => return true,
                DialogAction::Dismissed => self.transition(AppState::Idle),
                _ => {}
            }
        }
        false
    }

    fn handle_palette_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(action) = self.palette.handle_key(key) {
            match action {
                DialogAction::PaletteExecute(name) => {
                    self.transition(AppState::Idle);
                    self.handle_command(&format!("/{}", name));
                }
                DialogAction::Dismissed => {
                    self.transition(AppState::Idle);
                }
                _ => {}
            }
        }
        false
    }

    fn handle_model_picker_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut picker) = self.model_picker {
            if let Some(action) = picker.handle_key(key) {
                match action {
                    crate::dialogs::model_picker::ModelPickerAction::Select { provider, model } => {
                        self.transition(AppState::Idle);
                        self.switch_model(&provider, &model);
                    }
                    crate::dialogs::model_picker::ModelPickerAction::Cancel => {
                        self.transition(AppState::Idle);
                    }
                }
                self.model_picker = None;
            }
        }
        false
    }

    fn handle_session_browser_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut browser) = self.session_browser {
            if let Some(action) = browser.handle_key(key) {
                match action {
                    crate::dialogs::sessions::SessionAction::Switch(id) => {
                        self.transition(AppState::Idle);
                        self.session_id = id;
                        self.chat.clear();
                        self.tasks.clear();
                        self.stream_buf.clear();
                        self.thinking_buf.clear();
                        self.toasts.push(
                            "Session switched".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                    crate::dialogs::sessions::SessionAction::Create => {
                        self.transition(AppState::Idle);
                        self.create_session();
                    }
                    crate::dialogs::sessions::SessionAction::Cancel => {
                        self.transition(AppState::Idle);
                    }
                    _ => {
                        // Rename/Delete stay in the dialog
                        return false;
                    }
                }
                self.session_browser = None;
            }
        }
        false
    }

    fn open_command_palette(&mut self) {
        let items: Vec<PaletteItem> = self
            .command_entries
            .iter()
            .map(|c| PaletteItem {
                name: c.name.clone(),
                description: c.description.clone(),
                category: c.category.clone().unwrap_or_default(),
            })
            .collect();

        // Add built-in commands
        let mut all_items = vec![
            PaletteItem { name: "help".into(), description: "Show help".into(), category: "system".into() },
            PaletteItem { name: "clear".into(), description: "Clear chat".into(), category: "system".into() },
            PaletteItem { name: "models".into(), description: "Browse models".into(), category: "system".into() },
            PaletteItem { name: "sessions".into(), description: "Browse sessions".into(), category: "system".into() },
            PaletteItem { name: "theme".into(), description: "Switch theme".into(), category: "system".into() },
            PaletteItem { name: "exit".into(), description: "Quit".into(), category: "system".into() },
        ];
        all_items.extend(items);

        self.palette.open(all_items);
        self.transition(AppState::Palette);
    }

    fn handle_mouse(&mut self, mouse: crossterm::event::MouseEvent) {
        match mouse.kind {
            MouseEventKind::ScrollUp => {
                self.chat.scroll_up(3);
            }
            MouseEventKind::ScrollDown => {
                self.chat.scroll_down(3);
            }
            _ => {}
        }
    }

    fn handle_backend_event(&mut self, event: BackendEvent) -> bool {
        match event {
            BackendEvent::HealthResult(result) => {
                self.handle_health_result(result);
            }
            BackendEvent::LoginResult(result) => {
                self.handle_login_result(result);
            }
            BackendEvent::SseConnected { session_id } => {
                info!("SSE connected: {}", session_id);
                self.sse_reconnecting = false;
                // Load commands and tools after SSE connection
                self.load_commands();
                self.load_tools();
            }
            BackendEvent::SseDisconnected { error } => {
                if let Some(err) = error {
                    warn!("SSE disconnected: {}", err);
                }
                self.sse_reconnecting = true;
            }
            BackendEvent::SseReconnecting { attempt } => {
                debug!("SSE reconnecting (attempt {})", attempt);
                self.sse_reconnecting = true;
            }
            BackendEvent::StreamingToken { text, .. } => {
                self.stream_buf.push_str(&text);
                self.chat.update_streaming(&self.stream_buf);
            }
            BackendEvent::ThinkingDelta { text } => {
                self.thinking_buf.push_str(&text);
            }
            BackendEvent::AgentResponse {
                response,
                response_type: _,
                signal,
            } => {
                self.handle_agent_response(response, signal);
            }
            BackendEvent::ToolCallStart { name, args } => {
                if !self.activity.is_active() {
                    self.activity.start();
                }
                self.activity.tool_start(&name, &args);
                self.recompute_layout();
                debug!("Tool call start: {}", name);
            }
            BackendEvent::ToolCallEnd {
                name,
                duration_ms,
                success,
            } => {
                self.activity.tool_end(&name, duration_ms, success);
                debug!(
                    "Tool call end: {} ({}ms, success={})",
                    name, duration_ms, success
                );
            }
            BackendEvent::ToolResult {
                name, success, ..
            } => {
                debug!("Tool result: {} (success={})", name, success);
            }
            BackendEvent::LlmRequest { iteration } => {
                debug!("LLM request iteration {}", iteration);
            }
            BackendEvent::LlmResponse {
                duration_ms,
                input_tokens,
                output_tokens,
            } => {
                self.status
                    .set_stats(input_tokens, output_tokens, duration_ms);
                self.activity.set_tokens(input_tokens, output_tokens);
            }
            BackendEvent::SignalClassified { signal } => {
                self.status.set_signal(signal);
            }
            BackendEvent::ContextPressure {
                utilization,
                estimated_tokens,
                max_tokens,
            } => {
                self.status
                    .set_context(utilization, estimated_tokens, max_tokens);
            }
            BackendEvent::TaskCreated {
                task_id,
                subject,
                active_form: _,
            } => {
                self.tasks.add(task_id.clone(), subject, String::new());
                self.recompute_layout();
            }
            BackendEvent::TaskUpdated { task_id, status } => {
                self.tasks.update(&task_id, &status);
            }
            BackendEvent::CommandsLoaded(result) => match result {
                Ok(commands) => {
                    let names: Vec<String> =
                        commands.iter().map(|c| c.name.clone()).collect();
                    self.input.set_commands(names);
                    self.command_entries = commands;
                }
                Err(e) => warn!("Failed to load commands: {}", e),
            },
            BackendEvent::ToolsLoaded(result) => match result {
                Ok(tools) => {
                    self.header.set_tool_count(tools.len());
                    // Update welcome screen tool inventory
                    self.chat.set_welcome_info(
                        self.header.provider(),
                        self.header.model_name(),
                        tools.len(),
                    );
                }
                Err(e) => warn!("Failed to load tools: {}", e),
            },
            BackendEvent::OrchestrateResult(result) => match result {
                Ok(resp) => {
                    debug!(
                        "Orchestrate response: session={}, status={}",
                        resp.session_id, resp.status
                    );
                }
                Err(e) => {
                    error!("Orchestrate failed: {}", e);
                    self.toasts.push(
                        format!("Error: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                    if self.state == AppState::Processing {
                        self.transition(AppState::Idle);
                        self.activity.stop();
                    }
                }
            },
            BackendEvent::CommandResult(result) => {
                self.handle_command_result(result);
            }
            BackendEvent::ModelSwitched(result) => match result {
                Ok(resp) => {
                    self.header.set_provider_info(&resp.provider, &resp.model);
                    self.status.set_provider_info(&resp.provider, &resp.model);
                    self.chat.set_welcome_info(
                        &resp.provider,
                        &resp.model,
                        self.header.tool_count(),
                    );
                    self.toasts.push(
                        format!("Model: {}/{}", resp.provider, resp.model),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Model switch failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SessionCreated(result) => match result {
                Ok(resp) => {
                    self.session_id = resp.id;
                    self.chat.clear();
                    self.tasks.clear();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.toasts.push(
                        "New session".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Session create failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            // === Models/Sessions loaded (dialog triggers) ===
            BackendEvent::ModelsLoaded(result) => match result {
                Ok(resp) => {
                    let picker = crate::dialogs::model_picker::ModelPicker::new(
                        resp.models,
                        Vec::new(),
                    );
                    self.model_picker = Some(picker);
                    self.transition(AppState::ModelPicker);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load models: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SessionsLoaded(result) => match result {
                Ok(sessions) => {
                    let browser = crate::dialogs::sessions::SessionBrowser::new(
                        sessions,
                        self.session_id.clone(),
                    );
                    self.session_browser = Some(browser);
                    self.transition(AppState::Sessions);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load sessions: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },

            // === Orchestrator events → Agents component ===
            BackendEvent::OrchestratorTaskStarted { task_id } => {
                self.agents.task_started(&task_id);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentStarted { agent_name, role, model } => {
                self.agents.agent_started(&agent_name, &role, &model);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentProgress { agent_name, current_action, tool_uses, tokens_used } => {
                self.agents.agent_progress(&agent_name, &current_action, tool_uses, tokens_used);
            }
            BackendEvent::OrchestratorAgentCompleted { agent_name, tool_uses, tokens_used, .. } => {
                self.agents.agent_completed(&agent_name, tool_uses, tokens_used);
            }
            BackendEvent::OrchestratorAgentFailed { agent_name, error, tool_uses, tokens_used } => {
                self.agents.agent_failed(&agent_name, &error, tool_uses, tokens_used);
            }
            BackendEvent::OrchestratorWaveStarted { wave_number, total_waves } => {
                self.agents.wave_started(wave_number, total_waves);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorTaskCompleted { .. } => {
                self.agents.task_completed();
                self.recompute_layout();
            }

            // === Swarm events → Agents component ===
            BackendEvent::SwarmStarted { swarm_id, pattern, agent_count, .. } => {
                self.agents.swarm_started(&swarm_id, &pattern, agent_count);
                self.recompute_layout();
            }
            BackendEvent::SwarmCompleted { swarm_id, .. } => {
                self.agents.swarm_completed(&swarm_id);
                self.recompute_layout();
            }
            BackendEvent::SwarmFailed { swarm_id, reason } => {
                self.agents.swarm_failed(&swarm_id, &reason);
                self.recompute_layout();
            }
            BackendEvent::SwarmCancelled { swarm_id } => {
                self.agents.swarm_failed(&swarm_id, "cancelled");
                self.recompute_layout();
            }
            BackendEvent::SwarmTimeout { swarm_id } => {
                self.agents.swarm_failed(&swarm_id, "timeout");
                self.recompute_layout();
            }

            // Handle remaining events as they are implemented
            _ => {
                debug!("Unhandled backend event");
            }
        }
        false
    }

    fn handle_tick(&mut self) {
        self.toasts.tick();
        self.activity.tick();

        // Check banner timeout
        if self.state == AppState::Banner {
            if let Some(start) = self.banner_start {
                if start.elapsed() >= super::BANNER_DURATION {
                    self.transition(AppState::Idle);
                }
            }
        }
    }

    // === Action handlers ===

    fn handle_health_result(
        &mut self,
        result: Result<crate::client::types::HealthResponse, String>,
    ) {
        match result {
            Ok(health) => {
                info!(
                    "Backend healthy: {} v{} ({}/{})",
                    health.status, health.version, health.provider, health.model
                );
                self.header
                    .set_provider_info(&health.provider, &health.model);
                self.status
                    .set_provider_info(&health.provider, &health.model);
                self.chat.set_welcome_info(
                    &health.provider,
                    &health.model,
                    self.header.tool_count(),
                );
                self.transition(AppState::Banner);
                self.banner_start = Some(std::time::Instant::now());

                // Start auth + SSE
                self.do_login();
            }
            Err(e) => {
                warn!("Health check failed: {}", e);

                // Auto-start backend on first failure
                if !self.backend_spawn_attempted {
                    self.backend_spawn_attempted = true;
                    self.try_spawn_backend();
                }

                // Retry after delay
                let tx = self.event_tx.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(super::HEALTH_RETRY_DELAY).await;
                    let _ = tx.send(Event::HealthRetry);
                });
            }
        }
    }

    fn handle_login_result(
        &mut self,
        result: Result<crate::client::types::LoginResponse, String>,
    ) {
        match result {
            Ok(_) => {
                info!("Login successful");
                // Load commands and tools in parallel
                self.load_commands();
                self.load_tools();
                // Start SSE
                self.start_sse();
            }
            Err(e) => {
                warn!("Login failed: {}", e);
                self.toasts.push(
                    format!("Login failed: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }
    }

    fn handle_agent_response(
        &mut self,
        response: String,
        signal: Option<crate::client::types::Signal>,
    ) {
        // Truncate if too long
        let display_response = if response.len() > super::MAX_MESSAGE_SIZE {
            let truncated = &response[..super::MAX_MESSAGE_SIZE];
            format!(
                "{}\n\n... (response truncated at {}KB)",
                truncated,
                super::MAX_MESSAGE_SIZE / 1000
            )
        } else {
            response
        };

        self.chat.clear_streaming();
        self.chat
            .add_agent_message(&display_response, signal.as_ref());

        // Clear streaming state
        self.stream_buf.clear();
        self.thinking_buf.clear();
        self.activity.stop();
        self.status.set_active(false);
        self.cancelled = false;

        // Transition back to idle
        if self.state == AppState::Processing {
            self.transition(AppState::Idle);
        }

        // Update signal in status bar
        if let Some(signal) = signal {
            self.status.set_signal(signal);
        }

        self.recompute_layout();
    }

    fn handle_command_result(
        &mut self,
        result: Result<crate::client::types::CommandExecuteResponse, String>,
    ) {
        match result {
            Ok(resp) => {
                match resp.kind.as_str() {
                    "error" => {
                        self.chat
                            .add_system_message(&resp.output, "error");
                    }
                    "prompt" => {
                        // Feed output back as prompt
                        self.submit_prompt(&resp.output);
                    }
                    "action" => {
                        if let Some(action) = resp.action {
                            self.handle_command_action(&action);
                        }
                    }
                    _ => {
                        if !resp.output.is_empty() {
                            self.chat
                                .add_system_message(&resp.output, "info");
                        }
                    }
                }
            }
            Err(e) => {
                self.toasts.push(
                    format!("Command error: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }

        if self.state == AppState::Processing {
            self.transition(AppState::Idle);
            self.activity.stop();
            self.status.set_active(false);
        }
    }

    fn handle_command_action(&mut self, action: &str) {
        match action {
            ":new_session" => self.create_session(),
            ":clear" => {
                self.chat.clear();
                self.tasks.clear();
            }
            _ => {
                debug!("Unhandled command action: {}", action);
            }
        }
    }

    pub fn submit_input(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }

        if text.starts_with('/') {
            self.handle_command(text);
        } else {
            self.submit_prompt(text);
        }
    }

    pub(crate) fn submit_prompt(&mut self, text: &str) {
        self.chat.add_user_message(text);
        self.transition(AppState::Processing);
        self.activity.start();
        self.status.set_active(true);
        self.processing_start = Some(std::time::Instant::now());
        self.stream_buf.clear();
        self.thinking_buf.clear();

        // Send to backend
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let input = text.to_string();

        tokio::spawn(async move {
            let req = crate::client::types::OrchestrateRequest {
                input,
                session_id: Some(session_id),
                user_id: None,
                workspace_id: None,
                skip_plan: None,
            };
            let result = client.orchestrate(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::OrchestrateResult(Ok(resp)),
                Err(e) => BackendEvent::OrchestrateResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn cancel_processing(&mut self) {
        self.cancelled = true;
        self.chat.clear_streaming();
        self.stream_buf.clear();
        self.thinking_buf.clear();
        self.activity.stop();
        self.status.set_active(false);
        self.transition(AppState::Idle);
        self.toasts.push(
            "Cancelled".into(),
            crate::components::toast::ToastLevel::Info,
        );
    }

    fn background_task(&mut self) {
        if self.state != AppState::Processing {
            return;
        }
        let summary = format!(
            "Background task ({}s)",
            self.processing_start
                .map(|t| t.elapsed().as_secs())
                .unwrap_or(0)
        );
        self.bg_tasks.push(summary);
        self.status.set_background_count(self.bg_tasks.len());
        self.toasts.push(
            "Moved to background".into(),
            crate::components::toast::ToastLevel::Info,
        );
        // Don't cancel processing, just hide the activity
        self.activity.stop();
        self.transition(AppState::Idle);
    }

    pub fn check_health(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.health().await;
            let event = match result {
                Ok(resp) => BackendEvent::HealthResult(Ok(resp)),
                Err(e) => BackendEvent::HealthResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn do_login(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.login(Some("local")).await;
            let event = match result {
                Ok(resp) => BackendEvent::LoginResult(Ok(resp)),
                Err(e) => BackendEvent::LoginResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn load_commands(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_commands().await;
            let event = match result {
                Ok(commands) => BackendEvent::CommandsLoaded(Ok(commands)),
                Err(e) => BackendEvent::CommandsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_models(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_models().await;
            let event = match result {
                Ok(resp) => BackendEvent::ModelsLoaded(Ok(resp)),
                Err(e) => BackendEvent::ModelsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_sessions(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_sessions().await;
            let event = match result {
                Ok(sessions) => BackendEvent::SessionsLoaded(Ok(sessions)),
                Err(e) => BackendEvent::SessionsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn load_tools(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_tools().await;
            let event = match result {
                Ok(tools) => BackendEvent::ToolsLoaded(Ok(tools)),
                Err(e) => BackendEvent::ToolsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn try_spawn_backend(&self) {
        // Discover project root by searching upward from known locations.
        // Priority:
        //   1. Binary path: priv/rust/tui/target/release/osagent → walk up 5 levels
        //   2. ~/.osa/project_root file (written by `bin/install`)
        //   3. Current working directory (if it contains mix.exs)
        let candidates: Vec<Option<std::path::PathBuf>> = vec![
            // From binary location: target/release/osagent → ../../.. = priv/rust/tui → ../../../ = root
            std::env::current_exe()
                .ok()
                .and_then(|p| {
                    // osagent → release → target → tui → rust → priv → ROOT
                    p.parent()?.parent()?.parent()?.parent()?.parent()?.parent()
                        .map(|p| p.to_path_buf())
                }),
            // Stored project root
            std::fs::read_to_string(
                std::path::PathBuf::from(
                        std::env::var("HOME").unwrap_or_default()
                    ).join(".osa/project_root"),
            )
            .ok()
            .map(|s| std::path::PathBuf::from(s.trim())),
            // CWD
            std::env::current_dir().ok(),
        ];

        for candidate in candidates.into_iter().flatten() {
            if candidate.join("mix.exs").exists() {
                info!("Auto-starting backend from: {}", candidate.display());
                let project_dir = candidate;
                let log_dir = std::path::PathBuf::from(
                        std::env::var("HOME").unwrap_or_default()
                    ).join(".osa/logs/backend.log");
                std::thread::spawn(move || {
                    let log_file = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_dir)
                        .ok();
                    let stdout = log_file
                        .as_ref()
                        .map(|f| std::process::Stdio::from(f.try_clone().unwrap()))
                        .unwrap_or_else(std::process::Stdio::null);
                    let stderr = log_file
                        .map(|f| std::process::Stdio::from(f))
                        .unwrap_or_else(std::process::Stdio::null);
                    let _ = std::process::Command::new("mix")
                        .arg("osa.serve")
                        .current_dir(&project_dir)
                        .stdout(stdout)
                        .stderr(stderr)
                        .spawn();
                });
                return;
            }
        }
        warn!("Could not find project root to auto-start backend. \
               Run from the project directory or create ~/.osa/project_root");
    }

    fn start_sse(&mut self) {
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let base_url = self.config.base_url.clone();
        let client = self.client.clone();

        tokio::spawn(async move {
            let token = match client.token().await {
                Some(t) => t,
                None => {
                    warn!("No auth token for SSE");
                    return;
                }
            };

            // SseClient wraps events in Event::Backend() internally
            let sse = crate::client::SseClient::new(session_id, base_url, token, tx);
            sse.connect();
        });
    }

    pub(crate) fn show_help(&mut self) {
        let help = "OSA Agent - Available Commands:\n\
            /help - Show this help\n\
            /clear - Clear chat\n\
            /models - Browse models\n\
            /model <name> - Switch model\n\
            /sessions - Browse sessions\n\
            /session new - Create new session\n\
            /theme <name> - Switch theme\n\
            /exit - Quit\n\
            \n\
            Keyboard Shortcuts:\n\
            Ctrl+K - Command palette\n\
            Ctrl+N - New session\n\
            Ctrl+L - Toggle sidebar\n\
            Ctrl+C - Cancel/Quit\n\
            j/k - Scroll (when input empty)\n\
            PgUp/PgDn - Page scroll";
        self.chat.add_system_message(help, "info");
    }

    pub(crate) fn create_session(&mut self) {
        // create_session is a todo! stub in http.rs, so just reset locally
        self.session_id = super::generate_session_id();
        self.chat.clear();
        self.tasks.clear();
        self.stream_buf.clear();
        self.thinking_buf.clear();
        self.toasts.push(
            "New session created".into(),
            crate::components::toast::ToastLevel::Info,
        );
    }

    fn copy_last_message(&mut self) {
        if let Some(msg) = self.chat.last_agent_message() {
            match arboard::Clipboard::new().and_then(|mut cb| cb.set_text(msg)) {
                Ok(_) => {
                    self.toasts.push(
                        "Copied to clipboard".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    warn!("Failed to copy: {}", e);
                    self.toasts.push(
                        format!("Copy failed: {}", e),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            }
        }
    }
}

