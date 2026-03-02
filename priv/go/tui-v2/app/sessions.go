package app

import (
	"fmt"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/ui/chat"
	"github.com/miosa/osa-tui/ui/dialog"
)

// -- Model selection ---------------------------------------------------------

func (m Model) handleModelList(r msg.ModelListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Failed to list models: %v", r.Err))
		return m, m.input.Focus()
	}
	if len(r.Models) == 0 {
		m.chat.AddSystemWarning(fmt.Sprintf(
			"No models available. Current: %s. Is Ollama running?", m.header.ModelName(),
		))
		return m, m.input.Focus()
	}

	filter := m.pendingProviderFilter
	m.pendingProviderFilter = ""

	var items []dialog.PickerItem
	for _, entry := range r.Models {
		if filter != "" && strings.ToLower(entry.Provider) != filter {
			continue
		}
		items = append(items, dialog.PickerItem{
			Name:     entry.Name,
			Provider: entry.Provider,
			Size:     entry.Size,
			Active:   entry.Active,
		})
	}

	if len(items) == 0 {
		m.chat.AddSystemError(fmt.Sprintf(
			"No models available for provider: %s. Is the API key configured?", filter,
		))
		return m, m.input.Focus()
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].Provider != items[j].Provider {
			return items[i].Provider < items[j].Provider
		}
		return items[i].Name < items[j].Name
	})

	m.picker.SetWidth(m.width - 4)
	m.picker.SetItems(items)
	m.state = StateModelPicker
	m.input.Blur()
	return m, nil
}

func (m Model) handleModelSwitch(r msg.ModelSwitchResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Switch failed: %v", r.Err))
		return m, nil
	}
	m.status.SetProviderInfo(r.Provider, r.Model)
	m.header.SetModelOverride(r.Provider, r.Model)
	m.sidebar.SetModelInfo(r.Provider, r.Model)
	m.chat.AddSystemMessage(fmt.Sprintf("Switched to %s / %s", r.Provider, r.Model))
	return m, m.checkHealth()
}

func (m Model) handlePickerChoice(c dialog.PickerChoice) (Model, tea.Cmd) {
	m.picker.Clear()
	m.state = StateIdle
	m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", c.Provider, c.Name))
	return m, tea.Batch(m.input.Focus(), m.switchModel(c.Provider, c.Name))
}

func (m Model) fetchModels() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.ListModels()
		if err != nil {
			return msg.ModelListResult{Err: err}
		}
		var models []msg.ModelEntry
		for _, entry := range resp.Models {
			models = append(models, msg.ModelEntry{
				Name:     entry.Name,
				Provider: entry.Provider,
				Size:     entry.Size,
				Active:   entry.Active,
			})
		}
		return msg.ModelListResult{Models: models, Current: resp.Current, Provider: resp.Provider}
	}
}

func (m Model) switchModel(provider, modelName string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.SwitchModel(client.ModelSwitchRequest{Provider: provider, Model: modelName})
		if err != nil {
			return msg.ModelSwitchResult{Err: err}
		}
		return msg.ModelSwitchResult{Provider: resp.Provider, Model: resp.Model}
	}
}

// -- Session management -------------------------------------------------------

func (m Model) listSessions() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		sessions, err := c.ListSessions()
		if err != nil {
			return msg.SessionListResult{Err: err}
		}
		var result []msg.SessionInfo
		for _, s := range sessions {
			result = append(result, msg.SessionInfo{
				ID:           s.ID,
				CreatedAt:    s.CreatedAt,
				Title:        s.Title,
				MessageCount: s.MessageCount,
			})
		}
		return msg.SessionListResult{Sessions: result}
	}
}

func (m Model) createSession() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.CreateSession()
		if err != nil {
			return msg.SessionSwitchResult{Err: err}
		}
		return msg.SessionSwitchResult{SessionID: resp.ID}
	}
}

func (m Model) switchSession(id string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		info, err := c.GetSession(id)
		if err != nil {
			return msg.SessionSwitchResult{Err: err}
		}
		messages := info.Messages
		if len(messages) == 0 {
			fetched, err := c.GetSessionMessages(id)
			if err == nil {
				messages = fetched
			}
		}
		var result []msg.SessionMessage
		for _, sm := range messages {
			result = append(result, msg.SessionMessage{
				Role:      sm.Role,
				Content:   sm.Content,
				Timestamp: sm.Timestamp,
			})
		}
		return msg.SessionSwitchResult{SessionID: info.ID, Messages: result}
	}
}

func (m Model) handleSessionList(r msg.SessionListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Session list error: %v", r.Err))
		return m, nil
	}
	if len(r.Sessions) == 0 {
		m.chat.AddSystemMessage("No sessions found.")
		return m, nil
	}
	var sb strings.Builder
	sb.WriteString("Sessions:\n")
	for i, s := range r.Sessions {
		title := s.Title
		if title == "" {
			title = "(untitled)"
		}
		sb.WriteString(fmt.Sprintf("  %d. %s — %s (%d messages)\n",
			i+1, shortID(s.ID), title, s.MessageCount,
		))
	}
	m.chat.AddSystemMessage(strings.TrimRight(sb.String(), "\n"))
	return m, nil
}

func (m Model) handleSessionSwitch(r msg.SessionSwitchResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Session error: %v", r.Err))
		return m, nil
	}
	m.closeSSE()
	m.sessionID = r.SessionID
	m.chat = chat.New(m.layout.ChatWidth, m.layout.ChatHeight)
	m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())

	if len(r.Messages) > 0 {
		for _, sm := range r.Messages {
			switch sm.Role {
			case "user":
				m.chat.AddUserMessage(sm.Content)
			case "assistant":
				m.chat.AddAgentMessage(sm.Content, nil, 0, "")
			default:
				m.chat.AddSystemMessage(sm.Content)
			}
		}
		m.chat.AddSystemMessage(fmt.Sprintf(
			"--- Resumed session %s (%d messages) ---", shortID(r.SessionID), len(r.Messages),
		))
	} else {
		m.chat.AddSystemMessage(fmt.Sprintf("Switched to session %s", shortID(r.SessionID)))
	}

	var cmds []tea.Cmd
	cmds = append(cmds, m.input.Focus())
	if m.program != nil {
		if cmd := m.startSSE(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return m, tea.Batch(cmds...)
}


func (m Model) handleSessionAction(a dialog.SessionAction) (Model, tea.Cmd) {
	m.state = StateIdle
	switch a.Action {
	case "switch":
		return m, tea.Batch(m.input.Focus(), m.switchSession(a.SessionID))
	case "create":
		return m, tea.Batch(m.input.Focus(), m.createSession())
	case "rename":
		m.chat.AddSystemMessage(fmt.Sprintf("Renamed session %s → %s", shortID(a.SessionID), a.NewName))
		return m, m.input.Focus()
	case "delete":
		m.chat.AddSystemMessage(fmt.Sprintf("Deleted session %s", shortID(a.SessionID)))
		return m, m.input.Focus()
	}
	return m, m.input.Focus()
}

func (m Model) handleModelsChoice(c dialog.ModelChoice) (Model, tea.Cmd) {
	m.state = StateIdle
	m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", c.Provider, c.Model))
	return m, tea.Batch(m.input.Focus(), m.switchModel(c.Provider, c.Model))
}

