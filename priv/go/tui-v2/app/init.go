package app

import tea "charm.land/bubbletea/v2"

// -- Init ---------------------------------------------------------------------

func (m Model) Init() tea.Cmd {
	return tea.Batch(m.checkHealth(), m.input.Focus(), func() tea.Msg { return tea.RequestWindowSize() })
}
