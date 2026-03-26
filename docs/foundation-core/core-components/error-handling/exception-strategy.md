# Exception Strategy

## When to Use try/rescue

Use `try/rescue` for *expected* failures where the calling code can provide a
meaningful recovery. Do not use it to silence unexpected crashes — those belong
to supervisors.

### API Call Failures

All LLM provider modules wrap HTTP calls in `try/rescue`:

```elixir
try do
  response = Req.post!(url, json: body, headers: headers, receive_timeout: 120_000)
  {:ok, parse_response(response)}
rescue
  Req.TransportError -> {:error, "Network error — provider unreachable"}
  Req.HTTPError = e  -> {:error, "HTTP #{e.response.status}: #{inspect(e.response.body)}"}
  Jason.DecodeError   -> {:error, "Invalid JSON in provider response"}
end
```

### ETS Table Access

ETS table operations raise `ArgumentError` when the table does not exist (before
startup or after a supervisor restart). Code that reads shared ETS tables wraps
lookups defensively:

```elixir
def cancel(session_id) do
  :ets.insert(:daemon_cancel_flags, {session_id, true})
rescue
  ArgumentError ->
    Logger.warning("[loop] Cancel table not found — agent may not be running")
    {:error, :not_running}
end
```

### Optional Module Calls

Modules marked optional (sandbox, intelligence, sidecars) are wrapped at call
sites so their absence or crash does not affect core flow:

```elixir
try do
  Daemon.Sandbox.execute(cmd)
rescue
  _ -> {:error, "Sandbox unavailable"}
catch
  :exit, _ -> {:error, "Sandbox process not running"}
end
```

### Event Stream Append

Stream append is fire-and-forget; failures must not block the caller:

```elixir
try do
  Events.Stream.append(typed_event.session_id, typed_event)
rescue
  e ->
    Logger.warning("[Bus] Stream append failed: #{Exception.message(e)}")
catch
  kind, reason ->
    Logger.warning("[Bus] Stream #{kind}: #{inspect(reason)}")
end
```

### Checkpoint Write

Checkpoint writes are best-effort. A failed checkpoint is logged and skipped;
the session continues:

```elixir
def checkpoint_state(state) do
  File.write!(path, Jason.encode!(sanitized), [:utf8])
rescue
  e -> Logger.warning("[loop] Checkpoint write failed: #{Exception.message(e)}")
end
```

## When to Use catch

Use `:exit` catches for GenServer calls to processes that may not be running
(`:noproc`):

```elixir
def get_state(session_id) do
  GenServer.call(via(session_id), :get_state)
catch
  :exit, _ -> {:error, :not_found}
end
```

Use `:exit` catches in `Events.Stream` public API to handle the case where
the stream GenServer for a session has already stopped:

```elixir
def append(session_id, event) do
  GenServer.call(via(session_id), {:append, event})
catch
  :exit, {:noproc, _} -> {:error, :not_found}
end
```

## Supervisor Restart Policies

### :transient (Agent.Loop)

`Agent.Loop` uses `:transient` restart. The process restarts on abnormal exit
(crash) but not on normal exit (conversation finished). This is correct because:

- A finished session should not restart and consume resources
- A crashed session should restart so the user can continue

### :one_for_one (Sessions, Extensions)

Channel adapters and extension subsystems are independent. A Telegram adapter
crash should not restart the Discord adapter or the session supervisor.

### :rest_for_one (Infrastructure)

Infrastructure processes have strict dependencies. If `Events.Bus` crashes,
everything that depends on it (Bridge.PubSub, Telemetry.Metrics) must restart
too because they hold subscriptions or state that references Bus-internal
structures.

## Graceful Degradation Pattern

For truly optional subsystems, the degradation follows this pattern:

1. The feature flag check happens in `Supervisors.Extensions.init/1`
2. If the flag is false, no child spec is added — the process never starts
3. Call sites guard with a feature-enabled check before calling the module:

```elixir
defp maybe_sandbox_execute(cmd, opts) do
  if Application.get_env(:daemon, :sandbox_enabled, false) do
    Sandbox.execute(cmd, opts)
  else
    {:error, "Sandbox not enabled"}
  end
end
```

This prevents `Process.whereis` failures and avoids GenServer call timeouts to
non-running processes.

## DLQ Exception Strategy

The DLQ is the exception handler for the event dispatch system. It catches
handler crashes that escape `dispatch_with_dlq/3` and gives them structured
retry semantics rather than silent loss:

```elixir
defp retry_handler(entry) do
  try do
    entry.handler.(entry.payload)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end
```

After `@max_retries` (3) failures, the event is permanently dropped and an
algedonic alert is emitted so operators know that a handler is consistently
failing.

## Logger Usage

Exceptions are always logged before being swallowed:

| Severity | Use |
|----------|-----|
| `Logger.error/1` | Permanent failure (DLQ exhausted, unrecoverable data loss) |
| `Logger.warning/1` | Expected failure with degraded behavior (provider timeout, checkpoint write failed) |
| `Logger.debug/1` | Non-failure informational (checkpoint written, compaction triggered) |

Never swallow an exception without at least a `Logger.warning/1` entry. Silent
failures make debugging impossible.
