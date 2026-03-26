# Event System

## Overview

The Daemon event system is built on `goldrush`, a library that compiles
event-matching predicates into real Erlang bytecode modules (`.beam` files) at
runtime. This gives routing performance at BEAM instruction speed — no hash
lookups, no dynamic pattern matching on the hot path.

The system has three layers:

```
Events.Bus          — public API: emit/3, register_handler/2, unregister_handler/2
    ↓
:daemon_event_router   — goldrush-compiled BEAM module (type filtering only)
    ↓
dispatch_event/1    — reads handlers from ETS :daemon_event_handlers, dispatches via Task
    ↓
Events.DLQ          — failed handlers → exponential backoff retry
```

A secondary path appends every event with a `session_id` to the per-session
`Events.Stream` circular buffer.

## Event Types

Thirteen event types are declared at compile time:

| Type | Direction | Description |
|------|-----------|-------------|
| `user_message` | channel → Agent.Loop | User input from any channel |
| `llm_request` | Agent.Loop → Providers.Registry | LLM API call being made |
| `llm_response` | Providers → Agent.Loop | LLM API response received |
| `tool_call` | Agent.Loop → Tools.Registry | Tool being invoked |
| `tool_result` | Tools → Agent.Loop | Tool execution result |
| `agent_response` | Agent.Loop → Channels, Bridge.PubSub | Final agent response |
| `system_event` | Scheduler, internals → Agent.Loop, Memory | Internal system signals |
| `channel_connected` | Channels → Bus | Channel connection established |
| `channel_disconnected` | Channels → Bus | Channel connection closed |
| `channel_error` | Channels → Bus | Channel transport error |
| `ask_user_question` | Agent.Loop → HTTP endpoint | Agent blocking on user input |
| `survey_answered` | HTTP endpoint → Agent.Loop | User answered a pending question |
| `algedonic_alert` | Any → System | Urgent bypass signal (VSM pain/pleasure) |

Events with types outside this list are rejected at the `emit/3` call site via
a guard clause.

## Signal Theory Integration

Every event carries Signal Theory (S-theory) dimensions that classify its
information content. These dimensions are auto-classified by
`Events.Classifier.auto_classify/1` when not explicitly provided:

| Field | Type | Description |
|-------|------|-------------|
| `signal_mode` | atom | Processing mode (`:sync`, `:async`, `:reactive`) |
| `signal_genre` | atom | Signal genre classification |
| `signal_type` | atom | Structural type |
| `signal_format` | atom | Encoding format |
| `signal_structure` | atom | Data structure type |
| `signal_sn` | float (0.0–1.0) | Signal-to-noise ratio |

Signal dimensions drive routing decisions. The `GenreRouter` in `Agent.Loop`
uses `signal_genre` to short-circuit some genres without LLM invocation.

## Failure Mode Detection

`Events.FailureModes` (delegating to `MiosaSignal.FailureModes`) runs
signal-theoretic failure detection on a 1-in-10 sample of events:

```elixir
@failure_mode_sample_rate 10

if :rand.uniform(@failure_mode_sample_rate) == 1 do
  case FailureModes.detect(typed_event) do
    [] -> :ok
    violations ->
      Enum.each(violations, fn {mode, description} ->
        Logger.warning("[Bus] Signal failure mode #{mode}: #{description}")
      end)
  end
end
```

This keeps the detection overhead negligible (10% of events) while still
catching systematic signal pathologies.

## CloudEvents Compliance

The `Event` struct follows the CloudEvents v1.0.2 specification:

```elixir
defstruct [
  # CloudEvents v1.0.2 required
  :id, :type, :source, :time,
  # CloudEvents v1.0.2 optional
  :subject, :data, :dataschema,
  # Tracing
  :parent_id, :session_id, :correlation_id,
  # Signal Theory S=(M,G,T,F,W)
  :signal_mode, :signal_genre, :signal_type,
  :signal_format, :signal_structure, :signal_sn,
  # Defaults
  specversion: "1.0.2",
  datacontenttype: "application/json",
  extensions: %{}
]
```

CloudEvents fields:
- `id` — UUID v4 generated at emit time
- `source` — caller-provided string (default: `"bus"`)
- `type` — one of the 13 declared event type atoms
- `time` — UTC DateTime at emit time

## Algedonic Alerts

Algedonic alerts are VSM (Viable System Model) urgent bypass signals. They
propagate immediately outside normal event channels, signaling critical system
health issues.

```elixir
Events.Bus.emit_algedonic(:high, "DLQ: tool_result handler failed 3 times",
  metadata: %{event_type: :tool_result, last_error: "timeout"})
```

Severity levels: `:critical`, `:high`, `:medium`, `:low`.

Algedonic alerts are emitted automatically by the DLQ when a handler exhausts
all retry attempts.

## Task-Supervised Dispatch

All dispatch is fire-and-forget via `Events.TaskSupervisor`:

```elixir
Task.Supervisor.start_child(
  Daemon.Events.TaskSupervisor,
  fn -> :glc.handle(:daemon_event_router, gre_event) end,
  max_children: 1000
)
```

This ensures the `emit/3` caller is never blocked by handler execution,
goldrush's `gr_param` GenServer timeouts, or ETS contention. The task supervisor
caps concurrent dispatch tasks at 1000 to prevent runaway memory growth.

## Session Stream Integration

After routing through the compiled module, every event with a `session_id` is
best-effort appended to the per-session `Events.Stream`:

```elixir
if typed_event.session_id do
  try do
    Events.Stream.append(typed_event.session_id, typed_event)
  rescue
    e -> Logger.warning("[Bus] Stream append failed: #{Exception.message(e)}")
  end
end
```

Failures are caught and logged — stream unavailability never blocks event dispatch.
