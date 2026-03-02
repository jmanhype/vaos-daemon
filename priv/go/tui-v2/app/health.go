package app

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/ui/dialog"
)

// -- Health -------------------------------------------------------------------

func (m Model) handleHealth(h msg.HealthResult) (Model, tea.Cmd) {
	if h.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Backend unreachable: %v -- retrying in 5s", h.Err))
		m.state = StateConnecting
		return m, tea.Tick(5*time.Second, func(time.Time) tea.Msg { return retryHealth{} })
	}

	m.header.SetHealth(h)
	m.status.SetProviderInfo(h.Provider, h.Model)
	m.sidebar.SetModelInfo(h.Provider, h.Model)
	m.state = StateBanner

	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		b = []byte{0, 0, 0, 0}
	}
	m.sessionID = generateSessionID(b)

	m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
	m.recomputeLayout()

	var cmds []tea.Cmd
	cmds = append(cmds, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return bannerTimeout{} }))

	// Auto-login when no token exists (local/Ollama usage).
	// Defer commands/tools fetch until after login so the token is available.
	if m.client.Token == "" {
		cmds = append(cmds, m.doLogin("local"))
	} else {
		cmds = append(cmds, m.fetchCommands(), m.fetchToolCount())
		if m.program != nil {
			if cmd := m.startSSE(); cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
	}
	return m, tea.Batch(cmds...)
}

// -- Auth helpers -------------------------------------------------------------

func (m Model) doLogin(userID string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.Login(userID)
		if err != nil {
			return msg.LoginResult{Err: err}
		}
		pd := profileDirPath()
		if pd != "" {
			if err := os.MkdirAll(pd, 0o755); err != nil {
				return msg.LoginResult{Err: fmt.Errorf("create profile dir: %w", err)}
			}
			if err := os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0o600); err != nil {
				return msg.LoginResult{Token: resp.Token, Err: fmt.Errorf("save token: %w", err)}
			}
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0o600)
			}
		}
		return msg.LoginResult{Token: resp.Token, RefreshToken: resp.RefreshToken, ExpiresIn: resp.ExpiresIn}
	}
}

func (m Model) doRefreshToken(refreshToken string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.RefreshToken(refreshToken)
		if err != nil {
			return refreshTokenResult{err: err}
		}
		pd := profileDirPath()
		if pd != "" {
			_ = os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0o600)
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0o600)
			}
		}
		return refreshTokenResult{
			token:        resp.Token,
			refreshToken: resp.RefreshToken,
			expiresIn:    resp.ExpiresIn,
		}
	}
}

func (m Model) handleRefreshTokenResult(r refreshTokenResult) (Model, tea.Cmd) {
	if r.err != nil {
		m.chat.AddSystemWarning("Session expired. Use /login to re-authenticate.")
		m.state = StateIdle
		return m, m.input.Focus()
	}
	m.client.SetToken(r.token)
	m.refreshToken = r.refreshToken
	if m.program != nil && m.sessionID != "" {
		return m, m.startSSE()
	}
	return m, nil
}

func (m Model) doLogout() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		err := c.Logout()
		pd := profileDirPath()
		if pd != "" {
			os.Remove(filepath.Join(pd, "token"))
		}
		return msg.LogoutResult{Err: err}
	}
}

// -- Health check ------------------------------------------------------------

func (m Model) checkHealth() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		health, err := c.Health()
		if err != nil {
			return msg.HealthResult{Err: err}
		}
		return msg.HealthResult{
			Status:   health.Status,
			Version:  health.Version,
			Provider: health.Provider,
			Model:    health.Model,
		}
	}
}

// -- Onboarding commands -----------------------------------------------------

func (m Model) checkOnboarding() tea.Cmd {
	return func() tea.Msg {
		result, err := m.client.CheckOnboarding()
		if err != nil {
			return msg.OnboardingStatusResult{Err: err}
		}
		providers := make([]msg.OnboardingProvider, len(result.Providers))
		for i, p := range result.Providers {
			providers[i] = msg.OnboardingProvider{
				Key:          p.Key,
				Name:         p.Name,
				DefaultModel: p.DefaultModel,
				EnvVar:       p.EnvVar,
			}
		}
		templates := make([]msg.OnboardingTemplate, len(result.Templates))
		for i, t := range result.Templates {
			templates[i] = msg.OnboardingTemplate{
				Name:    t.Name,
				Path:    t.Path,
				Stack:   t.Stack,
				Modules: t.Modules,
			}
		}
		machines := make([]msg.OnboardingMachine, len(result.Machines))
		for i, mach := range result.Machines {
			machines[i] = msg.OnboardingMachine{
				Key:         mach.Key,
				Name:        mach.Name,
				Description: mach.Description,
			}
		}
		channels := make([]msg.OnboardingChannel, len(result.Channels))
		for i, ch := range result.Channels {
			channels[i] = msg.OnboardingChannel{
				Key:         ch.Key,
				Name:        ch.Name,
				Description: ch.Description,
			}
		}
		return msg.OnboardingStatusResult{
			NeedsOnboarding: result.NeedsOnboarding,
			Providers:       providers,
			Templates:       templates,
			Machines:        machines,
			Channels:        channels,
			SystemInfo:      result.SystemInfo,
		}
	}
}

func (m Model) completeOnboarding(done dialog.OnboardingDone) tea.Cmd {
	return func() tea.Msg {
		result, err := m.client.CompleteOnboarding(client.OnboardingSetupRequest{
			Provider:    done.Provider,
			Model:       done.Model,
			APIKey:      done.APIKey,
			EnvVar:      done.EnvVar,
			AgentName:   done.AgentName,
			UserName:    done.UserName,
			UserContext: done.UserContext,
			Machines:    done.Machines,
			Channels:    convertChannels(done.Channels),
			OSTemplate:  done.OSTemplate,
		})
		if err != nil {
			return msg.OnboardingSetupError{Err: err}
		}
		return msg.OnboardingComplete{
			Provider: result.Provider,
			Model:    result.Model,
		}
	}
}

// convertChannels builds the channel config map for the setup request.
func convertChannels(keys []string) map[string]any {
	if len(keys) == 0 {
		return nil
	}
	result := make(map[string]any, len(keys))
	for _, k := range keys {
		result[k] = map[string]any{"enabled": true}
	}
	return result
}
