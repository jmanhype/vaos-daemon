# BUG-012: No Swarm Status Endpoint at /api/v1/swarm/status

> **Severity:** HIGH
> **Status:** Open
> **Component:** `lib/optimal_system_agent/channels/http/api/orchestration_routes.ex`
> **Reported:** 2026-03-14

---

## Summary

The desktop client and Go TUI both poll `GET /api/v1/swarm/status/<id>` to
display swarm progress. This path is documented in `api.ex` line 18 as
`GET /swarm/status/:id`. The route exists in `orchestration_routes.ex` at
line 387, but there is a conflict: `GET /:swarm_id` at line 408 matches first
when Plug evaluates routes in declaration order, capturing `"status"` as the
`swarm_id` segment and calling `Swarm.status("status")`, which returns
`{:error, :not_found}` → 404.

## Symptom

```
GET /api/v1/swarm/status/swarm_abc123
→ 404 {"error":"not_found","details":"Swarm status not found"}
```

The correct handler is unreachable because the wildcard `/:swarm_id` declared
earlier in the file swallows all single-segment GET requests.

## Root Cause

In `orchestration_routes.ex`, the route declarations appear in this order:

```elixir
# Line 387 — specific path (should match /status/:id)
get "/status/:swarm_id" do ...

# Line 408 — wildcard (matches EVERYTHING including /status/...)
get "/:swarm_id" do ...
```

Plug.Router evaluates `get "/:swarm_id"` before `get "/status/:swarm_id"` if
the wildcard was declared first in compilation order, or if Plug's internal
routing disambiguates literals over variables only at the first path segment.
For `/status/abc`, Plug sees `/:swarm_id` where `swarm_id = "status"` as a
valid single-segment match before it tries to match two segments.

The router documentation in `api.ex` line 18 shows `GET /swarm/status/:id` as
a canonical endpoint, but the implementation is broken by ordering.

## Impact

- Swarm progress polling fails in all clients.
- Users cannot track running swarms from the desktop UI.
- CLI `/swarm` command shows stale or empty data.

## Suggested Fix

Move `get "/status/:swarm_id"` to appear before `get "/:swarm_id"` in
`orchestration_routes.ex`, or rename the wildcard to avoid ambiguity:

```elixir
# More specific paths first
get "/status/:swarm_id" do
  ...
end

# Wildcard last
get "/:swarm_id" do
  ...
end
```

Plug.Router evaluates routes in the order they appear at compile time. Placing
more-specific patterns before wildcards is the required pattern.

## Workaround

Use `GET /api/v1/swarm/<id>` directly (not `/swarm/status/<id>`). This hits the
wildcard handler which correctly calls `Swarm.status(swarm_id)`.
