package app

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/msg"
)

const maxMessageSize = 100_000

func truncateResponse(s string) string {
	if len(s) > maxMessageSize {
		return s[:maxMessageSize] + "\n\n... (response truncated at 100KB)"
	}
	return s
}

func (m Model) fetchToolCount() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		tools, err := c.ListTools()
		if err != nil {
			return toolCountLoaded(0)
		}
		return toolCountLoaded(len(tools))
	}
}

func (m Model) tickCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return msg.TickMsg{} })
}

// shortID truncates an ID to 8 characters for display.
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// generateSessionID creates a time-based session ID with random suffix.
func generateSessionID(randBytes []byte) string {
	return fmt.Sprintf("tui_%d_%x", time.Now().UnixNano(), randBytes)
}
