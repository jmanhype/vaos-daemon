# Dead Letter Queue

## Audience

Engineers debugging failed event handlers, monitoring DLQ health, and tuning retry behavior.

## Overview

`OptimalSystemAgent.Events.DLQ` is a GenServer that catches failed event handler invocations and retries them with exponential backoff. It is backed by an ETS table (`:osa_dlq`) for in-process speed. Events are not persisted across restarts — OSA treats events as ephemeral; durable patterns are captured by the learning engine.

## When Events Enter the DLQ

`Events.Bus.dispatch_with_dlq/3` wraps each handler invocation in a supervised task. If the handler raises an exception or throws:

```elixir
Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
  try do
    handler.(payload)
  rescue
    e ->
      Logger.warning("[Bus] Handler crash for #{type}: #{Exception.message(e)}")
      Events.DLQ.enqueue(type, payload, handler, Exception.message(e))
  catch
    kind, reason ->
      Logger.warning("[Bus] Handler #{kind} for #{type}: #{inspect(reason)}")
      Events.DLQ.enqueue(type, payload, handler, "#{kind}: #{inspect(reason)}")
  end
end)
```

Every handler crash results in a DLQ entry. The handler itself is stored — or converted to an MFA tuple for restartability.

## DLQ Entry Structure

```elixir
%OptimalSystemAgent.Events.DLQ{
  id: "base64url-16-bytes",       # crypto-random ID
  event_type: :tool_result,       # atom
  payload: %{...},                # original event payload map
  handler: {Module, :function, []}, # MFA tuple, or closure (best-effort)
  error: "argument error: ...",   # last error string
  retries: 0,                     # number of retries attempted so far
  next_retry_at: 1735689601000,   # monotonic ms
  created_at: 1735689600000       # monotonic ms
}
```

## Retry Policy

Retries use exponential backoff capped at 30 seconds, with a maximum of 3 attempts:

```
Attempt 1 (initial failure): enqueued, next_retry_at = now + 1_000ms
Attempt 2 (retry 1):         next_retry_at = now + 2_000ms  (1s * 2^1)
Attempt 3 (retry 2):         next_retry_at = now + 4_000ms  (1s * 2^2)
→ max_retries exceeded: emit algedonic :high alert, drop entry
```

Constants:

```elixir
@max_retries     3
@base_backoff_ms 1_000
@max_backoff_ms  30_000
```

The DLQ checks for ready entries every 60 seconds (`@cleanup_interval_ms`):

```elixir
defp process_retries do
  now = System.monotonic_time(:millisecond)
  ready = Enum.filter(:ets.tab2list(@table), fn {_, e} -> e.next_retry_at <= now end)
  # retry each ready entry ...
end
```

## Exhaustion Behavior

When a handler exhausts all retries, the DLQ:

1. Deletes the entry from ETS
2. Logs at error level:
   ```
   [DLQ] Event tool_result exhausted 3 retries, dropping. Last error: ...
   ```
3. Emits an algedonic alert (`:high` severity):
   ```elixir
   Events.Bus.emit_algedonic(:high, "DLQ: tool_result handler failed 3 times",
     metadata: %{
       event_type: :tool_result,
       last_error: "...",
       created_at: 1735689600000
     }
   )
   ```

## Handler Storage

Anonymous functions cannot survive process restarts. `DLQ.enqueue/4` attempts to convert closures to MFA tuples:

```elixir
# MFA tuples are stored directly
{Module, :function, args}

# Named functions defined in a module — converted to MFA
fn payload -> Module.function(payload) end
# → {Module, :function, []}

# Anonymous closures over variables — stored as-is (best effort)
fn payload -> IO.inspect(payload) end
# stored as function reference
```

When retrying an MFA tuple, the payload is appended as the final argument:
```elixir
apply(mod, fun, args ++ [entry.payload])
```

## Public API

```elixir
# Check current queue depth
depth = Events.DLQ.depth()
# => 3

# List all entries
entries = Events.DLQ.entries()
# => [%Events.DLQ{id: "...", event_type: :tool_result, retries: 1, ...}]

# Manually force all ready entries to retry now
{successes, failures} = Events.DLQ.drain()
# => {2, 1}
```

## Monitoring

The DLQ does not expose metrics directly to `Telemetry.Metrics`. Monitor it via:

1. **DLQ depth** — call `Events.DLQ.depth/0` from a monitoring process or health check
2. **Algedonic alerts** — subscribe to `Events.Bus.register_handler(:algedonic_alert, ...)` and watch for DLQ-sourced messages
3. **Log patterns** — watch for `[DLQ]` prefix in logs at warning and error levels

Key log messages:

| Level | Message pattern | Meaning |
|-------|----------------|---------|
| warning | `[DLQ] Enqueued failed tool_result event: ...` | Handler crashed, event queued for retry |
| error | `[DLQ] Event tool_result exhausted 3 retries, dropping. Last error: ...` | Permanent failure — investigate the handler |
| info | `[DLQ] Started` | Normal startup |

## Operational Notes

- The `:osa_dlq` ETS table is created by `DLQ.init/1`, not at application boot. If `Events.DLQ` crashes and restarts, all in-flight DLQ entries are lost. This is acceptable because the DLQ holds ephemeral retry state, not source-of-truth data.
- Algedonic alerts emitted for exhausted handlers can cause handler feedback loops if an algedonic handler also crashes. `DLQ.enqueue` wraps the algedonic emission in a `rescue / catch` to prevent this.
- The DLQ operates on monotonic time (`System.monotonic_time(:millisecond)`) for backoff calculations to avoid system clock adjustments interfering with retry scheduling.
