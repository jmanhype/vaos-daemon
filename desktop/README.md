# OSA Desktop

> Your AI agent command center. Local-first. Zero config. Any OS.

OSA Desktop is the graphical interface for [OSA](https://github.com/Miosa-osa/OptimalSystemAgent) — an AI agent platform built on Elixir/OTP that runs on your machine, talks to 18 LLM providers, and gives you full control.

**Use it as:**
- A personal AI coding assistant (like Cursor, but local)
- A command center for multi-agent orchestration
- A template for building your own AI-powered desktop app
- An integration point for any existing command center or workflow

**Built with:** Tauri v2 + SvelteKit 2 + Svelte 5 | Dark glassmorphic UI | <10MB shell

---

## Install

### For You (Developer)

```bash
git clone https://github.com/Miosa-osa/osa-desktop.git
cd osa-desktop
./scripts/dev-setup.sh   # Installs Rust, Node, deps — handles everything
make dev                  # Launch with hot reload
```

### For Your Users / Clients

```bash
# macOS / Linux — one command, zero prerequisites
curl -fsSL https://osa.dev/install | sh
```

```powershell
# Windows — one command in PowerShell
irm https://osa.dev/install.ps1 | iex
```

### For Your Business / Team

Download from [Releases](https://github.com/Miosa-osa/osa-desktop/releases):

| Platform | Format | Size |
|----------|--------|------|
| macOS | `.dmg` | ~30MB |
| Windows | `.msi` | ~30MB |
| Linux | `.AppImage` / `.deb` | ~30MB |

Drag to Applications. Open. Pick a model. Done. No terminal. No config files.

### As a Template

Fork this repo and build your own AI command center on top of it. The architecture is modular:
- Swap the Elixir backend for any API server on localhost
- Use the 20 pre-built Svelte components (permissions, tasks, surveys, terminal, etc.)
- Plug into your existing tools via the command palette and settings system
- Ship as a branded desktop app with Tauri's cross-platform packaging

### Integrate With Anything

OSA Desktop connects to any backend on `localhost:8089` that speaks the OSA HTTP API. Use it as a frontend for:
- Your own AI agents
- Existing command centers and dashboards
- CI/CD pipelines and monitoring tools
- Any system that exposes a REST API + SSE streaming

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  Tauri v2 Shell (Rust, <10MB)               │
│  ┌───────────────────────────────────────┐  │
│  │  System WebView                       │  │
│  │  SvelteKit 2 + Svelte 5 (static SPA) │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  Sidecar: Elixir/OTP backend (:8089)        │
│  ├── Agent loop (GenServer)                 │
│  ├── SSE streaming                          │
│  ├── 18 LLM providers                       │
│  ├── GoldRush event routing                 │
│  └── Tool execution + permissions           │
│                                             │
│  System Tray: hide/show/quit                │
└─────────────────────────────────────────────┘
```

- **Frontend**: SvelteKit 2 with Svelte 5 runes, compiled to static SPA
- **Shell**: Tauri v2 — system WebView, <10MB bundle, native OS integration
- **Backend**: Elixir/OTP sidecar on localhost:8089, spawned and managed by Tauri
- **Streaming**: SSE (Server-Sent Events) via fetch, not EventSource
- **Theme**: Dark glassmorphic with Foundation design tokens

---

## Features

### Chat
- Real-time streaming with token-by-token display
- Markdown rendering with syntax-highlighted code blocks
- Thinking/reasoning blocks (collapsible)
- Tool call visualization with status indicators
- Auto-scroll with scroll-to-bottom FAB

### Agent Management
- Live agent dashboard with status, metrics, progress
- Multi-agent orchestration with wave tracking
- Task tracking cards with animated checkboxes
- Activity feed with verbosity levels (Off/New/All/Verbose)

### Permissions & Safety
- Permission dialog: Deny / Allow Always / Allow Once
- YOLO mode toggle (Cmd+Y) — auto-approve all tools
- Permission tiers: Full / Workspace / Read-only
- Plan review: Approve / Reject / Edit agent plans

### Interactive Flows
- Survey/QA dialogs with radio card selection
- Smooth slide transitions between questions
- Onboarding: 3-step zero-config (auto-detects Ollama, LM Studio, cloud APIs)

### Navigation
- Command palette (Cmd+K) with fuzzy search
- Session browser with rename, delete, search
- Model browser with provider grouping and one-click switch
- Embedded terminal (xterm.js)
- Settings: General, Provider, Permissions, Advanced, About

### Desktop Integration
- System tray with hide/show/quit
- Sidecar lifecycle management (spawn, health check, crash recovery)
- Native file dialogs (folder picker, save)
- Cross-platform: macOS, Windows, Linux

---

## Project Structure

```
osa-desktop/
├── src/
│   ├── routes/
│   │   ├── app/
│   │   │   ├── +layout.svelte      # App shell + overlays
│   │   │   ├── +page.svelte        # Chat (default)
│   │   │   ├── agents/             # Agent dashboard
│   │   │   ├── models/             # Model browser
│   │   │   ├── settings/           # Settings (5 tabs)
│   │   │   └── terminal/           # Embedded terminal
│   │   ├── chat/                   # Chat route
│   │   └── onboarding/             # Setup wizard
│   ├── lib/
│   │   ├── api/                    # HTTP client, SSE, types
│   │   ├── components/
│   │   │   ├── activity/           # Activity feed
│   │   │   ├── chat/               # Chat, messages, code blocks
│   │   │   ├── layout/             # Sidebar, title bar
│   │   │   ├── palette/            # Command palette
│   │   │   ├── permissions/        # Permission dialog + overlay
│   │   │   ├── plan/               # Plan review
│   │   │   ├── sessions/           # Session browser
│   │   │   ├── survey/             # Survey/QA dialog
│   │   │   └── tasks/              # Task tracking cards
│   │   ├── stores/                 # 12 Svelte 5 stores
│   │   ├── onboarding/             # Detection, validation, types
│   │   └── utils/                  # Platform detection
│   └── app.css                     # Glass theme tokens
├── src-tauri/
│   ├── src/
│   │   ├── lib.rs                  # App builder + plugins
│   │   ├── sidecar.rs              # Backend lifecycle
│   │   ├── commands.rs             # IPC (hardware, health, terminal)
│   │   └── tray.rs                 # System tray
│   ├── capabilities/default.json   # Plugin permissions
│   ├── Cargo.toml
│   └── tauri.conf.json
├── scripts/
│   ├── install.sh                  # macOS/Linux installer
│   ├── install.ps1                 # Windows installer
│   └── dev-setup.sh                # Developer setup
├── .github/workflows/
│   ├── build.yml                   # CI/CD matrix build + release
│   └── check.yml                   # PR gate (lint + typecheck)
├── Makefile
├── package.json
├── svelte.config.js
├── vite.config.ts
└── tsconfig.json
```

## Stats

| Metric | Value |
|--------|-------|
| SvelteKit source files | 61 |
| Svelte components | 20 |
| Svelte stores | 12 |
| Route pages | 7 |
| Rust source files | 5 |
| LLM providers supported | 18 |
| Bundle size (Tauri shell) | <10MB |

---

## Development

```bash
make dev          # Start Tauri dev mode (hot reload)
make check        # svelte-check + cargo check
make build        # Production build
make package      # Create distributable (.dmg/.msi/.AppImage)
make clean        # Remove build artifacts
```

### Prerequisites

- **Rust** (1.75+) — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Node.js** (20+) — `brew install node` or `fnm install 20`
- **OSA Backend** — the Elixir backend must be available as a sidecar binary or running on :8089

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Command palette |
| Cmd+Y | Toggle YOLO mode |
| Cmd+\\ | Toggle sidebar |
| Cmd+, | Settings |
| Cmd+1-5 | Navigate tabs |
| Ctrl+Shift+S | Session browser |
| Enter | Send message |
| Shift+Enter | New line |

---

## License

Proprietary. Copyright 2026 MIOSA Inc.
