# State Management — Svelte Stores

All stores use the Svelte 5 runes API (`$state`, `$derived`, `$derived.by`, `$effect`). Each store is a class with public reactive fields and is exported as a module-level singleton. There are 18 store files under `src/lib/stores/`.

## Store Index

| File | Singleton | Purpose |
|---|---|---|
| `chat.svelte.ts` | `chatStore` | Sessions, messages, active SSE stream |
| `sessions.svelte.ts` | `sessionsStore` | Session panel state (open/close, CRUD) |
| `permissions.svelte.ts` | `permissionStore` | Tool permission queue, YOLO mode |
| `connection.svelte.ts` | `connectionStore` | Backend health polling |
| `agents.svelte.ts` | `agentsStore` | Agent list, tree inference, SSE updates |
| `tasks.svelte.ts` | `taskStore` | Orchestrator task progress |
| `survey.svelte.ts` | `surveyStore` | Survey queue and submission |
| `theme.svelte.ts` | `themeStore` | Dark/light/system theme |
| `models.svelte.ts` | `modelsStore` | Model list and activation |
| `palette.svelte.ts` | `paletteStore` | Command palette open state + commands |
| `activity.svelte.ts` | `activityStore` | Activity feed |
| `activityLogs.svelte.ts` | `activityLogsStore` | Raw activity log entries |
| `memory.svelte.ts` | `memoryStore` | Memory card browser |
| `plan.svelte.ts` | `planStore` | Orchestrator plan state |
| `scheduledTasks.svelte.ts` | `scheduledTasksStore` | Scheduler jobs |
| `settingsStore.ts` | `settingsStore` | App settings (writable Svelte 4 store) |
| `usage.svelte.ts` | `usageStore` | Token / cost usage tracking |
| `voice.svelte.ts` | `voiceStore` | Voice input, provider selection, transcription |

## `chatStore` — The Central Store

`src/lib/stores/chat.svelte.ts`

This store owns the SSE connection and is the single source of truth for conversations.

**Reactive fields:**

```typescript
sessions        = $state<Session[]>([])
currentSession  = $state<Session | null>(null)
messages        = $state<Message[]>([])
pendingUserMessage = $state<Message | null>(null)  // optimistic
streaming       = $state<StreamingMessage>({
  textBuffer:    "",
  thinkingBuffer: "",
  toolCalls:     [],
})
isStreaming     = $state(false)
isLoadingSessions = $state(false)
isLoadingMessages = $state(false)
error           = $state<string | null>(null)
```

**SSE stream lifecycle:**

`sendMessage(content, model?)` creates a session if none exists, sets `pendingUserMessage` optimistically, then calls `streamMessage()` from `$api/sse`. Each `StreamEvent` passes through `#handleStreamEvent`:

- `streaming_token` → appends to `streaming.textBuffer`
- `thinking_delta` → appends to `streaming.thinkingBuffer`
- `tool_call` → pushes to `streaming.toolCalls`
- `tool_result` → updates matching tool call with result
- `done` → calls `#finalizeStream()`: moves pending user message into `messages`, creates an assistant `Message` from the buffers, clears streaming state
- `error` → sets `error`, clears `isStreaming`

`cancelGeneration()` aborts the `StreamController` and calls `#finalizeStream()` with whatever content accumulated.

**Stream listener pattern:**

`chatStore` exposes a broadcast bus for raw SSE events:

```typescript
chatStore.addStreamListener(fn: (event: StreamEvent) => void): void
chatStore.removeStreamListener(fn): void
```

The `app/+layout.svelte` registers a `dispatchStreamEvent` listener here, which routes `tool_call`, `system_event` (survey, tasks), and `done` to their respective stores. This avoids coupling `chatStore` to permissions, surveys, or tasks directly.

## `permissionStore` — Tool Permission Queue

`src/lib/stores/permissions.svelte.ts`

Manages a queue of permission requests shown one at a time in `PermissionOverlay.svelte`.

**Reactive fields:**

```typescript
queue  = $state<PermissionRequest[]>([])
yolo   = $state(false)
```

Derived getters: `current` (head of queue), `hasPending`.

**`requestPermission(tool, description, paths)`:**

Returns a `Promise<PermissionDecision>`. If YOLO mode is active or the tool is in the `#alwaysAllowed` Set, resolves immediately with `"allow"`. Otherwise pushes a `PermissionRequest` (with the resolve function) onto `queue` and waits.

**`decide(decision)`:**

Resolves the head request. If `"allow_always"`, adds the tool to `#alwaysAllowed`. Removes the request from the queue.

**`enableYolo()`:**

Sets `yolo = true` and drains the current queue by resolving all pending requests with `"allow"`.

**`handleToolCallEvent(tool, description, paths, onDecision)`:**

Called by the layout's SSE dispatcher when a `tool_call` event arrives with `phase: "awaiting_permission"`. Wraps `requestPermission` and passes the resolved decision to `onDecision`, which POSTs it to the backend.

**Decision types:**

```typescript
type PermissionDecision = "allow" | "allow_always" | "deny"
```

## `connectionStore` — Backend Health Polling

`src/lib/stores/connection.svelte.ts`

**Reactive fields:**

```typescript
status      = $state<"connecting" | "connected" | "disconnected">("connecting")
health      = $state<HealthResponse | null>(null)
lastChecked = $state<Date | null>(null)
error       = $state<string | null>(null)
isChecking  = $state(false)
```

Derived: `isConnected`, `isReady` (connected and health status is `"ok"` or `"degraded"`).

**`startPolling(intervalMs = 10_000)`:**

Runs `check()` immediately, then every 10 seconds. Returns a cleanup function. The app layout calls this from `onMount`.

**`markCrashed(reason?)`:**

Called when the Tauri `backend-crashed` event fires. Stops polling, sets status to `"disconnected"` immediately without waiting for the next poll.

**`onBackendReady()`:**

Called when Tauri emits `backend-ready`. Performs an immediate health check and restarts polling.

## `sessionsStore` — Session Panel

`src/lib/stores/sessions.svelte.ts`

A companion to `chatStore` focused on the session list panel (open/close state and session CRUD). Uses `sessionsApi` directly.

**`switchSession(id)`:**

Sets `activeId` and dispatches a `CustomEvent("osa:session-switch", { detail: { sessionId } })` on `window`. The chat view listens for this event to load the selected session.

**`syncFromChatStore(sessions, activeId)`:**

Called after `chatStore.listSessions()` resolves to avoid a second network request.

## `agentsStore` — Agent Tree

`src/lib/stores/agents.svelte.ts`

**Derived tree inference:**

The backend `Agent` type has no `parentId` or `wave` fields yet. `agentsStore` infers hierarchy from creation timestamps: agents created within 2 seconds of each other are assigned the same wave number. The root is the first agent or one whose name contains "orchestrat", "master", or "primary".

`agentTree = $derived.by(...)` returns a flat `AgentTreeNode[]` array. `AgentTree.svelte` uses the `wave` field for layout rather than recursive traversal.

**SSE integration:**

`handleEvent({ type, payload })` handles `agent_started`, `agent_updated`, `agent_done`, `agent_error`, and `agent_removed`. Uses `splice` for fine-grained Svelte reactivity on updates.

## `taskStore` — Orchestrator Task Progress

`src/lib/stores/tasks.svelte.ts`

Tracks tasks emitted by the orchestrator as `system_event` SSE events.

```typescript
tasks = $state<Task[]>([])
```

Derived: `completedCount`, `activeTask`, `hasTasks`, `pendingTasks`.

Task status progression: `pending` → `active` → `completed` | `failed`.

The `TaskCard` component floats above the `ChatInput` when `taskStore.hasTasks` is true. Users can click "Ask" to send a follow-up question about the active task directly into the chat.

## `surveyStore` — Survey Queue

`src/lib/stores/survey.svelte.ts`

Manages surveys triggered by backend `system_event` SSE events (`event: "survey_shown"`).

**`showSurvey(survey, sessionId?)`:**

Adds to an internal queue and returns a `Promise<Answer[]>`. Shows one survey at a time. On completion, POSTs answers to `/api/v1/sessions/:sessionId/survey/answer`.

**`handleDismiss()`:**

Rejects the promise for the active survey.

## `themeStore` — Theme

`src/lib/stores/theme.svelte.ts`

Persists the theme preference in `localStorage` under key `osa-theme`. Reacts to `prefers-color-scheme` media query changes when in `"system"` mode. Applies `data-theme` attribute and `color-scheme` CSS property to `document.documentElement`. Also calls `@tauri-apps/api/window getCurrentWindow().setTheme()` to sync the native window chrome.

## Auth Store (in `client.ts`)

Auth state is module-level in `src/lib/api/client.ts`, not a Svelte store. The JWT is held in `_token: string | null` and persisted to Tauri's encrypted store via `@tauri-apps/plugin-store` (`store.json`, key `authToken`).

**`initializeAuth()`:**

Called once from the root `+layout.svelte` on mount:
1. Reads `authToken` from `store.json`.
2. If absent, POSTs to `/api/v1/auth/login` with a `crypto.randomUUID()` user ID to obtain a token.
3. Persists the token back to `store.json`.
4. Schedules `refreshToken()` every 10 minutes via `setInterval`.

**`refreshToken()`:**

De-duplicates concurrent calls via a `_refreshPromise` singleton. POSTs to `/api/v1/auth/refresh`. On failure, clears `_token`.

**Auto-refresh on 401:**

The `request<T>()` function retries once after a 401 by calling `refreshToken()`. If the refresh also fails, the 401 is surfaced to the caller.

## `voiceStore` — Voice Input

`src/lib/stores/voice.svelte.ts`

Supports four voice providers: `local` (no API key, uses browser MediaRecorder), `groq` (Groq Whisper API), `openai` (OpenAI Whisper), and `browser` (Web Speech API).

`ChatInput.svelte` binds to `voiceStore.isListening` to show the pulsing mic indicator and the active state on the toolbar button.
