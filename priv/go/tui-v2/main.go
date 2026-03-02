package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
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

	// Debug log for diagnosing silent exits.
	logDir := filepath.Join(home, ".osa", "logs")
	os.MkdirAll(logDir, 0755)
	logFile, logErr := os.OpenFile(filepath.Join(logDir, "tui.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if logErr == nil {
		log.SetOutput(logFile)
		defer logFile.Close()
	}
	log.Printf("osagent starting: baseURL=%s profile=%q profileDir=%s", baseURL, profile, app.ProfileDir)

	token, refreshToken = loadTokens(app.ProfileDir, token)
	log.Printf("tokens loaded: hasToken=%v hasRefresh=%v", token != "", refreshToken != "")

	// Auto-detect terminal background and set theme before any rendering.
	log.Printf("detecting terminal background...")
	if lipgloss.HasDarkBackground(os.Stdin, os.Stdout) {
		style.SetTheme("dark")
		log.Printf("theme: dark")
	} else {
		style.SetTheme("light")
		log.Printf("theme: light")
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

	log.Printf("creating tea.Program...")
	p := tea.NewProgram(m)

	go func() {
		p.Send(app.ProgramReady{Program: p})
	}()

	log.Printf("calling p.Run()...")
	if _, err := p.Run(); err != nil {
		log.Printf("p.Run() error: %v", err)
		fmt.Fprintf(os.Stderr, "osa: %v\n", err)
		os.Exit(1)
	}
	log.Printf("p.Run() returned cleanly")
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
