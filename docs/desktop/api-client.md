# Frontend-Backend Communication

All data communication between the SvelteKit frontend and the OSA backend goes over HTTP and Server-Sent Events to `http://127.0.0.1:9089`. There is no Tauri IPC for data — IPC is used only for system-level operations (health check, restart, hardware detection, terminal launch).

## HTTP Client (`src/lib/api/client.ts`)

**Base coordinates:**

```typescript
export const BASE_URL   = "http://127.0.0.1:9089";
export const API_PREFIX = "/api/v1";
```

The `/health` and `/onboarding/*` endpoints are at the root level (no `/api/v1` prefix). All other endpoints are under `BASE_URL + API_PREFIX`.

**Core `request<T>()` function:**

Every API call goes through a single typed `request<T>(path, options, retried)` function that:

1. Prepends `BASE_URL + API_PREFIX` to the path.
2. Sets `Content-Type: application/json` and `Accept: application/json`.
3. Attaches `Authorization: Bearer <token>` if `_token` is set.
4. On HTTP 401 (and only if not already retried): calls `refreshToken()` and retries once.
5. On non-2xx: reads the body as JSON or text, extracts an `error` field if present, and throws an `ApiError`.
6. On 204 No Content: returns `undefined`.

**`ApiError`:**

```typescript
class ApiError extends Error {
  readonly status: number;
  readonly code:   string | undefined;
  readonly body:   unknown;
}
```

**API namespaces exposed:**

| Export | Methods | Paths |
|---|---|---|
| `health` | `get()` | `GET /health` |
| `onboarding` | `status()`, `complete()` | `GET /onboarding/status`, `POST /onboarding/complete` |
| `sessions` | `list()`, `get(id)`, `create(body)`, `delete(id)`, `rename(id, title)` | `/sessions` |
| `messages` | `list(sessionId)`, `send(body)` | `/sessions/:id/messages`, `/messages` |
| `models` | `list()`, `activate(name)`, `download(name)`, `delete(name)` | `/models` |
| `providers` | `list()`, `connect(slug, apiKey)`, `disconnect(slug)` | `/providers` |
| `agents` | `list()`, `get(id)`, `pause(id)`, `resume(id)`, `cancel(id)` | `/agents` |
| `orchestrate` | `run(body)` | `POST /orchestrate` |
| `settings` | `get()`, `update(body)` | `/settings` |
| `scheduler` | `list()`, `get(id)`, `create(body)`, `delete(id)`, `toggle(id)`, `runNow(id)` | `/scheduler/jobs` |

**`messages.send(body)`** always sets `stream: true`. It returns `{ stream_id, session_id }`. In practice, the chat flow uses the SSE-based `streamMessage()` instead, which sends the message and opens the stream in a single coordinated call.

## Authentication Flow

```
initializeAuth()
  │
  ├── read store.json["authToken"] (Tauri encrypted store)
  │     found → set _token, schedule refresh
  │
  └── not found
        │
        POST /api/v1/auth/login  { user_id: crypto.randomUUID() }
        │
        ← { token: "..." }
        │
        persist to store.json["authToken"]
        schedule setInterval(refreshToken, 10 minutes)
```

Token refresh de-duplicates concurrent calls via `_refreshPromise`. If the refresh fails, `_token` is set to `null` and the app proceeds unauthenticated until the next successful login.

## SSE Streaming (`src/lib/api/sse.ts`)

The SSE client uses `fetch` (not `EventSource`) because `EventSource` does not support custom headers (Authorization) and only supports GET requests.

### Chat Message Stream — `streamMessage(options)`

```
1. GET  /api/v1/sessions/:id/stream        (headers: Authorization, Accept: text/event-stream)
        Opens the SSE response body — starts buffering

2. POST /api/v1/sessions/:id/message       (concurrently)
        body: { message: string, model?: string }
        Returns 200 when message is accepted

3. consumeStream() reads the GET response body
        Events arrive on the SSE connection
        Stops on "done" or "error" event, or AbortSignal
```

Both the stream consumption and the message POST run inside `Promise.all()`. The AbortController from `streamMessage()` is threaded through both fetches, so `abort()` cancels both.

Returns a `StreamController { abort: () => void }`.

### SSE Block Parser — `parseSSEBlock(block)`

SSE messages are `\n\n`-delimited blocks. Each block may contain:

```
event: streaming_token
data: {"type":"streaming_token","delta":"Hello"}
```

The parser extracts `event:` and `data:` lines. If `data` is JSON, parses it; if the `event` field says `streaming_token` but the data is plain text (not JSON), wraps it as `{ type: "streaming_token", delta: data }`. Returns `null` for keep-alive blocks (`:` comment lines) and `[DONE]`.

### Stream Event Types

Defined in `src/lib/api/types.ts`:

| Type | Fields | Description |
|---|---|---|
| `streaming_token` | `delta: string` | Incremental text token from the LLM |
| `thinking_delta` | `delta: string` | Extended thinking / reasoning trace chunk |
| `tool_call` | `tool_use_id`, `tool_name`, `input`, `phase?`, `description?`, `paths?` | Agent is calling a tool; `phase: "awaiting_permission"` pauses for user |
| `tool_result` | `tool_use_id`, `result`, `is_error` | Tool execution result |
| `system_event` | `event: string`, `payload?` | Lifecycle events (survey_shown, task_created, task_updated) |
| `done` | `session_id`, `message_id` | Stream complete |
| `error` | `message`, `code?` | Stream-level error |

### Agent Event Stream — `subscribeToAgentEvents(callbacks, signal)`

Long-lived reconnecting SSE stream on `GET /api/v1/agents/stream`. Uses the same `consumeStream()` reader. On disconnect, reconnects with exponential backoff (1 s → 2 s → 4 s ... → 30 s max). Respects an `AbortSignal` for clean teardown on component destroy.

### Generic Reconnecting SSE — `connectSSE(path, callbacks, maxAttempts)`

General-purpose SSE connector with configurable max attempts (default 5). Returns a `StreamController`. Used for endpoints beyond the agent stream.

**Backoff constants:**

```typescript
const INITIAL_DELAY_MS = 1_000
const MAX_DELAY_MS     = 30_000
const BACKOFF_FACTOR   = 2
```

## Permission Flow (End to End)

When the agent wants to run a privileged tool:

```
Backend
  └── emits SSE: { type: "tool_call", phase: "awaiting_permission",
                   tool_use_id, tool_name, description, paths }

chatStore.#handleStreamEvent()
  └── calls #streamListeners → dispatchStreamEvent (in app layout)

dispatchStreamEvent()
  └── permissionStore.handleToolCallEvent(tool, description, paths, onDecision)

permissionStore
  └── requestPermission() → queues PermissionRequest
  └── PermissionOverlay.svelte shows dialog to user

User clicks Allow / Allow Always / Deny
  └── permissionStore.decide(decision)
  └── onDecision(decision) callback fires

app/+layout.svelte onDecision handler
  └── POST /api/v1/sessions/:sessionId/tool_calls/:toolUseId/decision
        body: { decision: "allow" | "allow_always" | "deny" }

Backend resumes or cancels tool execution
```

The POST in the `onDecision` handler is fire-and-forget (`.catch(() => {})`) because the backend endpoint was added after the permission system and may not exist on older backends.

## Terminal Command Execution

The terminal route (`src/routes/app/terminal/+page.svelte`) does not use the stores API layer. It calls `fetch` directly:

```
POST /api/v1/tools/shell_execute/execute
body: { command: string, working_directory: null }

response:
  { stdout?, stderr?, exit_code?, output?, result? }
```

The response field names are accepted in multiple variants (`stdout` or `output` or `result`) because the backend's field name was not stable during development.

## Tauri IPC Calls

The frontend invokes Tauri commands via `@tauri-apps/api`:

```typescript
import { invoke } from "@tauri-apps/api/core";

await invoke("check_backend_health");           // boolean
await invoke("restart_backend");                // void
await invoke("get_backend_url");                // "http://127.0.0.1:9089"
await invoke("detect_hardware");                // HardwareInfo
await invoke("get_platform");                   // PlatformInfo
await invoke("open_terminal");                  // void
await invoke("get_app_version");                // "0.1.0"
```

The Tauri `backend-ready` and `backend-crashed` events from the Rust layer are consumed in `connectionStore` and the app layout:

```typescript
import { listen } from "@tauri-apps/api/event";

listen("backend-ready",       () => connectionStore.onBackendReady());
listen("backend-unavailable", () => connectionStore.markCrashed("Backend unavailable"));
listen("backend-crashed",     () => connectionStore.markCrashed("Backend crashed"));
```
