package app

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/config"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/ui/activity"
	"github.com/miosa/osa-tui/ui/clipboard"
	"github.com/miosa/osa-tui/ui/completions"
	"github.com/miosa/osa-tui/ui/dialog"
	"github.com/miosa/osa-tui/ui/status"
	"github.com/miosa/osa-tui/ui/toast"
)

// -- Update -------------------------------------------------------------------
func (m Model) Update(rawMsg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch v := rawMsg.(type) {

	case tea.WindowSizeMsg:
		m.width = v.Width
		m.height = v.Height
		m.layout = ComputeLayout(
			v.Width, v.Height, m.layoutMode,
			countLines(m.status.View()),
			countLines(m.tasks.View()),
			countLines(m.agents.View()),
		)
		m.chat.SetSize(m.layout.ChatWidth, m.layout.ChatHeight)
		m.sidebar.SetSize(m.layout.SidebarWidth, m.layout.SidebarHeight)
		m.plan.SetWidth(v.Width - 4)
		m.picker.SetWidth(v.Width - 4)
		m.input.SetWidth(v.Width)
		m.header.SetWidth(v.Width)
		m.permissions.SetSize(v.Width, v.Height)
		m.sessions.SetSize(v.Width, v.Height)
		m.quit.SetSize(v.Width, v.Height)
		m.models.SetSize(v.Width, v.Height)
		m.onboarding.SetSize(v.Width, v.Height)
		return m, nil

	case tea.MouseClickMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			m.selection.HandleMouseDown(v.X, v.Y, time.Now().UnixMilli())
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(v)
			return m, cmd
		case StateModelPicker:
			var cmd tea.Cmd
			m.picker, cmd = m.picker.Update(v)
			return m, cmd
		}
		return m, nil

	case tea.MouseMotionMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			m.selection.HandleMouseMotion(v.X, v.Y)
		}
		return m, nil

	case tea.MouseReleaseMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			m.selection.HandleMouseUp(v.X, v.Y)
			if m.selection.HasSelection() {
				// Auto-copy selection to clipboard.
				if text := m.chat.PlainTextLines(); len(text) > 0 {
					selected := m.selection.SelectedText(text)
					if selected != "" {
						_ = clipboard.Copy(selected)
						m.toasts.Add("Copied selection", toast.ToastInfo)
						return m, m.tickCmd()
					}
				}
			}
		}
		return m, nil

	case tea.MouseWheelMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			m.selection.Clear()
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(v)
			return m, cmd
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(v)

	case tea.PasteMsg:
		// Forward bracketed paste to the input so the textarea can insert the text.
		if m.state == StateIdle || m.state == StateProcessing {
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(v)
			return m, cmd
		}
		return m, nil

	// -- Program lifecycle --

	case ProgramReady:
		m.program = v.Program
		if m.sessionID != "" && m.sse == nil {
			return m, m.startSSE()
		}
		return m, nil

	// -- Health / connection --

	case msg.HealthResult:
		return m.handleHealth(v)

	case retryHealth:
		return m, m.checkHealth()

	case bannerTimeout:
		if m.state == StateBanner {
			return m, m.checkOnboarding()
		}
		return m, nil

	case msg.OnboardingStatusResult:
		if v.Err != nil {
			if m.forceOnboarding {
				// /setup explicitly requested — show error instead of silently skipping
				m.forceOnboarding = false
				m.state = StateIdle
				m.recomputeLayout()
				m.chat.AddSystemMessage("Setup wizard unavailable — backend not reachable")
				return m, m.input.Focus()
			}
			// Fail-open: backend unreachable, skip onboarding with notice
			m.state = StateIdle
			m.recomputeLayout()
			m.chat.AddSystemMessage("Could not check setup status — run /doctor to verify configuration")
			return m, m.input.Focus()
		}
		if !v.NeedsOnboarding && !m.forceOnboarding {
			m.state = StateIdle
			m.recomputeLayout()
			return m, m.input.Focus()
		}
		m.forceOnboarding = false
		m.onboarding = dialog.NewOnboardingFromStatus(v)
		m.onboarding.SetSize(m.width, m.height)
		m.state = StateOnboarding
		m.input.Blur()
		return m, nil

	case dialog.OnboardingDone:
		// Fire POST to complete setup
		return m, m.completeOnboarding(v)

	case msg.OnboardingSetupError:
		// Return to wizard with error visible on confirm screen
		m.onboarding.SetError(v.Err.Error())
		return m, nil

	case msg.OnboardingComplete:
		m.state = StateIdle
		m.recomputeLayout()
		m.header.SetHealth(msg.HealthResult{Provider: v.Provider, Model: v.Model})
		m.status.SetProviderInfo(v.Provider, v.Model)
		m.sidebar.SetModelInfo(v.Provider, v.Model)
		m.chat.AddSystemMessage(fmt.Sprintf("Setup complete — using %s/%s", v.Provider, v.Model))
		return m, m.input.Focus()

	// -- Orchestration --

	case msg.OrchestrateResult:
		return m.handleOrchestrate(v)

	case msg.CommandResult:
		return m.handleCommand(v)

	case commandsLoaded:
		m.commandEntries = []client.CommandEntry(v)
		names := make([]string, len(v))
		items := make([]completions.CompletionItem, len(v))
		for i, cmd := range v {
			names[i] = "/" + cmd.Name
			items[i] = completions.CompletionItem{
				Name:        "/" + cmd.Name,
				Description: cmd.Description,
				Category:    cmd.Category,
				Icon:        "/",
			}
		}
		m.input.SetCommands(names)
		m.input.SetCompletions(items)
		return m, nil

	case toolCountLoaded:
		m.header.SetToolCount(int(v))
		m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
		return m, nil

	// -- SSE lifecycle --

	case client.SSEConnectedEvent:
		m.sessionID = v.SessionID
		m.sseReconnecting = false
		return m, nil

	case client.SSEDisconnectedEvent:
		if m.sseReconnecting {
			return m, nil
		}
		if m.sessionID != "" && m.sse != nil && !m.sse.IsClosed() && m.program != nil {
			m.sseReconnecting = true
			return m, m.sse.ReconnectListenCmd(m.program)
		}
		return m, nil

	case client.SSEReconnectingEvent:
		m.chat.AddSystemWarning(fmt.Sprintf(
			"Connection lost. Reconnecting (attempt %d/%d)...", v.Attempt, client.MaxReconnects,
		))
		return m, nil

	case client.SSEAuthFailedEvent:
		m.closeSSE()
		if m.refreshToken != "" {
			return m, m.doRefreshToken(m.refreshToken)
		}
		m.chat.AddSystemWarning("Authentication expired. Use /login to re-authenticate.")
		m.state = StateIdle
		return m, m.input.Focus()

	case refreshTokenResult:
		return m.handleRefreshTokenResult(v)

	// -- Auth --

	case msg.LoginResult:
		if v.Err != nil {
			m.chat.AddSystemWarning(fmt.Sprintf("Login skipped (anonymous mode): %v", v.Err))
		} else {
			m.client.SetToken(v.Token)
			m.refreshToken = v.RefreshToken
			m.chat.AddSystemMessage(fmt.Sprintf("Authenticated (token expires in %ds)", v.ExpiresIn))
			if m.sse != nil {
				m.closeSSE()
			}
			// Now that we have a token, fetch commands/tools and start SSE.
			var loginCmds []tea.Cmd
			loginCmds = append(loginCmds, m.fetchCommands(), m.fetchToolCount())
			if m.program != nil && m.sessionID != "" {
				if cmd := m.startSSE(); cmd != nil {
					loginCmds = append(loginCmds, cmd)
				}
			}
			return m, tea.Batch(loginCmds...)
		}
		return m, nil

	case msg.LogoutResult:
		if v.Err != nil {
			m.chat.AddSystemError(fmt.Sprintf("Logout error: %v", v.Err))
		} else {
			m.chat.AddSystemMessage("Logged out")
			m.closeSSE()
		}
		return m, nil

	// -- Sessions --

	case msg.SessionListResult:
		return m.handleSessionList(v)

	case msg.SessionSwitchResult:
		return m.handleSessionSwitch(v)

	// -- Streaming / SSE agent events --

	case client.StreamingTokenEvent:
		m.streamBuf.WriteString(v.Text)
		m.chat.SetStreamingContent(m.streamBuf.String())
		return m, nil

	case client.ThinkingDeltaEvent:
		m.activity, _ = m.activity.Update(msg.ThinkingDelta{Text: v.Text})
		m.thinkingBuf.WriteString(v.Text)
		m.chat.SetThinkingContent(m.thinkingBuf.String())
		return m, nil

	case client.AgentResponseEvent:
		m.streamBuf.Reset()
		return m.handleClientAgentResponse(v)

	case client.LLMRequestEvent:
		m.activity, _ = m.activity.Update(msg.LLMRequest{Iteration: v.Iteration})
		return m, nil

	case client.ToolCallStartEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallStart{Name: v.Name, Args: v.Args})
		m.chat.TrackToolStart(v.Name, v.Args)
		return m, nil

	case client.ToolCallEndEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallEnd{Name: v.Name, DurationMs: v.DurationMs, Success: v.Success})
		m.chat.TrackToolEnd(v.Name, v.DurationMs, v.Success)
		return m, nil

	case client.LLMResponseEvent:
		m.activity, _ = m.activity.Update(msg.LLMResponse{
			DurationMs:   v.DurationMs,
			InputTokens:  v.InputTokens,
			OutputTokens: v.OutputTokens,
		})
		m.status.SetStats(time.Since(m.processingStart), m.activity.ToolCount(), v.InputTokens, v.OutputTokens)
		return m, nil

	case client.ContextPressureEvent:
		m.status.SetContext(v.Utilization, v.MaxTokens, v.EstimatedTokens)
		m.sidebar.SetContext(v.Utilization, v.MaxTokens, v.EstimatedTokens)
		return m, nil

	// -- Tasks --

	case client.TaskCreatedEvent:
		m.tasks.AddTask(activity.Task{
			ID:         v.TaskID,
			Subject:    v.Subject,
			Status:     "pending",
			ActiveForm: v.ActiveForm,
		})
		return m, nil

	case client.TaskUpdatedEvent:
		m.tasks.UpdateTask(v.TaskID, v.Status)
		return m, nil

	// -- Orchestrator multi-agent events --

	case client.OrchestratorTaskStartedEvent:
		m.agents.Start()
		return m, nil

	case client.OrchestratorWaveStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorWaveStarted{
			WaveNumber: v.WaveNumber,
			TotalWaves: v.TotalWaves,
		})
		return m, nil

	case client.OrchestratorAgentStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentStarted{
			AgentName: v.AgentName,
			Role:      v.Role,
			Model:     v.Model,
		})
		return m, nil

	case client.OrchestratorAgentProgressEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentProgress{
			AgentName:     v.AgentName,
			CurrentAction: v.CurrentAction,
			ToolUses:      v.ToolUses,
			TokensUsed:    v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorAgentCompletedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentCompleted{
			AgentName:  v.AgentName,
			ToolUses:   v.ToolUses,
			TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorAgentFailedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentFailed{
			AgentName:  v.AgentName,
			Error:      v.Error,
			ToolUses:   v.ToolUses,
			TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorTaskCompletedEvent:
		m.agents.Stop()
		return m, nil

	// -- Swarm events --

	case client.SwarmStartedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm launched: %s pattern with %d agents", v.Pattern, v.AgentCount,
		))
		return m, nil

	case client.SwarmCompletedEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		if v.ResultPreview != "" {
			m.chat.AddAgentMessage(v.ResultPreview, nil, 0, fmt.Sprintf("swarm/%s", v.Pattern))
		} else {
			m.chat.AddSystemMessage(fmt.Sprintf("Swarm %s (%s) completed.", v.SwarmID, v.Pattern))
		}
		return m, m.input.Focus()

	case client.SwarmFailedEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemError(fmt.Sprintf("Swarm %s failed: %s", v.SwarmID, v.Reason))
		return m, m.input.Focus()

	case client.SwarmCancelledEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemWarning(fmt.Sprintf("Swarm %s was cancelled.", v.SwarmID))
		return m, m.input.Focus()

	case client.SwarmTimeoutEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemError(fmt.Sprintf("Swarm %s timed out.", v.SwarmID))
		return m, m.input.Focus()

	case client.SwarmIntelligenceStartedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm intelligence (%s) started: %s", v.Type, v.Task,
		))
		return m, nil

	case client.SwarmIntelligenceRoundEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence round %d", v.Round))
		return m, nil

	case client.SwarmIntelligenceConvergedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence converged at round %d", v.Round))
		return m, nil

	case client.SwarmIntelligenceCompletedEvent:
		statusStr := "completed"
		if v.Converged {
			statusStr = "converged"
		}
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm intelligence %s after %d rounds", statusStr, v.Rounds,
		))
		return m, nil

	// -- Hook / budget events --

	case client.HookBlockedEvent:
		m.chat.AddSystemWarning(fmt.Sprintf("Hook blocked: %s — %s", v.HookName, v.Reason))
		return m, nil

	case client.BudgetWarningEvent:
		m.chat.AddSystemWarning(fmt.Sprintf("Budget at %.0f%%: %s", v.Utilization*100, v.Message))
		return m, nil

	case client.BudgetExceededEvent:
		m.chat.AddSystemError(fmt.Sprintf("Budget exceeded: %s", v.Message))
		return m, nil

	// -- Tool results --

	case client.ToolResultEvent:
		m.activity, _ = m.activity.Update(msg.ToolResult{Name: v.Name, Result: v.Result, Success: v.Success})
		m.chat.TrackToolResult(v.Name, v.Result, v.Success)
		return m, nil

	// -- Signal classification --

	case client.SignalClassifiedEvent:
		sig := &status.Signal{Mode: v.Mode, Genre: v.Genre, Type: v.Type, Weight: v.Weight}
		m.status.SetSignal(sig)
		return m, nil

	// -- Parse warnings (toasts) --

	case client.SSEParseWarning:
		m.toasts.Add(v.Message, toast.ToastWarning)
		return m, m.tickCmd()

	case msg.SSEParseWarning:
		m.toasts.Add(v.Message, toast.ToastWarning)
		return m, m.tickCmd()

	// -- UI toggle events --

	case msg.ToggleExpand:
		m.activity, _ = m.activity.Update(v)
		m.agents, _ = m.agents.Update(v)
		m.tasks = m.tasks.Update(v)
		return m, nil

	case msg.ToggleSidebar:
		if m.layoutMode == LayoutSidebar {
			m.layoutMode = LayoutCompact
			m.config.SidebarOpen = false
		} else {
			m.layoutMode = LayoutSidebar
			m.config.SidebarOpen = true
		}
		_ = config.Save(profileDirPath(), m.config)
		m.recomputeLayout()
		return m, nil

	// -- Tick --

	case msg.TickMsg:
		m.toasts.Tick()
		needTick := false
		if m.state == StateProcessing {
			m.status.SetStats(
				time.Since(m.processingStart),
				m.activity.ToolCount(),
				m.activity.InputTokens(),
				m.activity.OutputTokens(),
			)
			m.recomputeLayout()
			m.chat.SetProcessingView(m.activity.View())
			needTick = true
		}
		if m.toasts.HasToasts() {
			needTick = true
		}
		m.activity, _ = m.activity.Update(rawMsg)
		if needTick {
			cmds = append(cmds, m.tickCmd())
		}
		return m, tea.Batch(cmds...)

	// -- Dialog messages --

	case dialog.PlanDecision:
		return m.handlePlanDecision(v)

	case msg.ModelListResult:
		return m.handleModelList(v)

	case msg.ModelSwitchResult:
		return m.handleModelSwitch(v)

	case dialog.PickerChoice:
		return m.handlePickerChoice(v)

	case dialog.PickerCancel:
		m.picker.Clear()
		m.state = StateIdle
		return m, m.input.Focus()

	case dialog.PaletteExecuteMsg:
		m.state = StateIdle
		return m.submitInput(v.Command)

	case dialog.PaletteDismissMsg:
		m.state = StateIdle
		return m, m.input.Focus()

	// -- New dialog messages (Wave 4) --

	case dialog.PermissionDecision:
		return m.handlePermissionDecision(v)

	case dialog.SessionAction:
		return m.handleSessionAction(v)

	case dialog.ModelChoice:
		return m.handleModelsChoice(v)

	case dialog.ModelCancel:
		m.state = StateIdle
		return m, m.input.Focus()

	case dialog.QuitConfirmed:
		m.closeSSE()
		return m, tea.Quit

	case dialog.QuitCancelled:
		m.state = StateIdle
		m.confirmQuit = false
		return m, m.input.Focus()
	}

	// Forward to activity during processing (handles spinner ticks, etc.)
	if m.state == StateProcessing {
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}
