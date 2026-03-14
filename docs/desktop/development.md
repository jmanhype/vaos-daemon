# Development Guide

## Prerequisites

You need three runtimes installed:

**Node.js** — version 20 or later. Check: `node --version`.

**Rust** — stable toolchain via [rustup](https://rustup.rs). Check: `rustc --version`. The Tauri CLI and the `src-tauri` crate compile during the first `tauri dev` run, which takes several minutes. Subsequent builds are incremental.

**Tauri CLI** — installed as a local npm devDependency (`@tauri-apps/cli@^2`). You do not need to install it globally; `npm run tauri:dev` invokes it via the local `node_modules/.bin` path.

**Elixir sidecar binary** — the compiled `osagent` binary must be placed at `src-tauri/binaries/osagent` (the path declared in `tauri.conf.json` under `bundle.externalBin`). In development you can skip this by running the Elixir backend manually on port 9089 — the sidecar spawn is skipped when the port is already in use.

**Platform-specific system dependencies:**

- macOS: Xcode Command Line Tools (`xcode-select --install`).
- Linux (Ubuntu/Debian): `libwebkit2gtk-4.1-dev libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev`.
- Windows: Microsoft Visual C++ Build Tools, WebView2 Runtime.

## Running in Development

```bash
cd desktop
npm install
npm run tauri:dev
```

`tauri dev` does the following in parallel:

1. Runs `npm run dev` (the `beforeDevCommand` in `tauri.conf.json`), which starts the Vite dev server at `http://localhost:5199`.
2. Compiles the Rust `src-tauri` crate. On the first run this compiles all dependencies and takes 3–5 minutes.
3. Opens a native window pointing to `http://localhost:5199`.

The Rust layer runs `sidecar::start_sidecar`. If `binaries/osagent` is not present, it logs a warning and emits `backend-unavailable`. The window still opens. If you have the Elixir backend running separately on port 9089, the sidecar check finds the port in use and connects to it instead.

To run the backend manually:

```bash
# In the backend directory (separate terminal):
mix phx.server   # or however the Elixir app is started
# Backend must listen on port 9089
```

## Hot Reload Behavior

The SvelteKit frontend uses Vite HMR. Changes to `.svelte`, `.ts`, and `.css` files in `src/` are reflected in the Tauri window immediately without a full reload — typically under 100 ms.

Changes to `src-tauri/src/*.rs` trigger a Rust recompile. `tauri dev` detects the change and rebuilds the Rust crate. On macOS M-series hardware this takes 5–15 seconds for incremental builds. The window reopens automatically when the Rust binary restarts.

Changes to `tauri.conf.json` also trigger a Rust rebuild.

## Project-Specific Dev Shortcuts

**Skip the sidecar.** Run the Elixir backend manually on port 9089. When `sidecar.rs` detects the port is in use, it sets `SIDECAR_RUNNING = true` and emits `backend-ready` without spawning a child process.

**Frontend only (no native window).** If you only need to work on the SvelteKit UI:

```bash
npm run dev
```

This starts Vite at `http://localhost:5199` in the browser. The `@tauri-apps/api` calls will fail silently (no Tauri context), but the HTTP API calls to port 9089 will work if the backend is running.

**Type checking:**

```bash
npm run check          # run once
npm run check:watch    # watch mode
```

**Lint and format:**

```bash
npm run lint           # prettier + eslint (check only)
npm run format         # prettier write
```

## Building for Production

```bash
npm run tauri:build
```

This runs:
1. `npm run build` — Vite builds the SvelteKit app with the static adapter into `build/`.
2. `tauri build` — compiles the Rust crate in release mode, bundles `build/` into the native app, and packages installers.

Output locations:
- macOS: `src-tauri/target/release/bundle/dmg/OSA_*.dmg` and `.app`
- Linux: `src-tauri/target/release/bundle/deb/*.deb` and `.AppImage`
- Windows: `src-tauri/target/release/bundle/msi/*.msi`

**Debug build** (production binary with debug info):

```bash
npm run tauri:build:debug
```

Useful for profiling native performance without the slow Rust dev-mode binary.

**Before building for distribution**, the `osagent` binary must be in `src-tauri/binaries/` and it must be compiled for the target platform. On macOS with Apple Silicon you need a universal binary or an arm64 binary.

## Debugging

### SvelteKit Frontend

In Tauri dev mode, right-click anywhere in the window and select "Inspect Element" to open the WebKit DevTools. All `console.log`, `console.error`, and `console.warn` output appears in the DevTools console.

To enable DevTools in a production build, add `"devtools": true` to the window config in `tauri.conf.json` (do not ship this in a release).

Alternatively:

```bash
# macOS — open Safari, enable Develop menu, then attach to OSA
# Safari → Develop → OSA → main
```

### Rust / Tauri Layer

Logs are written via the `log` crate (`log::info!`, `log::warn!`, `log::error!`). `env_logger` is initialized in `lib.rs::run()`.

Set the `RUST_LOG` environment variable before launching:

```bash
RUST_LOG=debug npm run tauri:dev
# or more specific:
RUST_LOG=osa_desktop=debug,tauri=warn npm run tauri:dev
```

Sidecar stdout/stderr is logged at `debug` level prefixed with `[osagent]` and `[osagent stderr]`.

### Checking Backend Connection

The `check_backend_health` IPC command and the `connectionStore` poll `/health` every 10 seconds. You can call the command from the DevTools console:

```javascript
const { invoke } = window.__TAURI__.core;
await invoke("check_backend_health");        // true / false
await invoke("get_backend_url");             // "http://127.0.0.1:9089"
await invoke("detect_hardware");             // { cpu_brand, cpu_cores, ... }
```

### Common Dev Problems

**`tauri dev` fails on first Rust compile.** Usually a missing system dependency. On Linux, install `libwebkit2gtk-4.1-dev`. On macOS, ensure Xcode CLT is installed.

**Window opens but shows a blank white page.** Vite did not start before Tauri. Check that port 5199 is free before running `npm run tauri:dev`. Kill any stale Vite processes with `lsof -ti:5199 | xargs kill`.

**"Backend offline" banner is always shown.** The sidecar binary is missing from `src-tauri/binaries/osagent`. Either build and copy the binary, or run the Elixir backend manually on port 9089.

**Hot reload stops working.** Restart `npm run tauri:dev`. This sometimes happens when the Rust watcher and the Vite watcher get out of sync.

**Permission dialog appears but agent does not resume.** The backend does not implement `POST /sessions/:id/tool_calls/:toolUseId/decision`. This endpoint was added after the permission UI. Check backend version and logs.

**`svelte-check` reports type errors in `.svelte` files.** Run `npx svelte-kit sync` to regenerate the `.svelte-kit/` type declarations, then re-run `npm run check`.

## Makefile Targets

The `Makefile` in `desktop/` provides convenience wrappers. Check it for project-specific targets like test, lint-fix, or clean.

```bash
make dev      # alias for npm run tauri:dev
make build    # alias for npm run tauri:build
```

## SvelteKit Config Notes

`svelte.config.js` uses `@sveltejs/adapter-static` — the SvelteKit app builds to static files, not a Node.js server. This is required because Tauri serves the frontend from the filesystem (or the Vite dev server URL in dev mode).

Path aliases are defined in `tsconfig.json`:
- `$lib` → `src/lib`
- `$api` → `src/lib/api`
- `$app` → SvelteKit virtual module (navigation, environment, stores)
