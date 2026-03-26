# Tracing

## Correlation Fields

Daemon does not integrate an external distributed tracing system (no OpenTelemetry,
no Jaeger). Tracing is built from three correlation fields carried on every
`Event` struct:

| Field | Purpose |
|-------|---------|
| `id` | Unique identifier for this event (UUID v4) |
| `parent_id` | ID of the event that caused this event |
| `session_id` | Session this event belongs to |
| `correlation_id` | Groups related events across multiple sessions or requests |

These fields form two orthogonal views:

- **Causality chain** — follow `parent_id` links to trace how a user message
  became an LLM response became tool calls became a final answer
- **Session view** — filter by `session_id` to see all events in a session,
  in chronological order

## Causality Chain Example

A single user turn produces this event chain:

```
user_message
  id: "evt-001"
  parent_id: nil
  session_id: "session-abc"
      │
      ▼
llm_request
  id: "evt-002"
  parent_id: "evt-001"
  session_id: "session-abc"
      │
      ▼
tool_call (read_file)
  id: "evt-003"
  parent_id: "evt-002"
  session_id: "session-abc"
      │
      ▼
tool_result (read_file)
  id: "evt-004"
  parent_id: "evt-003"
  session_id: "session-abc"
      │
      ▼
llm_response
  id: "evt-005"
  parent_id: "evt-004"
  session_id: "session-abc"
      │
      ▼
agent_response
  id: "evt-006"
  parent_id: "evt-005"
  session_id: "session-abc"
```

Creating child events with `Event.child/4` automatically sets `parent_id`:

```elixir
llm_req = Event.child(user_msg, :llm_request, "agent.loop",
  %{provider: :anthropic, model: "claude-sonnet-4-6"})

tool_call = Event.child(llm_req, :tool_call, "tools.registry",
  %{name: "read_file", input: %{path: "/tmp/x"}})
```

## EventStream — Real-Time Session Monitoring

`Events.Stream` provides real-time access to all events in a session. Subscribe
from any process:

```elixir
# Subscribe to live events for a session
:ok = Events.Stream.subscribe("session-abc")

# Receive events as they are emitted
receive do
  {:event, event} ->
    IO.inspect(event.type)   # :tool_call, :llm_response, etc.
end
```

Use cases:
- Command Center SSE feed (HTTP server pushes events to browser)
- Test assertions on agent behavior without mocking
- Real-time debugging of a live session

### Query Past Events

```elixir
# All events in session
{:ok, events} = Events.Stream.events("session-abc")

# Only tool calls
{:ok, tool_calls} = Events.Stream.events("session-abc", type: :tool_call)

# Events since a timestamp
{:ok, recent} = Events.Stream.events("session-abc",
  since: DateTime.add(DateTime.utc_now(), -300, :second),
  limit: 50
)
```

### Time-Range Replay

```elixir
{:ok, events} = Events.Stream.replay(
  "session-abc",
  ~U[2026-03-14 10:00:00Z],
  ~U[2026-03-14 11:00:00Z]
)
```

Events are returned in chronological order (oldest first). The circular buffer
holds at most 1000 events per session. Sessions with very long tool chains may
roll older events off the front.

## JSONL Session Files — Durable Trace Log

Every session writes a JSONL file to `~/.daemon/sessions/<session_id>.jsonl`. Each
line is a JSON object representing one turn or memory entry. This is the primary
durable trace log for post-hoc analysis.

Structure of a session file:

```jsonl
{"role":"user","content":"Refactor the auth module","timestamp":"2026-03-14T10:00:00Z"}
{"role":"assistant","content":"I'll start by reading the current implementation...","timestamp":"...","tools_used":["read_file","write_file"]}
{"role":"observation","content":"Extracted 3 patterns from this session","timestamp":"...","kind":"learning"}
```

The session file grows during the conversation. At session end, the vault may
create a handoff document that summarizes the session in narrative form.

## Episodic Memory as Trace

`miosa_memory` maintains an episodic memory store in `~/.daemon/sessions/`. Each
session's JSONL file serves as both:

1. The conversation transcript (for replay via `Agent.Replay`)
2. A searchable episodic trace (retrieved by the memory subsystem on future
   sessions to provide historical context)

The learning engine annotates the JSONL file with extracted patterns:

```jsonl
{"kind":"pattern","content":"User prefers PostgreSQL over SQLite for production","confidence":0.92,"session_id":"session-abc","timestamp":"..."}
```

## Hook Execution Tracing

Per-hook timing is available from ETS `:daemon_hooks_metrics` without a GenServer
call:

```elixir
call_count = :ets.lookup_element(:daemon_hooks_metrics, {:pre_tool_use, :call_count}, 2)
total_us   = :ets.lookup_element(:daemon_hooks_metrics, {:pre_tool_use, :total_us},   2)
blocks     = :ets.lookup_element(:daemon_hooks_metrics, {:pre_tool_use, :blocks_count}, 2)

avg_latency_us = if call_count > 0, do: total_us / call_count, else: 0
```

This gives per-event-type hook chain average latency with no additional overhead.

## Provider Latency Tracing

`llm_response` events carry the full call duration:

```elixir
%{
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  duration_ms: 1842,
  usage: %{input_tokens: 1234, output_tokens: 567}
}
```

`Telemetry.Metrics` maintains a rolling window of the last 100 durations per
provider in `:daemon_telemetry` ETS. Reading the window at any point gives an
accurate p99 estimate:

```elixir
[{_, latencies}] = :ets.lookup(:daemon_telemetry, :provider_latency)
window = Map.get(latencies, :anthropic, [])
sorted = Enum.sort(window)
p99 = Enum.at(sorted, round(length(sorted) * 0.99) - 1, 0)
```

## Session Metadata via get_metadata/1

After each `process_message/3` call, metadata about the last turn is accessible:

```elixir
meta = Agent.Loop.get_metadata("session-abc")
# => %{iteration_count: 5, tools_used: ["read_file", "write_file", "run_tests"]}
```

This is used by channel adapters to display tool usage information in the UI
and by tests to assert on agent behavior without inspecting internal state.
