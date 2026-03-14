# Event Architecture

## Audience

Engineers adding new event types, subscribing to events, or debugging event routing in OSA.

## Overview

OSA uses a two-layer event system:

1. **goldrush** (`Events.Bus`) — high-speed internal dispatch. Handlers are compiled to BEAM bytecode modules at startup. Events are dispatched via supervised tasks.
2. **Phoenix.PubSub** (`Bridge.PubSub`) — multi-process fan-out. Bridges goldrush events to named pub/sub topics so SDK connections, SSE streams, and monitoring processes can subscribe without coupling to goldrush directly.

## Event Struct

Events conform to CloudEvents v1.0.2. The canonical implementation is in `MiosaSignal.Event`; `OptimalSystemAgent.Events.Event` is a delegation shim for backward compatibility.

```elixir
%OptimalSystemAgent.Events.Event{
  # CloudEvents v1.0.2 required
  id: "uuid-string",
  type: :llm_response,        # atom, one of @event_types
  source: "agent.loop",       # string identifying origin
  time: ~U[2026-01-01 00:00:00Z],
  specversion: "1.0.2",
  datacontenttype: "application/json",

  # CloudEvents optional
  subject: nil,
  data: %{...},               # event payload
  dataschema: nil,
  extensions: %{},

  # Tracing
  parent_id: "parent-event-uuid",
  session_id: "session-123",
  correlation_id: "corr-456",

  # Signal Theory dimensions S=(M,G,T,F,W)
  signal_mode: :data,         # :data | :command | :query | :event | :stream
  signal_genre: :task,        # see MiosaSignal.Event.signal_genre()
  signal_type: :request,
  signal_format: :json,
  signal_structure: :flat,
  signal_sn: 0.73             # signal-to-noise ratio 0.0–1.0
}
```

## Event Types

The event bus recognizes exactly these event types (defined as `@event_types` in `Events.Bus`):

```elixir
~w(
  user_message
  llm_request
  llm_response
  tool_call
  tool_result
  agent_response
  system_event
  channel_connected
  channel_disconnected
  channel_error
  ask_user_question
  survey_answered
  algedonic_alert
)a
```

Events not in this list are rejected by the goldrush type filter and never dispatched.

## goldrush Compilation

At `Events.Bus.init/1`, a goldrush query is compiled into a real `.beam` module named `:osa_event_router`:

```elixir
type_filters = Enum.map(@event_types, &:glc.eq(:type, &1))

query = :glc.with(:glc.any(type_filters), fn event ->
  dispatch_event(event)
end)

:glc.compile(:osa_event_router, query)
```

This compilation happens exactly once. Recompiling after init would cause a TOCTOU race between `gr_param`'s ETS tables and in-flight task workers holding references to the old bytecode.

At dispatch time, an event is converted to a goldrush record:

```elixir
gre_fields = typed_event |> Event.to_map() |> Map.to_list()
gre_event  = :gre.make(gre_fields, [:list])
:glc.handle(:osa_event_router, gre_event)
```

The `:type` field must be present at the top level for the goldrush filter to match.

## Emitting Events

```elixir
alias OptimalSystemAgent.Events.Bus

# Standard event
{:ok, event} = Bus.emit(:llm_response, %{
  session_id: "sess-123",
  duration_ms: 1200,
  usage: %{input_tokens: 450, output_tokens: 312}
}, source: "agent.loop", session_id: "sess-123")

# Algedonic alert (urgent bypass signal)
{:ok, _} = Bus.emit_algedonic(:high, "DLQ handler exhausted retries",
  metadata: %{event_type: :tool_result, retries: 3}
)
```

Options for `emit/3`:

| Option | Type | Description |
|--------|------|-------------|
| `:source` | string | Origin identifier (default: `"bus"`) |
| `:parent_id` | string | Parent event UUID for causality chains |
| `:session_id` | string | Session scoping for stream append |
| `:correlation_id` | string | Groups related events |
| `:signal_mode` | atom | Override auto-classification |
| `:signal_genre` | atom | Override auto-classification |
| `:signal_sn` | float | Signal-to-noise ratio |

Auto-classification runs on every event without explicit `signal_mode`. `Events.Classifier.auto_classify/1` delegates to `MiosaSignal.Classifier`.

## Signal Theory Failure-Mode Detection

A 1-in-10 sample of events is checked against `Events.FailureModes.detect/1` (delegates to `MiosaSignal.FailureModes`). Detected violations are logged at warning level:

```
[Bus] Signal failure mode :noise on tool_result: high noise content
```

This sampling keeps the hot path overhead negligible.

## Handler Registration

```elixir
# Register a handler
ref = Events.Bus.register_handler(:llm_response, fn payload ->
  # payload is a map with atom keys from Event.to_map/1
  IO.inspect(payload.session_id)
end)

# Unregister
Events.Bus.unregister_handler(:llm_response, ref)
```

Handlers are stored in `:osa_event_handlers` ETS table (`:named_table, :public, :bag`). Registration does not recompile the goldrush module — the compiled module does type filtering only; handler lookup is dynamic via ETS.

Each handler invocation is wrapped in a supervised task. A handler crash routes the event to `Events.DLQ` for retry.

## Phoenix.PubSub Integration

`Bridge.PubSub` registers a handler for every event type on `Events.Bus` after a 100ms delay (to avoid a startup race). It then fans out each event to four pub/sub tiers:

| Topic | When used |
|-------|-----------|
| `"osa:events"` | Firehose — all events (debugging, monitoring) |
| `"osa:session:{session_id}"` | Events for one session |
| `"osa:type:{type}"` | Events of one type across all sessions |
| `"osa:tui:output"` | Agent-visible events for the Rust TUI SSE stream |

Subscribing:

```elixir
# Firehose
Bridge.PubSub.subscribe_firehose()

# Session
Bridge.PubSub.subscribe_session("sess-123")

# Type
Bridge.PubSub.subscribe_type(:llm_response)

# TUI
Bridge.PubSub.subscribe_tui_output()
```

Subscribers receive `{:osa_event, payload}` messages where `payload` is the event map.

## TUI Event Types

Events broadcast to `osa:tui:output` are those the agent surface should display:

```elixir
@tui_event_types ~w(llm_chunk llm_response agent_response tool_result tool_error
                    thinking_chunk agent_message signal_classified)a

@tui_system_events ~w(skills_triggered sub_agent_started sub_agent_completed
                      orchestrator_agent_started orchestrator_agent_completed
                      orchestrator_started orchestrator_finished
                      skill_evolved skill_bootstrap_created
                      doom_loop_detected agent_cancelled budget_alert)a
```

A `system_event` reaches the TUI only if its `event` field is in `@tui_system_events`.

## Per-Session Event Streams

In addition to PubSub, each session has a dedicated `Events.Stream` GenServer (circular buffer of 1000 events, registered in `OptimalSystemAgent.EventStreamRegistry`). The bus appends to it automatically when `session_id` is present on the event:

```elixir
if typed_event.session_id do
  Events.Stream.append(typed_event.session_id, typed_event)
end
```

Stream subscribers receive `{:event, event}` messages. The stream is automatically cleaned up when the subscriber process exits.
