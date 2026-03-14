# HTTP API Surface

All endpoints are served by Bandit on the configured port (`OSA_HTTP_PORT`, default 4000).
The API router is `OptimalSystemAgent.Channels.HTTP.API` (Plug.Router), mounted at `/api/v1`.

## Global Plug Pipeline

Every request passes through these plugs in order:

1. `cors` — injects `Access-Control-Allow-Origin` (configurable via `:cors_origin`, default `*`); OPTIONS returns 204
2. `OptimalSystemAgent.Channels.HTTP.RateLimiter` — token-bucket ETS-backed, per client IP
3. `validate_content_type` — POST/PUT/PATCH must send `Content-Type: application/json` (415 on violation)
4. `authenticate` — JWT HS256 verification (bypassed for `/auth/*`, `/channels/*`, `/platform/auth/*`)
5. `OptimalSystemAgent.Channels.HTTP.Integrity` — optional HMAC-SHA256 body integrity (enabled when `require_auth: true`)
6. `Plug.Parsers` — JSON body parsing, 1 MB limit

## Authentication

**Scheme:** JWT Bearer (`Authorization: Bearer <token>`)

**Algorithm:** HS256 signed with `OSA_SHARED_SECRET` (or `JWT_SECRET`).

**Token lifetimes:**
- Access token: 15 minutes (`exp = iat + 900`)
- Refresh token: 7 days (`exp = iat + 604_800`)

**Auth mode:**
- `require_auth: false` (default) — missing or invalid tokens are accepted; `user_id` is set to `"anonymous"`. A warning is logged.
- `require_auth: true` (set `OSA_REQUIRE_AUTH=true`) — missing or invalid token returns `401`.

**Claims injected into conn.assigns:**
- `user_id` — from JWT `user_id` claim
- `workspace_id` — from JWT `workspace_id` claim
- `claims` — full decoded map

## Rate Limits

| Path prefix         | Limit             | Window   |
|---------------------|-------------------|----------|
| `/api/v1/auth/`     | 10 req/IP         | 60 sec   |
| `/api/v1/platform/auth/` | 10 req/IP   | 60 sec   |
| All other paths     | 60 req/IP         | 60 sec   |

Exceeded requests receive `429` with `Retry-After: 60` and `X-RateLimit-Remaining: 0`.
All responses include `X-RateLimit-Limit` and `X-RateLimit-Remaining` headers.

---

## Endpoints

### Health

**GET /health**

No auth. Returns process uptime and provider status.

```
Response 200
{ "status": "ok", "uptime_seconds": 3612 }
```

---

### Authentication — `/api/v1/auth`

Auth routes bypass JWT. No Bearer token required.

**POST /api/v1/auth/login**

Obtain access and refresh tokens.

```
Request
{ "user_id": "alice", "secret": "<OSA_SHARED_SECRET>" }

Response 200
{ "token": "<jwt>", "refresh_token": "<jwt>", "expires_in": 900 }

Response 401 — wrong secret
{ "error": "unauthorized", "details": "Invalid or missing secret" }
```

When `OSA_REQUIRE_AUTH=false` and no shared secret is configured, the `secret` field is optional (dev mode; warning is logged).

**POST /api/v1/auth/logout**

Stateless — JWT is not server-side invalidated. Returns `{ "ok": true }`.

**POST /api/v1/auth/refresh**

Exchange a refresh token for a new token pair.

```
Request
{ "refresh_token": "<jwt>" }

Response 200
{ "token": "<jwt>", "refresh_token": "<jwt>", "expires_in": 900 }

Response 401
{ "error": "refresh_failed", "details": "not_refresh_token" }
```

---

### Sessions — `/api/v1/sessions`

**GET /api/v1/sessions**

List all sessions (persisted + live Registry sessions). Supports `?page=1&per_page=20`.

```
Response 200
{
  "sessions": [
    {
      "id": "sess_abc123",
      "title": "debugging the auth flow",
      "message_count": 14,
      "created_at": "2026-03-14T10:00:00Z",
      "last_active": "2026-03-14T11:23:00Z",
      "alive": true
    }
  ],
  "count": 47,
  "page": 1,
  "per_page": 20
}
```

**POST /api/v1/sessions**

Create a new session.

```
Response 201
{ "id": "sess_abc123", "status": "created" }
```

**GET /api/v1/sessions/:id**

Fetch session metadata and full conversation history. System messages are filtered out.

```
Response 200
{
  "id": "sess_abc123",
  "title": "...",
  "message_count": 14,
  "alive": true,
  "messages": [
    { "role": "user", "content": "...", "timestamp": "..." },
    { "role": "assistant", "content": "...", "timestamp": "..." }
  ]
}

Response 404 — { "error": "session_not_found" }
```

**GET /api/v1/sessions/:id/messages**

Returns only the messages array (no metadata).

**GET /api/v1/sessions/:id/stream** — SSE

Server-Sent Events stream scoped to a session. Subscribes to `osa:session:{id}` PubSub topic.

```
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no

event: connected
data: {"session_id": "sess_abc123"}

event: agent_response
data: {"type": "agent_response", "session_id": "...", "response": "..."}

: keepalive   (every 30 seconds)
```

**POST /api/v1/sessions/:id/message**

Send a message to an existing live session (fire-and-forget; poll `/messages` for result).

```
Request
{ "message": "What files are in this directory?" }

Response 202
{ "status": "processing", "session_id": "sess_abc123" }

Response 404 — session not in Registry (not live)
Response 200 — { "status": "filtered" } or { "status": "clarify", "prompt": "..." }
```

**POST /api/v1/sessions/:id/cancel**

Cancel the active agent loop for the session.

```
Response 200 — { "status": "cancel_requested", "session_id": "..." }
Response 404 — { "error": "not_running" }
```

**DELETE /api/v1/sessions/:id**

Cancel loop and delete the session JSONL file from disk.

```
Response 200 — { "status": "deleted", "session_id": "..." }
Response 404 — { "error": "session_not_found" }
```

**POST /api/v1/sessions/:id/replay**

Replay a past session under a different provider/model.

```
Request
{ "session_id": "new_sess_id", "provider": "openai", "model": "gpt-4o" }

Response 202
{ "status": "replaying", "source_session_id": "...", "replay_session_id": "..." }
```

**POST /api/v1/sessions/:id/provider**

Hot-swap the LLM provider for a live session.

```
Request
{ "provider": "anthropic", "model": "claude-opus-4-6" }

Response 200
{ "status": "ok", "provider": "anthropic", "model": "claude-opus-4-6" }
```

---

### Orchestration — `/api/v1/orchestrate` and `/api/v1/orchestrator`

`/orchestrator` is a backward-compatible alias for `/orchestrate`.

**POST /api/v1/orchestrate**

Auto-dispatch: runs a quick complexity heuristic, escalates to multi-agent if complex.

```
Request
{
  "input": "Refactor the authentication module to use OAuth2",
  "session_id": "sess_abc123",   // optional, generated if omitted
  "user_id": "alice",            // optional
  "skip_plan": false,            // optional
  "working_dir": "/home/alice/project",  // optional
  "auto_dispatch": true,         // optional, default true
  "max_agents": 5                // optional
}

Response 202 — single agent
{ "session_id": "...", "status": "processing", "mode": "single_agent" }

Response 202 — multi-agent escalation
{ "session_id": "...", "task_id": "task_xyz", "status": "processing", "mode": "multi_agent" }

Response 200 — noise filtered
{ "session_id": "...", "status": "filtered" }

Response 200 — needs clarification
{ "session_id": "...", "status": "clarify", "prompt": "..." }
```

**POST /api/v1/orchestrate/complex**

Launch a multi-agent orchestrated task directly.

```
Request
{
  "task": "Build a REST API with authentication, tests, and OpenAPI docs",
  "strategy": "auto",     // "auto" | "pact" | "parallel" | "pipeline"
  "session_id": "...",    // optional
  "blocking": false,      // if true, waits up to 5 min for result
  "max_agents": 8         // optional
}

Response 202 — non-blocking
{ "task_id": "task_xyz", "status": "running", "session_id": "..." }

Response 200 — blocking, completed
{ "task_id": "task_xyz", "status": "completed", "synthesis": "...", "session_id": "..." }

Response 504 — blocking, timed out
{ "error": "orchestration_timeout" }
```

**GET /api/v1/orchestrate/tasks**

List all orchestrator tasks (running and recently completed).

```
Response 200
{
  "tasks": [
    {
      "id": "task_xyz",
      "status": "running",
      "message_preview": "Build a REST API...",
      "agent_count": 4,
      "completed_agents": 2,
      "started_at": "2026-03-14T10:00:00Z"
    }
  ],
  "count": 3,
  "active_count": 1
}
```

**GET /api/v1/orchestrate/:task_id/progress**

Snapshot of task progress including per-agent status and token usage.

```
Response 200
{
  "task_id": "task_xyz",
  "status": "running",
  "started_at": "...",
  "agents": [
    {
      "id": "agent_1",
      "name": "research",
      "role": "researcher",
      "status": "running",
      "tool_uses": 12,
      "tokens_used": 45200,
      "current_action": "file_read"
    }
  ],
  "synthesis": null,
  "machine_phase": "executing",
  "formatted": "Running 3 agents..."
}
```

**GET /api/v1/orchestrate/:task_id/progress/stream** — SSE

Real-time progress stream. Subscribes to `osa:orchestrator:{task_id}` PubSub.

---

### Swarm — `/api/v1/swarm`

**POST /api/v1/swarm/launch**

```
Request
{
  "task": "Audit the codebase for security issues",
  "pattern": "parallel",      // "parallel" | "pipeline" | "debate" | "review" | named preset
  "max_agents": 5,
  "timeout_ms": 300000,
  "session_id": "..."
}

Response 202
{
  "swarm_id": "swarm_abc",
  "status": "running",
  "pattern": "parallel",
  "agent_count": 5,
  "agents": [],
  "started_at": "..."
}

Response 400 — invalid pattern
{ "error": "invalid_pattern", "details": "Unknown pattern 'foo'. Execution patterns: parallel, pipeline, debate, review." }
```

**GET /api/v1/swarm**

List all swarms.

```
Response 200
{ "swarms": [...], "count": 3, "active_count": 1 }
```

**GET /api/v1/swarm/:id** or **GET /api/v1/swarm/status/:id**

Get swarm status.

```
Response 200
{
  "id": "swarm_abc",
  "status": "completed",
  "task": "Audit the codebase...",
  "pattern": "parallel",
  "agent_count": 5,
  "agents": ["agent_1", "agent_2", ...],
  "result": "...",
  "started_at": "...",
  "completed_at": "..."
}
```

**DELETE /api/v1/swarm/:id**

```
Response 200 — { "status": "cancelled", "swarm_id": "swarm_abc" }
Response 404 — { "error": "not_found" }
```

---

### Agent SSE Stream — `/api/v1/stream`

**GET /api/v1/stream/tui_output**

SSE stream for the Rust TUI. Subscribes to `osa:tui:output` PubSub topic. Receives agent-visible events: `llm_chunk`, `llm_response`, `agent_response`, `tool_result`, `tool_error`, `thinking_chunk`.

**GET /api/v1/stream/:session_id**

Session-scoped SSE stream. Subscribes to `osa:session:{session_id}`. Validates session ownership when `require_auth: true`.

---

### Signal Classification — `/api/v1/classify`

**POST /api/v1/classify**

Classify a message using Signal Theory (no LLM call, deterministic).

```
Request
{ "message": "fix the login bug", "channel": "http" }

Response 200
{
  "signal": {
    "mode": "reactive",
    "genre": "task",
    "type": "code_change",
    "format": "plain",
    "weight": 0.87
  }
}
```

---

## Standard Error Shape

All errors use a consistent JSON envelope:

```json
{ "error": "<error_code>", "details": "<human-readable message>" }
```

Common codes: `invalid_request`, `not_found`, `unauthorized`, `rate_limited`,
`internal_error`, `orchestration_error`, `swarm_error`, `session_not_found`.
