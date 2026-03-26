# Understanding the Desktop App Stack

Daemon's desktop application is built with Tauri, SvelteKit, and Svelte 5. This
guide explains what each piece is, how they fit together, and how the desktop
app communicates with the Elixir backend.

---

## What is Tauri?

Tauri is a framework for building desktop applications. You write the user
interface as a web application (HTML, CSS, JavaScript), and Tauri wraps it in
a native desktop window. The result is a `.app` or `.exe` file that users can
install and run like any other desktop application.

If you have heard of **Electron** (used by VS Code, Slack, Discord), Tauri is
similar in concept but very different in implementation.

### Tauri vs Electron

| | Tauri | Electron |
|---|---|---|
| Core language | Rust | JavaScript (Node.js) |
| Webview | System native (WebKit on macOS, WebView2 on Windows, WebKitGTK on Linux) | Ships its own Chromium |
| Binary size | ~5–15 MB | ~100–200 MB |
| Memory usage | Much lower (no separate browser engine) | Higher (full Chromium instance) |
| Security | Strict by default, explicit API allowlisting | Permissive by default |

Tauri uses whatever webview the operating system provides. On macOS, that is
WebKit (the same engine that powers Safari). This keeps the binary small and
memory usage low. The tradeoff is that rendering can vary slightly across
platforms — but for Daemon's chat UI, this is not a concern.

Tauri's backend is written in Rust, which means the desktop shell is fast,
memory-safe, and produces tiny binaries.

---

## What is SvelteKit?

**Svelte** is a JavaScript UI framework. Like React or Vue, it helps you build
interactive user interfaces from components. Unlike React or Vue, Svelte is a
compiler — it converts your component code into vanilla JavaScript at build time,
rather than shipping a runtime library that does the work in the browser.

This means Svelte applications are smaller, faster, and use less memory than
equivalent React applications. There is no virtual DOM — Svelte generates code
that directly updates the DOM when state changes.

**SvelteKit** is the full-stack framework built on top of Svelte. It adds:

- File-based routing (a file at `src/routes/chat/+page.svelte` becomes the
  `/chat` route)
- Server-side rendering (pages can be pre-rendered for fast initial loads)
- API routes (server-side code that handles requests)
- Build tooling (Vite under the hood)

For Daemon's desktop app, SvelteKit is used primarily for its component system
and routing — not for server-side rendering, since the app talks to the Elixir
backend over HTTP rather than rendering on a Node.js server.

---

## What is Svelte 5?

Daemon uses **Svelte 5**, which introduced a new reactivity system called **runes**.

In Svelte 4, reactivity was implicit. Declaring a variable with `let` inside a
component made it reactive. Assignments triggered updates automatically.

In Svelte 5, reactivity is explicit via runes — special syntax that makes the
intent clear:

```svelte
<script>
  // Svelte 5 runes syntax
  let count = $state(0);           // reactive state
  let doubled = $derived(count * 2); // derived value (computed)

  function increment() {
    count++;  // direct mutation triggers UI update
  }
</script>

<button onclick={increment}>
  Count: {count}, Doubled: {doubled}
</button>
```

Runes are compiled away at build time. The resulting JavaScript is efficient and
has no runtime overhead from the reactivity system itself.

---

## How Daemon's Desktop App Works

The desktop app has three distinct layers:

```
┌─────────────────────────────────────────────────────────┐
│                   Tauri Shell (Rust)                    │
│  • Native window, menus, system tray                    │
│  • Sidecar lifecycle (spawns and monitors Elixir)       │
│  • Secure bridge between webview and OS APIs            │
├─────────────────────────────────────────────────────────┤
│              SvelteKit + Svelte 5 (Frontend)            │
│  • Chat UI, tool call display, memory viewer            │
│  • Routes: /chat, /tasks, /memory, /settings            │
│  • SSE client for real-time streaming                   │
├─────────────────────────────────────────────────────────┤
│              Elixir Backend (Sidecar)                   │
│  • Daemon's full OTP application                           │
│  • HTTP API on port 9089                               │
│  • Agent loop, tools, providers, memory, etc.           │
└─────────────────────────────────────────────────────────┘
```

The Tauri shell and the SvelteKit frontend share the same process — they are
both part of the desktop application. The Elixir backend runs as a separate
process managed by Tauri.

---

## The Sidecar Pattern

A **sidecar** is a process that runs alongside the main application, managed by
the main application's lifecycle.

When you launch Daemon's desktop app:

1. Tauri starts and opens the native window
2. Tauri checks whether something is already running on port 9089
   (this handles the development case where you started the backend manually)
3. If port 9089 is empty, Tauri spawns the `daemon` binary as a child process
4. Tauri waits for the backend to become healthy (polls `GET /health` with
   exponential backoff, up to 30 seconds)
5. When the backend responds healthy, Tauri emits a `backend-ready` event to
   the SvelteKit frontend
6. The frontend receives the event and initializes the chat session

If the backend crashes during a session:
1. Tauri detects the child process termination
2. Tauri emits `backend-crashed` to the frontend
3. The frontend shows an error state and can prompt the user to restart

When the user closes Daemon:
1. Tauri calls the graceful shutdown sequence on the Elixir sidecar
2. The Elixir application runs its cleanup (flushes memory, closes connections)
3. The Tauri process exits

This is implemented in `src-tauri/src/sidecar.rs`. The Elixir binary is declared
in Tauri's configuration as a bundled sidecar binary, which means it is packaged
inside the application bundle and Tauri knows how to find it.

---

## Development Mode vs Production Mode

**Development**: You run the Elixir backend manually with `mix daemon.serve`, and
the frontend with `npm run dev` inside the `desktop/` directory. Tauri connects
to the existing backend because it detects port 9089 is already in use.

**Production**: The Elixir backend is compiled to a release binary (`daemon`)
and bundled inside the `.app` or `.exe`. Tauri spawns it as a sidecar. Users
do not need Elixir, Erlang, or mix installed.

---

## SSE Streaming: Real-Time Updates

When the agent is running — processing a message, executing tools, thinking
through a problem — the user interface shows responses appearing in real time,
token by token. This is done with **Server-Sent Events (SSE)**.

SSE is a web standard for one-way streaming from server to client over HTTP.
Unlike WebSockets (bidirectional), SSE is unidirectional — the server pushes
data to the client. This is a perfect match for streaming LLM responses.

```
Frontend                         Elixir Backend
   │                                   │
   │  GET /sessions/:id/stream         │
   │ ─────────────────────────────────>│
   │                                   │
   │  data: {"type":"token","t":"He"}  │
   │ <─────────────────────────────────│
   │                                   │
   │  data: {"type":"token","t":"llo"} │
   │ <─────────────────────────────────│
   │                                   │
   │  data: {"type":"token","t":" th"} │
   │ <─────────────────────────────────│
   │                                   │
   │  data: {"type":"done"}            │
   │ <─────────────────────────────────│
   │                                   │
```

The connection stays open for the duration of the session. As the LLM generates
tokens, the backend pushes each one through the SSE connection. The frontend
appends each token to the displayed message.

The frontend also receives events for tool calls (showing the user what tool the
agent is using and why), tool results, errors, and session lifecycle events.

---

## The UI Components

Daemon's desktop UI is structured as Svelte 5 components in `desktop/src/`:

```
src/
├── routes/
│   ├── +page.svelte         — Main chat interface
│   └── ...                  — Other routes (tasks, memory, settings)
└── lib/
    └── components/
        ├── chat/
        │   ├── ChatInput.svelte      — Message input field
        │   ├── MessageBubble.svelte  — Individual message display
        │   ├── ThinkingBlock.svelte  — Shows reasoning in progress
        │   └── ToolCall.svelte       — Shows tool execution in progress
        ├── tasks/
        │   ├── TaskCard.svelte
        │   └── ScheduledTaskCard.svelte
        └── memory/
            ├── MemoryCard.svelte
            └── MemoryDetail.svelte
```

Each component is a `.svelte` file containing its HTML template, JavaScript
logic, and CSS — all in one file. Svelte compiles this into efficient JavaScript
at build time.

---

## The Build Process

```
npm run build (inside desktop/)
     ↓
Vite bundles SvelteKit frontend → static files in desktop/build/
     ↓
tauri build
     ↓
Rust compiler builds Tauri shell
     ↓
Elixir release binary (daemon) bundled as sidecar
     ↓
Platform-specific app bundle:
  macOS: Daemon.app
  Windows: Daemon.exe installer
  Linux: Daemon.deb / Daemon.AppImage
```

---

## Next Steps

With the desktop app stack understood, return to the other learning guides if
you skipped any:

- [signal-theory-explained.md](./signal-theory-explained.md) — How Daemon classifies messages
- [react-pattern.md](./react-pattern.md) — How the agent reasons
- [llm-providers.md](./llm-providers.md) — How Daemon talks to AI models

Or move on to the [reference docs](../reference/) for API details and
configuration options.
