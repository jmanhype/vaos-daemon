# BUG-010: Negative uptime_seconds in /health Response

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/optimal_system_agent/channels/http.ex`
> **Reported:** 2026-03-14

---

## Summary

The `GET /health` endpoint returns a negative `uptime_seconds` value when the
`:start_time` application environment key has not been set before the health
check is called, or when the server process clock advances past the stored
`start_time` in a way that produces a negative difference.

## Symptom

```json
GET /health
{
  "status": "ok",
  "uptime_seconds": -1702847293,
  ...
}
```

The uptime value is a large negative integer equal to approximately
`-System.system_time(:second)` (the Unix epoch as a negative number), confirming
that the default fallback produces a near-zero result subtracted from the current
wall-clock time.

## Root Cause

`http.ex` line 94 computes uptime as:

```elixir
uptime = System.system_time(:second) -
  Application.get_env(:optimal_system_agent, :start_time,
    System.system_time(:second))
```

The default value for `Application.get_env` when `:start_time` is not set is
`System.system_time(:second)` evaluated _at the time of the call_. When the
application starts, `:start_time` should be written to the app env, but if the
application supervisor boots the HTTP channel before the key is written, the
default equals the current time and `uptime` is 0 or slightly negative (due to
scheduling jitter).

The deeper issue is that `System.system_time/1` returns wall-clock time which
can go backwards under NTP adjustments. `System.monotonic_time/1` should be used
for duration measurement.

## Impact

- Monitoring systems that parse `uptime_seconds` display incorrect values or
  trigger alerts on negative uptime.
- Desktop and Go TUI health displays show negative or zero uptime.
- A restart detection heuristic that uses uptime < threshold would fire
  incorrectly.

## Suggested Fix

Record boot time using monotonic time in `application.ex`:

```elixir
# In Application.start/2:
Application.put_env(:optimal_system_agent, :boot_monotonic,
  System.monotonic_time(:second))
```

In `http.ex` compute uptime from monotonic origin:

```elixir
boot = Application.get_env(:optimal_system_agent, :boot_monotonic,
         System.monotonic_time(:second))
uptime = System.monotonic_time(:second) - boot
```

`System.monotonic_time/1` is guaranteed non-decreasing within a VM session,
making it safe for elapsed-time calculations.

## Workaround

Set `:start_time` explicitly in `application.ex`:
```elixir
Application.put_env(:optimal_system_agent, :start_time, System.system_time(:second))
```
This eliminates the negative value but retains the NTP-susceptibility issue.
