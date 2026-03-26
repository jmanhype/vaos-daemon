# Daemon Desktop Command Center

The Daemon Desktop Command Center is a cross-platform desktop application built with Tauri 2 and SvelteKit 5. It provides a native window around the Daemon agent system, bundling the Elixir backend as a sidecar process and exposing a dark-themed UI for chat, terminal access, agent monitoring, model management, and settings.

## What It Is

The app is a Tauri 2 shell (`identifier: ai.osa.desktop`) that loads a statically-built SvelteKit 5 frontend at startup. When the window opens, the Rust layer spawns the Daemon Elixir backend (`binaries/daemon`) as a child process on port 9089. The SvelteKit frontend communicates exclusively over HTTP and Server-Sent Events (SSE) to that local backend — there is no direct Tauri IPC for data, only for system-level operations (health checks, restart, hardware detection, terminal launch).

```
┌────────────────────────────────────────────────────────────────┐
│  macOS / Windows / Linux                                        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Tauri Shell  (src-tauri/)                               │  │
│  │                                                          │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │  SvelteKit 5 Frontend  (src/)                    │   │  │
│  │  │                                                  │   │  │
│  │  │  Chat · Agents · Models · Terminal · Settings   │   │  │
│  │  └──────────┬───────────────────────────────────────┘   │  │
│  │             │  HTTP + SSE  (127.0.0.1:9089)             │  │
│  │  ┌──────────▼───────────────────────────────────────┐   │  │
│  │  │  Elixir Sidecar  (binaries/daemon)              │   │  │
│  │  │  DAEMON_HTTP_PORT=9089  DAEMON_HEADLESS=true           │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## How It Connects to the Backend

The Tauri shell spawns `daemon` with three environment variables:

```
DAEMON_HTTP_PORT=9089
DAEMON_LOG_LEVEL=warn
DAEMON_HEADLESS=true
```

Startup is non-blocking: the main window is shown immediately while the sidecar starts in the background. The Rust layer polls `http://127.0.0.1:9089/health` with exponential backoff (100 ms initial, doubling to 2 s max) for up to 30 seconds, then emits either `backend-ready` or `backend-unavailable` to the frontend via Tauri events.

In development, if port 9089 is already in use (e.g., a manually-started backend), the sidecar spawn is skipped entirely and the existing process is used.

## Key Features

**Chat with streaming.** The chat route sends messages over SSE using a two-step protocol: open a GET stream on `/api/v1/sessions/:id/stream`, then POST the message to `/api/v1/sessions/:id/message`. Tokens, thinking blocks, tool calls, and results all arrive as typed SSE events.

**Permission dialogs.** When the agent wants to run a tool (bash, file write, etc.), the backend emits a `tool_call` event with `phase: "awaiting_permission"`. The frontend shows a modal, collects the user's decision (allow / allow always / deny), and POSTs it back to `/api/v1/sessions/:id/tool_calls/:tool_use_id/decision`.

**YOLO mode.** A toggle that auto-approves all tool permission requests without showing dialogs. Activated via `⌘Y` or the command palette.

**Embedded terminal.** The terminal route hosts an xterm.js instance that submits commands to `/api/v1/tools/shell_execute/execute` and renders stdout/stderr inline. Has full readline emulation: history (up/down), Ctrl+A/E/K/U/W, Ctrl+F search overlay.

**Onboarding.** First-run wizard (3 steps) detects local providers (Ollama, LM Studio), collects an API key if needed, and sets the working directory.

**System tray.** The app hides to the tray on window close rather than quitting. The tray menu offers: Open Dashboard, Open Terminal (launches `osa-tui` in a native terminal window), and Quit Daemon.

**Command palette.** `⌘K` opens a global command palette registered with nav shortcuts, new session, clear chat, YOLO toggle, and backend restart.

## Directory Layout

```
desktop/
├── src/                        # SvelteKit 5 frontend
│   ├── lib/
│   │   ├── api/                # HTTP client, SSE client, API types
│   │   └── stores/             # Svelte 5 $state stores (18 files)
│   │       ├── chat.svelte.ts
│   │       ├── permissions.svelte.ts
│   │       ├── sessions.svelte.ts
│   │       ├── connection.svelte.ts
│   │       ├── agents.svelte.ts
│   │       ├── tasks.svelte.ts
│   │       ├── survey.svelte.ts
│   │       ├── theme.svelte.ts
│   │       └── ...
│   │   └── components/         # Svelte components
│   └── routes/                 # SvelteKit routes
│       ├── +layout.svelte      # Root layout — initializeAuth
│       ├── app/
│       │   ├── +layout.svelte  # App shell — SSE dispatcher, keyboard shortcuts
│       │   ├── +page.svelte    # Chat (main view)
│       │   ├── agents/
│       │   ├── terminal/
│       │   ├── models/
│       │   ├── connectors/
│       │   ├── settings/
│       │   ├── activity/
│       │   ├── memory/
│       │   ├── tasks/
│       │   └── usage/
│       ├── chat/               # Standalone chat route
│       └── onboarding/         # First-run wizard
├── src-tauri/                  # Tauri 2 / Rust layer
│   ├── src/
│   │   ├── lib.rs              # App builder, plugin registration
│   │   ├── commands.rs         # 7 IPC commands
│   │   ├── sidecar.rs          # Elixir sidecar lifecycle
│   │   └── tray.rs             # System tray setup
│   └── tauri.conf.json
├── package.json
└── vite.config.ts
```

## Quick Start

See [development.md](./development.md) for full setup instructions.

```bash
cd desktop
npm install
npm run tauri:dev
```

The dev server runs SvelteKit on port 5199 with Vite HMR. The Tauri shell opens a native window pointing to that dev server.
