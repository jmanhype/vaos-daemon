# Event Bus

## Architecture

`Daemon.Events.Bus` is a GenServer that owns the goldrush router
compilation and handler registration. At runtime, routing and dispatch happen in
caller processes (not the GenServer), giving near-zero overhead for the hot path.

```
Events.Bus (GenServer)
├── init/1            → compiles :daemon_event_router once
├── handle_call       → serializes handler registration/unregistration
└── :daemon_event_handlers (ETS :bag, public) → read by dispatch_event/1
```

## goldrush Router Compilation

The router is compiled **once** during `init/1` and never recompiled:

```elixir
defp compile_router do
  # Build an OR filter over all 13 declared event types
  type_filters = Enum.map(@event_types, &:glc.eq(:type, &1))

  # Wrap with output handler
  query =
    :glc.with(:glc.any(type_filters), fn event ->
      dispatch_event(event)
    end)

  :glc.compile(:daemon_event_router, query)
end
```

`glc:compile/2` generates a real `.beam` module named `:daemon_event_router` and
loads it into the running VM. Subsequently, `glc:handle(:daemon_event_router, event)`
routes events at BEAM instruction speed with no runtime pattern matching.

### Why Never Recompile

Recompiling after init causes a race condition:

1. `gr_param:transform/1` wipes the internal ETS table mid-recompile
2. In-flight Task workers still hold references to bytecode in the old module
3. `ets:lookup_element` crashes because the table no longer exists

Handler dispatch is kept dynamic via ETS lookup rather than baking handlers into
the compiled module. Adding or removing handlers requires no recompilation.

## emit/3

```elixir
@spec emit(atom(), map(), keyword()) :: {:ok, Event.t()}
def emit(event_type, payload \\ %{}, opts \\ []) when event_type in @event_types
```

Options:

| Option | Type | Description |
|--------|------|-------------|
| `:source` | string | Origin identifier (default: `"bus"`) |
| `:parent_id` | string | Parent event ID for causality chains |
| `:session_id` | string | Session this event belongs to |
| `:correlation_id` | string | Groups related events across sessions |
| `:signal_mode` | atom | Signal Theory mode (auto-classified if nil) |
| `:signal_genre` | atom | Signal Theory genre |
| `:signal_sn` | float | Signal-to-noise ratio (0.0–1.0) |

Emit flow:

```
emit(type, payload, opts)
    │
    ▼
Event.new(type, source, payload, opts)    # creates Event struct with UUID + timestamp
    │
    ▼
Classifier.auto_classify(event)           # adds signal dimensions if nil
    │
    ▼
FailureModes.detect(event)                # sampled 1-in-10; logs violations
    │
    ▼
gre:make(fields, [:list])                 # converts to goldrush event record
    │
    ▼
Task.Supervisor.start_child(...)          # fire-and-forget task
    │   └── glc:handle(:daemon_event_router, gre_event)
    │           └── dispatch_event(event)
    │                   └── read :daemon_event_handlers ETS
    │                           └── dispatch_with_dlq/3 per handler
    │
    ▼
Events.Stream.append(session_id, event)   # best-effort; failures logged
    │
    ▼
{:ok, typed_event}
```

## emit_algedonic/3

Specialized emit for urgent VSM bypass signals:

```elixir
@spec emit_algedonic(atom(), String.t(), keyword()) :: {:ok, Event.t()}
def emit_algedonic(severity, message, opts \\ [])
    when severity in [:critical, :high, :medium, :low]
```

Constructs an `algedonic_alert` event with:

```elixir
payload = %{
  signal: :pain,          # or :pleasure for positive alerts
  severity: severity,
  message: message,
  metadata: metadata
}
```

## Handler Registration

```elixir
@spec register_handler(atom(), (map() -> any())) :: reference()
def register_handler(event_type, handler_fn) when is_function(handler_fn, 1)

@spec unregister_handler(atom(), reference()) :: :ok
def unregister_handler(event_type, ref)
```

Registration goes through `GenServer.call/3` to serialize writes. The returned
reference is used for later unregistration. Handler data is stored in ETS
`:daemon_event_handlers` (`:bag`, `:public`):

```
{event_type, ref, handler_fn}
```

Multiple handlers for the same event type are stored as separate bag entries and
all execute concurrently via separate supervised tasks.

## dispatch_with_dlq/3

All handler invocations go through `dispatch_with_dlq/3`, which catches crashes
and routes failures to the DLQ:

```elixir
defp dispatch_with_dlq(type, payload, handler) do
  Task.Supervisor.start_child(Daemon.Events.TaskSupervisor, fn ->
    try do
      handler.(payload)
    rescue
      e ->
        Logger.warning("[Bus] Handler crash for #{type}: #{Exception.message(e)}")
        DLQ.enqueue(type, payload, handler, Exception.message(e))
    catch
      kind, reason ->
        DLQ.enqueue(type, payload, handler, "#{kind}: #{inspect(reason)}")
    end
  end)
end
```

Handlers receive a plain Elixir map derived from `gre:pairs/1`. The map contains
all Event struct fields plus a goldrush monotonic `:timestamp`.

## Dead Letter Queue

`Events.DLQ` is an ETS-backed GenServer that retries failed handler invocations
with exponential backoff:

| Parameter | Value |
|-----------|-------|
| Max retries | 3 |
| Base backoff | 1,000 ms |
| Max backoff | 30,000 ms |
| Backoff formula | `min(base * 2^retries, max)` |
| Retry tick interval | 60,000 ms |

Backoff schedule:

| Attempt | Delay |
|---------|-------|
| 1 | 1,000 ms |
| 2 | 2,000 ms |
| 3 | 4,000 ms (capped at 30,000 ms) |

When a handler exhausts all retries, the DLQ:
1. Deletes the entry from ETS
2. Logs an error at `:error` level
3. Emits an `algedonic_alert` with severity `:high`

```elixir
Events.Bus.emit_algedonic(:high,
  "DLQ: #{entry.event_type} handler failed #{@max_retries} times",
  metadata: %{event_type: entry.event_type, last_error: last_error})
```

### Handler Storage in DLQ

Anonymous functions cannot survive process restarts, so the DLQ converts
handlers to MFA tuples before storing:

```elixir
defp to_mfa(fun) when is_function(fun) do
  case Function.info(fun) do
    info ->
      mod = Keyword.get(info, :module)
      name = Keyword.get(info, :name)
      if convertible?(mod, name), do: {mod, name, []}, else: fun
  end
end
```

Non-convertible anonymous functions (closures capturing local state) are stored
as-is on a best-effort basis.

## ETS Tables

| Table | Type | Options | Purpose |
|-------|------|---------|---------|
| `:daemon_event_handlers` | `:bag` | `:public` | Handler registrations by event type |

The Bus itself does not own the goldrush internal tables — those are managed by
`gr_param` (a goldrush GenServer started automatically when goldrush is loaded).
