package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/miosa/osa-tui/app"
	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/style"
)

var version = "dev"

func main() {
	profileFlag := flag.String("profile", "", "Named profile for state isolation (~/.osa/profiles/<name>)")
	devFlag := flag.Bool("dev", false, "Dev mode (alias for --profile dev, port 19001)")
	setupFlag := flag.Bool("setup", false, "Open setup wizard on launch (re-configure provider, agent, etc.)")
	noColor := flag.Bool("no-color", false, "Disable ANSI colors")
	showVersion := flag.Bool("version", false, "Show version and exit")
	flag.BoolVar(showVersion, "V", false, "Show version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("osa %s\n", version)
		os.Exit(0)
	}

	if *noColor {
		os.Setenv("NO_COLOR", "1")
	}

	baseURL := os.Getenv("OSA_URL")
	if baseURL == "" {
		baseURL = "http://localhost:8089"
	}
	token := os.Getenv("OSA_TOKEN")

	profile := *profileFlag
	if *devFlag {
		profile = "dev"
		if baseURL == "http://localhost:8089" {
			baseURL = "http://localhost:19001"
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "osa: cannot determine home directory: %v\n", err)
		os.Exit(1)
	}

	var refreshToken string

	if profile != "" {
		app.ProfileDir = filepath.Join(home, ".osa", "profiles", profile)
	} else {
		app.ProfileDir = filepath.Join(home, ".osa")
	}
	os.MkdirAll(app.ProfileDir, 0755)

	token, refreshToken = loadTokens(app.ProfileDir, token)

	// Auto-detect terminal background and set theme before any rendering.
	// On Windows the OSC escape query sent by HasDarkBackground corrupts the
	// raw-mode input stream, making the TUI completely unusable (Bug 26).
	// Skip the query on Windows and default to the dark theme instead.
	if runtime.GOOS == "windows" {
		style.SetTheme("dark")
	} else if lipgloss.HasDarkBackground(os.Stdin, os.Stdout) {
		style.SetTheme("dark")
	} else {
		style.SetTheme("light")
	}

	c := client.New(baseURL)
	if token != "" {
		c.SetToken(token)
	}

	m := app.New(c)
	if refreshToken != "" {
		m.SetRefreshToken(refreshToken)
	}
	if *setupFlag {
		m.SetForceOnboarding(true)
	}

	p := tea.NewProgram(m)

	go func() {
		p.Send(app.ProgramReady{Program: p})
	}()

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "osa: %v\n", err)
		os.Exit(1)
	}
}

// loadTokens reads token and refresh_token files from the profile directory.
// If envToken is non-empty it takes precedence over the file-based token.
func loadTokens(dir, envToken string) (token, refreshToken string) {
	token = envToken
	if token == "" {
		if data, err := os.ReadFile(filepath.Join(dir, "token")); err == nil {
			token = strings.TrimSpace(string(data))
		}
	}
	if data, err := os.ReadFile(filepath.Join(dir, "refresh_token")); err == nil {
		refreshToken = strings.TrimSpace(string(data))
	}
	return
}
