# BUG-008: /analytics Command Has No Output Handler

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/optimal_system_agent/commands.ex`, `lib/optimal_system_agent/commands/system.ex`
> **Reported:** 2026-03-14

---

## Summary

`/analytics` is listed as a built-in command in `commands.ex` line 362, mapped
to `&System.cmd_analytics/2`. The `cmd_analytics/2` function exists but returns
a stub response that provides no actionable data. The command appears in `/help`
output, leading users to expect a usage dashboard, but the output is either an
empty string or a generic "analytics not available" message.

## Symptom

```
> /analytics
(no output, or: "Analytics not yet implemented")
```

The command is categorised as `"analytics"` in `category_for/1` at line 142
but the handler does not query `Telemetry.Metrics`, `Memory`, or any data
source.

## Root Cause

The `builtin_commands/0` list at line 362 registers:

```elixir
{"analytics", "Usage analytics and metrics", &System.cmd_analytics/2},
```

The `System` commands module (`lib/optimal_system_agent/commands/system.ex`)
defines `cmd_analytics/2` but the implementation body calls
`OptimalSystemAgent.Telemetry.Metrics` functions that are not yet wired to
return formatted session or cost data. The `Metrics` GenServer exists and tracks
data, but no formatting function is exported that `cmd_analytics` can call.

## Impact

- Users who type `/analytics` to check token costs or session counts get no
  useful output.
- The command creates a misleading capability impression during onboarding.
- `/budget` is similarly affected (see BUG-018).

## Suggested Fix

Wire `cmd_analytics/2` to query and format data from
`OptimalSystemAgent.Telemetry.Metrics`:

```elixir
def cmd_analytics(_arg, session_id) do
  stats = Metrics.summary(session_id)
  output = """
  Analytics — Session: #{session_id}
  Total tokens used: #{stats.total_tokens}
  LLM calls: #{stats.call_count}
  Tool executions: #{stats.tool_count}
  Avg latency: #{stats.avg_latency_ms}ms
  """
  {:command, output}
end
```

If `Metrics.summary/1` does not exist, add it to
`lib/optimal_system_agent/telemetry/metrics.ex`.

## Workaround

Use `GET /api/v1/analytics` via the HTTP API, which delegates to
`handle_analytics/1` in `data_routes.ex` and returns JSON-formatted metrics.
