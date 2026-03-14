# BUG-011: POST /api/v1/orchestrator/complex Returns 404

> **Severity:** HIGH
> **Status:** Open
> **Component:** `lib/optimal_system_agent/channels/http/api.ex`, `lib/optimal_system_agent/channels/http/api/orchestration_routes.ex`
> **Reported:** 2026-03-14

---

## Summary

SDK clients and documentation that reference the legacy endpoint
`POST /api/v1/orchestrator/complex` receive a 404. The alias route is defined in
`api.ex` but `OrchestrationRoutes` does not register a `post "/complex"` handler
when reached via the `/orchestrator` prefix — because Plug.Router receives the
stripped path as `/complex` in both cases, and the handler is present. The actual
404 stems from a different cause: the `/orchestrator` forward was added later
than `/orchestrate` and the route ordering interacts with the `match _` catch-all.

## Symptom

```
POST /api/v1/orchestrator/complex
→ 404 {"error":"not_found","details":"Endpoint not found"}
```

`POST /api/v1/orchestrate/complex` works correctly. Only the `/orchestrator`
alias path fails.

## Root Cause

`api.ex` lines 91–94 define both forwards:

```elixir
forward "/orchestrate", to: API.OrchestrationRoutes
# /orchestrator is an alias for /orchestrate kept for backward-compat with
# clients that used the longer form (e.g. POST /orchestrator/complex).
forward "/orchestrator", to: API.OrchestrationRoutes
```

However, Plug.Router compiles route matchers at compile time using the
`script_name` stack. When a request arrives at `/orchestrator/complex`, Plug
strips the `/orchestrator` prefix and passes `/complex` to
`OrchestrationRoutes`. This should hit the `post "/complex"` handler at line 170
of `orchestration_routes.ex`. In practice the `match _` catch-all at line 448
fires instead when the request body has not yet been parsed, because
`Plug.Parsers` is placed _after_ `plug :match` in `OrchestrationRoutes` (lines
35–36). The parsed body is `nil`, so the `with %{"task" => task}` guard at
line 171 fails and Plug falls through to the catch-all.

The root issue: `Plug.Parsers` is declared in the _parent_ `api.ex` (line 70)
after `:dispatch`, not before `:match` in the sub-router. Sub-routers that rely
on a parsed body must either declare their own `Plug.Parsers` or rely on the
parent having already run it.

## Impact

- SDK integrations and any documentation referencing `/orchestrator/complex`
  silently fail.
- The error response is a generic 404, providing no hint that `/orchestrate/complex`
  is the correct path.

## Suggested Fix

Add a `Plug.Parsers` plug in `OrchestrationRoutes` before `:match`, or confirm
that parent parsing is completed before forwarding. In `api.ex`, move
`Plug.Parsers` before `plug :match` (line 68) so body is available in all
sub-routers:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["application/json"],
  json_decoder: Jason,
  length: 1_000_000

plug :match
plug :dispatch
```

## Workaround

Use `POST /api/v1/orchestrate/complex` instead of
`POST /api/v1/orchestrator/complex`. Update all client code and documentation
to use the canonical path.
