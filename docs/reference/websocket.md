# Real-Time Events: SSE and WebSocket (Planned)

OSA uses Server-Sent Events (SSE) for streaming agent responses today. This document describes the planned extension of that event stream to cover knowledge graph changes, agent activity, and system-level signals — enabling live-updating frontends without polling.

This is a design document. The full event taxonomy described here is planned, not fully implemented as of March 2026.

---

## Current State: SSE for Agent Responses

The existing HTTP channel streams LLM tokens to clients over SSE:

```
GET /api/v1/sessions/:session_id/stream
Accept: text/event-stream
```

Events emitted today:

```
event: token
data: {"text": "Here is", "session_id": "abc123"}

event: tool_call
data: {"tool": "file_read", "args": {"path": "lib/auth.ex"}}

event: tool_result
data: {"tool": "file_read", "result": "...", "duration_ms": 12}

event: done
data: {"session_id": "abc123", "total_tokens": 847}
```

This stream is the primary channel used by the CLI and HTTP clients.

---

## Planned: Knowledge Graph SSE Stream

A dedicated stream for triple store changes, designed to drive the Knowledge Explorer's live graph view.

```
GET /api/v1/knowledge/stream
Accept: text/event-stream
Authorization: Bearer <token>
```

Planned events:

```
event: triple_asserted
data: {
  "subject":   "urn:osa:agent:cortex",
  "predicate": "urn:osa:knows",
  "object":    "urn:osa:concept:elixir",
  "graph":     "default",
  "ts":        "2026-03-08T10:00:00Z"
}

event: triple_retracted
data: {
  "subject":   "urn:osa:agent:cortex",
  "predicate": "urn:osa:knows",
  "object":    "urn:osa:concept:elixir",
  "ts":        "2026-03-08T10:01:00Z"
}

event: materialization_complete
data: {
  "inferred_count": 1240,
  "duration_ms":    382,
  "ts":             "2026-03-08T10:02:00Z"
}

event: consistency_violation
data: {
  "class":   "urn:owl:Nothing",
  "reason":  "Unsatisfiable — type conflict on urn:osa:agent:cortex",
  "ts":      "2026-03-08T10:03:00Z"
}
```

The backend source for these events is `Events.Bus` on the `:knowledge_event` topic. The knowledge store emits bus events after every write and after reasoner runs.

---

## Planned: Agent Activity Stream

A stream of agent lifecycle events for dashboards and monitoring frontends.

```
GET /api/v1/events/stream
Accept: text/event-stream
Authorization: Bearer <token>
```

Planned events (a subset of `Events.Bus` `:system_event` surfaced to HTTP):

```
event: session_started
data: {"session_id": "cli_abc123", "channel": "cli", "ts": "..."}

event: session_ended
data: {"session_id": "cli_abc123", "message_count": 42, "ts": "..."}

event: tool_telemetry
data: {"tool_name": "file_read", "duration_ms": 12, "ts": "..."}

event: hook_blocked
data: {"hook_name": "spend_guard", "hook_event": "pre_tool_use", "reason": "Budget exceeded", "ts": "..."}

event: recipe_step_completed
data: {"recipe": "code-review", "step_index": 2, "step_name": "Security Audit", "ts": "..."}

event: proactive_message
data: {"message": "Cron job completed: daily-digest", "message_type": "work_complete", "ts": "..."}

event: task_created
data: {"session_id": "cli_abc123", "task_id": "task_001", "title": "Implement auth", "ts": "..."}

event: task_completed
data: {"session_id": "cli_abc123", "task_id": "task_001", "ts": "..."}
```

---

## WebSocket (Future Consideration)

SSE covers the read-only streaming use cases. A WebSocket connection would add bidirectional capability — sending commands to the agent from the browser without a separate REST call.

Planned use cases for WebSocket (not currently prioritized):

| Use Case | Direction | Notes |
|----------|-----------|-------|
| Cancel a running agent | Client → Server | Interrupt signal to the agent loop |
| Submit a message | Client → Server | Alternative to `POST /api/v1/sessions/:id/message` |
| Real-time collaborative viewing | Server → Clients | Multiple browser tabs watching one session |

The `Phoenix.Channels` layer is available in the HTTP channel stack. Adding WebSocket support requires enabling the Phoenix endpoint WebSocket configuration and implementing channel handlers.

---

## Client Integration

### Connecting to SSE in JavaScript

```javascript
const source = new EventSource(
  "/api/v1/sessions/cli_abc123/stream",
  { headers: { Authorization: `Bearer ${token}` } }
)

source.addEventListener("token", (e) => {
  const { text } = JSON.parse(e.data)
  appendToChat(text)
})

source.addEventListener("done", () => {
  source.close()
})

source.onerror = () => {
  // Reconnect with exponential backoff
}
```

### Connecting in Svelte

```svelte
<script>
  import { onMount, onDestroy } from "svelte"

  let events = []
  let source

  onMount(() => {
    source = new EventSource("/api/v1/knowledge/stream")
    source.addEventListener("triple_asserted", (e) => {
      events = [...events, JSON.parse(e.data)]
    })
  })

  onDestroy(() => source?.close())
</script>
```

---

## Reconnection

SSE clients reconnect automatically using the browser's built-in retry mechanism. The server sets `retry: 3000` (3-second reconnect interval) in the SSE headers. For knowledge graph streams, the client should request events since the last known timestamp to avoid replaying already-seen events:

```
GET /api/v1/knowledge/stream?since=2026-03-08T10:00:00Z
```

This `since` filter is planned but not yet implemented.

---

## See Also

- [HTTP API](http-api.md) — REST endpoints for non-streaming operations
- [Knowledge Explorer](knowledge-explorer.md) — the frontend that consumes the knowledge stream
- [Proactive Mode](../features/proactive-mode.md) — source of proactive_message events
