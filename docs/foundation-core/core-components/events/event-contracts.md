# Event Contracts

## Event Envelope

All events share a common envelope defined by the `Event` struct (CloudEvents
v1.0.2 compliant):

```elixir
%Daemon.Events.Event{
  # CloudEvents v1.0.2 required fields
  id:              "550e8400-e29b-41d4-a716-446655440000",  # UUID v4
  type:            :tool_call,                               # atom
  source:          "agent.loop",                             # string
  time:            ~U[2026-03-14 12:00:00.000Z],            # DateTime UTC
  specversion:     "1.0.2",

  # CloudEvents v1.0.2 optional fields
  subject:         nil,                                      # optional string
  data:            %{tool: "read_file", path: "/tmp/x"},    # payload map
  dataschema:      nil,
  datacontenttype: "application/json",
  extensions:      %{},

  # Tracing
  parent_id:       "parent-event-uuid",      # causality chain
  session_id:      "session-abc",            # owning session
  correlation_id:  "request-group-uuid",     # related event group

  # Signal Theory dimensions S=(M,G,T,F,W)
  signal_mode:      :sync,      # processing mode
  signal_genre:     :command,   # signal genre
  signal_type:      :request,   # structural type
  signal_format:    :structured, # encoding format
  signal_structure: :map,       # data structure
  signal_sn:        0.85        # signal-to-noise ratio (0.0–1.0)
}
```

## Event Creation

### New Event

```elixir
event = Event.new(:tool_call, "agent.loop", %{tool: "search"})
```

Default opts: `source: "bus"`, `session_id: nil`, `parent_id: nil`.

### Child Event (Causality Chain)

```elixir
child = Event.child(parent_event, :tool_result, "tools.registry", %{result: "..."})
```

`Event.child/4` copies `session_id`, `correlation_id`, and sets `parent_id` to
the parent event's `id`. This creates a traceable causality chain.

### Emit With Tracing

```elixir
{:ok, event} = Events.Bus.emit(:llm_request,
  %{model: "claude-sonnet-4-6", messages: messages},
  session_id: session_id,
  parent_id: user_message_event.id,
  correlation_id: request_id,
  source: "agent.loop"
)
```

## Per-Event-Type Payload Contracts

### user_message

```elixir
%{
  session_id: "session-abc",
  content: "Write a test for this function",
  role: "user",
  channel: :cli | :http | :telegram | :discord | :slack
}
```

### llm_request

```elixir
%{
  session_id: "session-abc",
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  messages: [...],    # full conversation history slice
  tools: [...],       # tool specs passed to LLM
  iteration: 3
}
```

### llm_response

```elixir
%{
  session_id: "session-abc",
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  content: "Here is the analysis...",
  tool_calls: [],     # empty = final response
  usage: %{
    input_tokens: 1234,
    output_tokens: 567,
    cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0
  },
  duration_ms: 1842,
  success: true
}
```

`Telemetry.Metrics` subscribes to `llm_response` to record provider latency,
token stats, and call counts.

### tool_call

```elixir
%{
  session_id: "session-abc",
  tool_use_id: "toolu_abc123",
  name: "read_file",
  input: %{"path" => "/home/user/project/main.ex"}
}
```

### tool_result

```elixir
%{
  session_id: "session-abc",
  tool_use_id: "toolu_abc123",
  name: "read_file",
  result: "defmodule Main do\n...",
  error: nil,         # string if error occurred
  duration_ms: 42
}
```

`Telemetry.Metrics` subscribes to `tool_result` to record tool execution counts
and latency. Note: the payload uses `:name` (not `:tool`) as the tool
identifier.

### agent_response

```elixir
%{
  session_id: "session-abc",
  content: "The function has been refactored.",
  channel: :cli,
  iteration_count: 5,
  tools_used: ["read_file", "write_file", "run_tests"]
}
```

### system_event

```elixir
%{
  session_id: "session-abc",  # optional
  kind: :heartbeat | :scheduler_tick | :memory_flush | :vault_checkpoint,
  payload: %{}                # event-kind-specific data
}
```

### algedonic_alert

```elixir
%{
  signal: :pain | :pleasure,
  severity: :critical | :high | :medium | :low,
  message: "DLQ: tool_result handler failed 3 times",
  metadata: %{
    event_type: :tool_result,
    last_error: "timeout after 30000ms",
    created_at: 1741953600000
  }
}
```

### ask_user_question

```elixir
%{
  session_id: "session-abc",
  ref: "ask-ref-string-uuid",
  question: "Which database should I use for this?",
  options: ["PostgreSQL", "SQLite", "Skip"],
  asked_at: ~U[2026-03-14 12:00:00Z]
}
```

The HTTP endpoint `GET /sessions/:id/pending_questions` reads from
`osa_pending_questions` ETS to surface this to the user.

### survey_answered

```elixir
%{
  session_id: "session-abc",
  ref: "ask-ref-string-uuid",
  answer: "PostgreSQL"
}
```

## EventStream

`Events.Stream` provides a per-session event store with pub/sub:

### Starting a Stream

```elixir
{:ok, _pid} = Events.Stream.start_link("session-abc")
```

Streams are registered in `EventStreamRegistry` and started by
`Supervisors.Sessions` before the session `Loop` starts.

### Appending Events

```elixir
:ok = Events.Stream.append("session-abc", event)
```

Events are stored in a circular buffer backed by an Erlang `:queue`. When the
buffer reaches 1000 events, the oldest event is dropped:

```elixir
defp enqueue(queue, count, event, max) when count >= max do
  {_dropped, queue} = :queue.out(queue)
  {:queue.in(event, queue), max}
end
```

### Subscribing to Live Events

```elixir
:ok = Events.Stream.subscribe("session-abc", self())

# Subscriber receives:
receive do
  {:event, %Event{} = event} -> handle(event)
end
```

Subscribers are monitored. When a subscriber process exits, it is automatically
removed from the stream's subscriber map.

### Querying Events

```elixir
# All events
{:ok, events} = Events.Stream.events("session-abc")

# Filtered
{:ok, tool_calls} = Events.Stream.events("session-abc",
  type: :tool_call,
  since: ~U[2026-03-14 11:00:00Z],
  limit: 20
)
```

Options:
- `:type` — filter by event type atom
- `:since` — only events with `time >= since` (DateTime)
- `:limit` — most recent N events

### Time-Range Replay

```elixir
{:ok, events} = Events.Stream.replay(
  "session-abc",
  ~U[2026-03-14 11:00:00Z],
  ~U[2026-03-14 12:00:00Z]
)
```

Returns all events in the stream with `time` between `from` and `to` inclusive.
Useful for debugging, audit trails, and session replay.

## Tracing with Causality Chains

Parent-child event relationships form observable causality chains:

```
user_message (id: A, parent_id: nil)
    └── llm_request (id: B, parent_id: A)
            └── tool_call (id: C, parent_id: B)
                    └── tool_result (id: D, parent_id: C)
                            └── llm_response (id: E, parent_id: D)
                                    └── agent_response (id: F, parent_id: E)
```

All events in a single request share the same `session_id`. Related events
across multiple requests in a workflow share `correlation_id`.

## to_map/1 and to_cloud_event/1

```elixir
# For goldrush dispatch — flat map suitable as gre proplist
map = Event.to_map(event)
# => %{id: "...", type: :tool_call, source: "...", time: ~U[...], data: %{...}, ...}

# CloudEvents 1.0.2 JSON-serializable map
cloud_event = Event.to_cloud_event(event)
# => %{"specversion" => "1.0.2", "type" => "tool_call", "source" => "...", ...}
```
