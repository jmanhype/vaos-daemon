# OSA Desktop

> Your AI agent, running locally on your machine.

OSA Desktop is the native GUI for [OSA](https://github.com/Miosa-osa/OptimalSystemAgent) — an Elixir/OTP AI agent platform. It runs on your machine, connects to a local OSA backend, and gives you full control over multi-agent orchestration, 18 LLM providers, memory, scheduling, and knowledge graphs. No cloud required.

**Built with:** Tauri v2 + SvelteKit 2 + Svelte 5 | Dark glassmorphic UI | <10MB shell

---

## Install & Run

### Prerequisites

- **Elixir** 1.17+ / OTP 27+ — the OSA backend
- **Node.js** 22+ — the desktop frontend
- **Rust** 1.75+ — only needed for native Tauri builds

### One Command (recommended)

From the project root:

```bash
./dev.sh               # Starts backend (:9089) + frontend (:5199) together
./dev.sh --tauri       # Same, but opens as a native Tauri window
```

Open **http://localhost:5199** and you're in.

### Manual Setup

```bash
# 1. Backend
mix deps.get
mix osa.serve                    # Elixir backend on :9089

# 2. Frontend (separate terminal)
cd desktop
npm install
npm run dev                      # Browser mode on :5199
npm run tauri:dev                # Or native desktop mode
```

### Production Build

```bash
cd desktop
npm run tauri:build              # .dmg / .msi / .AppImage
```

---

## Architecture

```
OSA Desktop (Tauri v2 shell, <10MB)
  |
  |  SvelteKit 2 + Svelte 5 (static SPA, system WebView)
  |
  |  HTTP + SSE
  v
OSA Backend (Elixir/OTP, localhost:9089)
  |- Agent loop (GenServer)
  |- 18 LLM providers, 3 compute tiers
  |- Multi-agent orchestration + swarms
  |- Memory, Vault, Knowledge graph
  |- Scheduler (cron + heartbeat)
  |- SSE streaming per session
```

The frontend is a compiled static SPA embedded in the Tauri shell. It communicates with the OSA backend exclusively over localhost — no external network calls from the shell layer.

---

## Pages

| Page | Route | Description |
|------|-------|-------------|
| Chat | `/app` | Streaming chat with token display, tool call visualization, thinking blocks |
| Agents | `/app/agents` | Live agent dashboard, multi-agent orchestration, task tracking |
| Models | `/app/models` | Model browser, provider grouping, one-click model switch |
| Terminal | `/app/terminal` | Embedded terminal (xterm.js) |
| Connectors | `/app/connectors` | Configure channel integrations (Slack, Telegram, Discord, etc.) |
| Settings | `/app/settings` | General, Provider, Permissions, Advanced, About |
| Activity Logs | `/app/activity` | Real-time event feed with verbosity controls |
| Usage & Analytics | `/app/usage` | Token usage, cost tracking, session metrics |
| Memory Vault | `/app/memory` | Browse and manage structured Vault memory (facts, decisions, lessons) |
| Scheduled Tasks | `/app/tasks` | Cron job management, trigger scheduling, one-click execution |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Command palette |
| Cmd+1 | Chat |
| Cmd+2 | Agents |
| Cmd+3 | Models |
| Cmd+4 | Terminal |
| Cmd+5 | Connectors |
| Cmd+6 | Settings |
| Cmd+7 | Activity Logs |
| Cmd+8 | Usage & Analytics |
| Cmd+9 | Memory Vault |
| Cmd+0 | Scheduled Tasks |
| Cmd+Y | Toggle YOLO mode (auto-approve all tool calls) |
| Cmd+\ | Toggle sidebar |
| Cmd+, | Settings |
| Enter | Send message |
| Shift+Enter | New line |

---

## Project Structure

```
desktop/
├── src/
│   ├── routes/
│   │   ├── app/
│   │   │   ├── +layout.svelte      # App shell + overlays
│   │   │   ├── +page.svelte        # Chat (default)
│   │   │   ├── agents/             # Agent dashboard
│   │   │   ├── connectors/         # Channel integrations
│   │   │   ├── memory/             # Memory Vault browser
│   │   │   ├── models/             # Model browser
│   │   │   ├── settings/           # Settings (5 tabs)
│   │   │   ├── terminal/           # Embedded terminal
│   │   │   └── usage/              # Usage & analytics
│   │   └── onboarding/             # Setup wizard
│   ├── lib/
│   │   ├── api/                    # HTTP client, SSE, types
│   │   ├── components/             # 20 Svelte components
│   │   ├── stores/                 # 12 Svelte 5 stores
│   │   └── utils/                  # Platform detection
│   └── app.css                     # Glass theme tokens
├── src-tauri/
│   ├── src/
│   │   ├── lib.rs                  # App builder + plugins
│   │   ├── sidecar.rs              # Backend lifecycle
│   │   ├── commands.rs             # IPC (hardware, health, terminal)
│   │   └── tray.rs                 # System tray
│   └── tauri.conf.json
├── Makefile
└── package.json
```

---

## License

Proprietary. Copyright 2026 MIOSA Inc.
