# TUI Lessons & Requirements

> Reference doc for the new TUI replacement. Go TUI (`priv/go/tui-v2/`) is being retired.

## 1. Auth Flow (the #1 source of pain)

- Login MUST complete before any authenticated API calls
- Sequential: health check → login → set token → fetch commands/tools/SSE
- Never fire authenticated requests in parallel with login
- `require_auth: false` for local/Ollama usage
- Token must be stored AND set on the HTTP client

## 2. Backend Contract

| Endpoint | Auth | Returns |
|---|---|---|
| `GET /health` | No | Health status |
| `POST /api/v1/auth/login` | No | `{token, refresh_token, expires_in}` |
| `GET /api/v1/commands` | Yes | Command registry |
| `GET /api/v1/tools` | Yes | Tool list |
| `POST /api/v1/orchestrate` | Yes | `{session_id, status}` |
| `GET /api/v1/sse/:session_id` | Yes (Bearer) | SSE stream |

All SSE event types defined in `client/types.go`.

## 3. SSE Event Types to Handle

**Streaming:**
- `streaming_token`, `thinking_delta`, `agent_response`

**LLM lifecycle:**
- `llm_request`, `llm_response`

**Tools:**
- `tool_call_start`, `tool_call_end`, `tool_result`

**Signal:**
- `signal_classified`, `context_pressure`

**Tasks:**
- `task_created`, `task_updated`

**Orchestrator:**
- `orchestrator_*` (wave/agent lifecycle)

**Swarm:**
- `swarm_started`, `swarm_completed`, `swarm_failed`, `swarm_cancelled`, `swarm_timeout`

**Budget/Hooks:**
- `hook_blocked`, `budget_warning`, `budget_exceeded`

## 4. UX Requirements

- Alt-screen mode (full terminal takeover)
- Command palette (Ctrl+K)
- Slash commands with autocomplete
- Multi-line input (Alt+Enter)
- Sidebar toggle (Ctrl+L)
- Background tasks (Ctrl+B)
- Plan review/approve/reject/edit flow
- Session management (create/switch/list)
- Model picker with provider filtering
- Signal badge on every response (mode/genre/type)
- Toast notifications
- Mouse support (click, scroll, text selection + copy)

## 5. Mistakes to Never Repeat

- Don't fire auth-gated requests before login completes
- Don't show errors for expected states (login skip = warning, not error)
- Don't put everything in one file — split by concern from day 1
- Test the binary from a real TTY, not a subprocess
- Handle SSE reconnection gracefully (with backoff)
- God files: `commands.ex` hit 2938 lines, `api.ex` hit 1831 lines — split early

## 6. Rust TUI Architecture (replacement at `priv/rust/tui/`)

**Binary:** `osagent` (4.1MB arm64, stripped LTO)

**Key structural decisions that prevent Go bugs:**
- **Auth race impossible**: `AuthState` enum → `require_token() -> Result<&str>` = compile-time enforcement
- **Key event stealing impossible**: `FocusStack` with ordered layers (Dialog > Completions > Input > Chat > Global), first `Consumed` stops propagation
- **God files impossible**: Rust module system enforces 1 file = 1 concern from day 1
- **Silent exit impossible**: Panic hook restores terminal + prints to stderr + logs BEFORE any cleanup
- **SSE reconnect with backoff**: Exponential 2/4/8/16/30s cap, max 10 attempts

**Module structure:** ~43 files across `app/`, `client/`, `components/`, `event/`, `style/`, `config/`, `view/`, `render/`

**Event flow:** Three sources merged via `mpsc::unbounded_channel<Event>`:
1. Terminal (crossterm EventStream)
2. Backend (SSE events + HTTP response results)
3. App (tick timer, banner timeout, health retry)

**Build phases:**
1. Skeleton (done) — connect, banner, idle, input
2. Chat + SSE + Commands — streaming, messages, slash commands
3. Tool Rendering + Activity — inline tool display, spinners
4. Dialogs — onboarding, model picker, command palette, permissions
5. Multi-Agent + Swarm — orchestrator/swarm event rendering
6. Polish — sidebar, themes, image rendering, clipboard
7. Testing + Hardening — unit tests, clippy clean, binary optimization
