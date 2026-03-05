package app

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/msg"
)

// -- Swarm tea.Cmd builders ---------------------------------------------------

func (m Model) launchSwarm(task, pattern string) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		req := client.SwarmLaunchRequest{
			Task:      task,
			Pattern:   pattern,
			SessionID: sid,
		}
		resp, err := c.LaunchSwarm(req)
		if err != nil {
			return msg.SwarmLaunchResult{Err: err}
		}
		return msg.SwarmLaunchResult{
			SwarmID:    resp.SwarmID,
			Status:     resp.Status,
			Pattern:    resp.Pattern,
			AgentCount: resp.AgentCount,
		}
	}
}

func (m Model) listSwarms() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.ListSwarms()
		if err != nil {
			return msg.SwarmListResult{Err: err}
		}
		swarms := make([]msg.SwarmInfo, 0, len(resp.Swarms))
		for _, s := range resp.Swarms {
			swarms = append(swarms, msg.SwarmInfo{
				ID:         s.ID,
				Status:     s.Status,
				Pattern:    s.Pattern,
				AgentCount: s.AgentCount,
				StartedAt:  s.StartedAt,
			})
		}
		return msg.SwarmListResult{Swarms: swarms, ActiveCount: resp.ActiveCount}
	}
}

func (m Model) cancelSwarm(id string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		err := c.CancelSwarm(id)
		return msg.SwarmCancelResult{SwarmID: id, Err: err}
	}
}

// -- Swarm result handlers ----------------------------------------------------

func (m Model) handleSwarmLaunch(r msg.SwarmLaunchResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Swarm launch failed: %v", r.Err))
		return m, nil
	}
	m.chat.AddSystemMessage(fmt.Sprintf(
		"Swarm launched: %s (pattern: %s, %d agents) — ID: %s",
		r.Status, r.Pattern, r.AgentCount, shortID(r.SwarmID),
	))
	return m, nil
}

func (m Model) handleSwarmList(r msg.SwarmListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Failed to list swarms: %v", r.Err))
		return m, nil
	}
	if len(r.Swarms) == 0 {
		m.chat.AddSystemMessage("No swarms running.")
		return m, nil
	}
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("Swarms (%d active):\n", r.ActiveCount))
	for i, s := range r.Swarms {
		sb.WriteString(fmt.Sprintf("  %d. %s  %s  pattern:%s  agents:%d",
			i+1, shortID(s.ID), s.Status, s.Pattern, s.AgentCount,
		))
		if s.StartedAt != "" {
			sb.WriteString(fmt.Sprintf("  started:%s", s.StartedAt))
		}
		sb.WriteString("\n")
	}
	m.chat.AddSystemMessage(strings.TrimRight(sb.String(), "\n"))
	return m, nil
}

func (m Model) handleSwarmCancel(r msg.SwarmCancelResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Cancel failed: %v", r.Err))
		return m, nil
	}
	m.chat.AddSystemMessage(fmt.Sprintf("Swarm %s cancelled.", shortID(r.SwarmID)))
	return m, nil
}
