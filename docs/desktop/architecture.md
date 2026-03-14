# Desktop Architecture

## Overview

The desktop app is a Tauri 2 application (`identifier: ai.osa.desktop`, version `0.1.0`). The Rust host and the SvelteKit frontend are separate processes connected through Tauri's WebView IPC for system commands, and through plain HTTP+SSE for all data operations.

The window starts hidden (`"visible": false` in `tauri.conf.json`) and is shown programmatically once the sidecar lifecycle has been handed off to a background task. This keeps cold start time under control even if the Elixir backend takes several seconds to initialize.

## Tauri 2 Integration (`src-tauri/`)

### `lib.rs` — App Builder

`src-tauri/src/lib.rs` is the entry point called by `main.rs`. It:

1. Registers plugins: `shell`, `notification`, `dialog`, `process`, `os`, `fs`. The `updater` plugin is present but commented out pending signing key configuration.
2. Registers 7 IPC commands via `tauri::generate_handler!`.
3. Manages one piece of shared state: `SidecarState(Mutex<Option<CommandChild>>)`, which holds the live sidecar process handle.
4. In `.setup()`, calls `tray::setup_tray()` synchronously, then spawns the sidecar lifecycle on the Tokio async runtime in a non-blocking task.
5. In `.on_window_event()`, intercepts `CloseRequested` to kill the sidecar process and hide the window to the tray instead of quitting.

The window is hidden on quit, not destroyed. A real exit happens only via the tray "Quit OSA" menu item or `app.exit(0)`.

### `sidecar.rs` — Elixir Sidecar Lifecycle

Constants:

```rust
pub const BACKEND_PORT: u16 = 9089;
pub const HEALTH_URL: &str  = "http://127.0.0.1:9089/health";
pub static SIDECAR_RUNNING: AtomicBool = AtomicBool::new(false);
```

`start_sidecar(app)` flow:

1. Show the main window immediately (`window.show()` + `window.set_focus()`).
2. Check if port 9089 is already responding (`port_in_use()`). If yes, set `SIDECAR_RUNNING = true`, emit `backend-ready`, and return — this is the dev-mode path.
3. Spawn `shell.sidecar("osagent")` with env vars `OSA_HTTP_PORT`, `OSA_LOG_LEVEL=warn`, `OSA_HEADLESS=true` and args `["serve", "--port", "9089"]`.
4. Store the `CommandChild` handle in `SidecarState`.
5. Spawn a log monitor thread (via `std::thread::spawn` + a single-threaded Tokio runtime) that reads `CommandEvent::Stdout`, `Stderr`, and `Terminated` from the sidecar's output channel. On `Terminated`, sets `SIDECAR_RUNNING = false` and emits `backend-crashed`.
6. Call `wait_for_healthy(30)` — exponential backoff from 100 ms to 2 s, timeout 30 seconds. On success emits `backend-ready`. On timeout emits `backend-unavailable` and continues (app remains usable in offline mode).

The sidecar binary must be placed at `binaries/osagent` (declared in `tauri.conf.json` under `bundle.externalBin`).

Health check backoff sequence: 100 ms, 200 ms, 400 ms, 800 ms, 1.6 s, 2 s (capped), 2 s, ...

### `commands.rs` — The 7 IPC Commands

All commands are registered in `lib.rs` and callable from the frontend via `@tauri-apps/api`.

| Command | Signature | Description |
|---|---|---|
| `get_backend_url` | `() -> String` | Returns `http://127.0.0.1:9089` |
| `check_backend_health` | `async () -> Result<bool>` | GETs `/health`, updates `SIDECAR_RUNNING` |
| `restart_backend` | `async (app) -> Result<()>` | Calls `start_sidecar` again |
| `detect_hardware` | `() -> Result<HardwareInfo>` | CPU brand/cores, RAM bytes, GPU name (platform-specific) |
| `get_platform` | `() -> PlatformInfo` | OS and arch strings from `std::env::consts` |
| `open_terminal` | `(app) -> Result<()>` | Launches `osa-tui` in native terminal emulator |
| `get_app_version` | `() -> String` | Reads `CARGO_PKG_VERSION` |

`HardwareInfo` detection is platform-specific:
- macOS: `sysctl -n machdep.cpu.brand_string`, `hw.memsize`, `system_profiler SPDisplaysDataType`
- Linux: `/proc/cpuinfo`, `/proc/meminfo`, `lspci`
- Windows: `wmic cpu/os/win32_videocontroller`

`open_terminal` launch strategies:
- macOS: `open -a Terminal --args osa-tui`
- Linux: `x-terminal-emulator -e osa-tui`, fallback to `xterm`
- Windows: `cmd /c start osa-tui`

### `tray.rs` — System Tray

Menu items: **Open Dashboard**, **Open Terminal**, separator, **Status: Starting...** (disabled, informational), **Quit OSA**.

Left-click on the tray icon toggles window visibility (show/hide). Right-click shows the menu.

The `open_terminal` tray item calls `commands::launch_terminal_inner` via `tauri::async_runtime::spawn`.

On macOS, `icon_as_template(true)` is set so the icon adapts automatically to dark/light menu bar mode.

## SvelteKit Frontend (`src/`)

### Route Structure

```
routes/
├── +layout.svelte          Root layout — calls initializeAuth() on mount
├── +page.ts                Redirects to /onboarding or /app based on status
├── app/
│   ├── +layout.svelte      App shell: sidebar, permission overlay, SSE dispatcher
│   ├── +page.svelte        Chat page (main view)
│   ├── agents/+page.svelte  Agent tree and status
│   ├── terminal/+page.svelte xterm.js terminal
│   ├── models/+page.svelte  Model browser and activation
│   ├── connectors/+page.svelte Provider connections
│   ├── settings/+page.svelte  App settings
│   ├── activity/+page.svelte  Activity feed / audit log
│   ├── memory/+page.svelte   Memory browser
│   ├── tasks/+page.svelte    Task tracker
│   └── usage/+page.svelte    Token usage / cost tracking
├── chat/+page.svelte       Standalone chat (deep-linkable)
└── onboarding/
    ├── +page.svelte        Step orchestrator (3 steps + complete)
    └── steps/
        ├── StepProvider.svelte
        ├── StepApiKey.svelte
        ├── StepDirectory.svelte
        └── StepComplete.svelte
```

### App Layout — SSE Event Dispatcher

`src/routes/app/+layout.svelte` is the central event router. It registers a stream listener on `chatStore` via `chatStore.addStreamListener(dispatchStreamEvent)` in `onMount`. Every raw SSE event passes through `dispatchStreamEvent` before the chat store processes it:

- `tool_call` with `phase: "awaiting_permission"` → routed to `permissionStore.handleToolCallEvent()`, which shows the dialog and POSTs the decision back to `/api/v1/sessions/:id/tool_calls/:tool_use_id/decision`.
- `system_event` with `event: "survey_shown"` → routed to `surveyStore.showSurvey()`.
- `system_event` with `event: "task_created"` → routed to `taskStore.addTask()`.
- `system_event` with `event: "task_updated"` → routed to `taskStore.updateTask()`.

The layout also registers a `window.addEventListener('osa:send-message')` listener so any component can fire a custom DOM event to send a chat message and navigate to `/app`.

### Keyboard Shortcuts (registered in app layout)

| Shortcut | Action |
|---|---|
| `⌘K` | Open command palette |
| `⌘\` | Toggle sidebar collapsed |
| `⌘,` | Navigate to settings |
| `⌘Y` | Toggle YOLO mode |
| `⌘1`–`⌘0` | Navigate to routes: app, agents, models, terminal, connectors, settings, activity, usage, memory, tasks |

## Sidecar Management Detail

The sidecar child process handle is stored in `SidecarState(Mutex<Option<CommandChild>>)`, a Tauri-managed singleton. On window close (hide to tray), the Rust `on_window_event` handler acquires the lock and calls `child.kill()`. On app exit from the tray, the OS kills the child process automatically.

The `restart_backend` IPC command calls `start_sidecar` again. It does not kill the existing process first — if the port is still in use, the dev-mode path fires immediately. If the old process has crashed, the port is free and a new sidecar is spawned.

## Window Lifecycle

1. App launches. Window is created hidden (`"visible": false`).
2. `lib.rs` setup hook: tray is created, sidecar spawn is kicked off in background async task.
3. `sidecar.rs` `start_sidecar`: window is shown immediately (`window.show()`, `window.set_focus()`).
4. Health check loop runs. Emits `backend-ready` or `backend-unavailable` to the WebView.
5. Frontend receives `backend-ready` Tauri event → `connectionStore.onBackendReady()` → starts 10-second health poll loop.
6. User closes window → `CloseRequested` event → sidecar killed → window hidden (not destroyed).
7. Tray "Quit OSA" → `app.exit(0)` → OS cleanup.

## Tauri Config Highlights (`tauri.conf.json`)

- Default window: 1280×820, min 900×600, dark theme, centered, starts hidden.
- Dev URL: `http://localhost:5199` (Vite dev server).
- Frontend dist: `../build` (SvelteKit static adapter output).
- CSP: `connect-src 'self' http://localhost:9089 http://127.0.0.1:9089` — only the local backend is allowed.
- macOS minimum: 12.0 (Monterey).
- External binary: `binaries/osagent`.
- Bundle targets: all (DMG, MSI, deb, AppImage).
