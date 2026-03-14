# Event Contracts

OSA uses a two-layer event system:

1. **goldrush bus** (`OptimalSystemAgent.Events.Bus`) — in-process compiled-bytecode dispatch, zero-copy, sub-microsecond routing.
2. **Phoenix.PubSub** (`OptimalSystemAgent.PubSub`) — cross-process fan-out via the `Bridge.PubSub` GenServer.

Producers call `Bus.emit(event_type, payload)`. The bridge subscribes to all event types and fans each event out to four PubSub topics. Consumers (SSE handlers, TUI, monitoring) subscribe to PubSub topics, not to goldrush directly.

---

## Message Envelope

Every event map carries:

```elixir
%{
  type: atom(),          # event type atom (e.g. :agent_response)
  session_id: String.t() | nil,  # present on session-scoped events
  # ... event-specific fields
}
```

PubSub subscribers receive `{:osa_event, event_map}` tuples.

---

## PubSub Topic Contracts

| Topic | Subscribers | Content |
|---|---|---|
| `osa:events` | Firehose (monitoring, debugging) | All events |
| `osa:session:{session_id}` | SSE handlers for `/stream/:id`, TUI | Events where `session_id` matches |
| `osa:type:{event_type}` | Selective monitoring | Events of a specific type |
| `osa:tui:output` | Rust TUI SSE at `/stream/tui_output` | Agent-visible events only (filtered subset) |
| `osa:orchestrator:{task_id}` | Progress SSE at `/:task_id/progress/stream` | Progress update events for a task |

---

## Core Event Types

### `:llm_request`

Emitted before each LLM API call.

```elixir
%{
  type: :llm_request,
  session_id: String.t(),
  iteration: non_neg_integer(),
  agent: String.t()   # session_id acts as agent identifier
}
```

### `:llm_response`

Emitted after a successful LLM response.

```elixir
%{
  type: :llm_response,
  session_id: String.t(),
  content: String.t() | nil,
  tool_calls: [map()] | nil,
  model: String.t(),
  tokens_in: integer(),
  tokens_out: integer(),
  iteration: non_neg_integer()
}
```

### `:llm_chunk`

Emitted for each streaming token chunk (when streaming is enabled).

```elixir
%{
  type: :llm_chunk,
  session_id: String.t(),
  chunk: String.t()
}
```

### `:agent_response`

Emitted when the agent produces a final turn response.

```elixir
%{
  type: :agent_response,
  session_id: String.t(),
  response: String.t(),
  agent: String.t()
}
```

### `:tool_result`

Emitted after each tool call completes successfully.

```elixir
%{
  type: :tool_result,
  session_id: String.t(),
  tool_name: String.t(),
  result: String.t() | map(),
  iteration: non_neg_integer()
}
```

### `:tool_error`

Emitted when a tool call fails.

```elixir
%{
  type: :tool_error,
  session_id: String.t(),
  tool_name: String.t(),
  error: String.t(),
  iteration: non_neg_integer()
}
```

### `:signal_classified`

Emitted after Signal Theory classification of an inbound message.

```elixir
%{
  type: :signal_classified,
  session_id: String.t(),
  mode: String.t(),       # "reactive" | "proactive"
  genre: String.t(),      # "task" | "question" | "chat" | ...
  signal_type: String.t(),
  format: String.t(),
  weight: float()
}
```

### `:thinking_chunk`

Emitted during extended thinking (Anthropic reasoning models).

```elixir
%{
  type: :thinking_chunk,
  session_id: String.t(),
  chunk: String.t()
}
```

### `:strategy_changed`

Emitted when the agent reasoning strategy changes.

```elixir
%{
  type: :strategy_changed,
  strategy: String.t(),    # strategy module name
  requested_by: atom()     # :command | :auto
}
```

---

## System Events (`:system_event` wrapper)

Many lifecycle events are wrapped in the `:system_event` type. Consumers check `payload.event` for the sub-event name.

```elixir
%{
  type: :system_event,
  event: atom(),    # sub-event name
  # ... sub-event specific fields
}
```

### Orchestrator Sub-Events

**`:orchestrator_task_started`**
```elixir
%{type: :system_event, event: :orchestrator_task_started,
  task_id: String.t(), session_id: String.t(), message_preview: String.t()}
```

**`:orchestrator_task_decomposed`**
```elixir
%{type: :system_event, event: :orchestrator_task_decomposed,
  task_id: String.t(), session_id: String.t(),
  sub_task_count: integer(), estimated_tokens: integer(), complexity_score: float(),
  optimal_agent_count: integer()}
```

**`:orchestrator_agents_spawning`**
```elixir
%{type: :system_event, event: :orchestrator_agents_spawning,
  task_id: String.t(), session_id: String.t(),
  agent_count: integer(), agents: [%{name: String.t(), role: atom()}]}
```

**`:orchestrator_wave_started`**
```elixir
%{type: :system_event, event: :orchestrator_wave_started,
  task_id: String.t(), session_id: String.t(),
  wave_number: integer(), total_waves: integer(), agent_count: integer()}
```

**`:orchestrator_agent_progress`**
```elixir
%{type: :system_event, event: :orchestrator_agent_progress,
  task_id: String.t(), session_id: String.t(),
  agent_id: String.t(), agent_name: String.t(), role: atom(),
  tool_uses: integer(), tokens_used: integer(), current_action: String.t() | nil,
  description: String.t()}
```

**`:orchestrator_task_completed`**
```elixir
%{type: :system_event, event: :orchestrator_task_completed,
  task_id: String.t(), session_id: String.t(),
  agent_count: integer(), result_preview: String.t()}
```

**`:orchestrator_task_failed`**
```elixir
%{type: :system_event, event: :orchestrator_task_failed,
  task_id: String.t(), session_id: String.t(), reason: String.t()}
```

**`:orchestrator_task_appraised`**
```elixir
%{type: :system_event, event: :orchestrator_task_appraised,
  task_id: String.t(), session_id: String.t(),
  estimated_cost_usd: float(), estimated_hours: float()}
```

### Swarm Sub-Events

**`:swarm_started`**
```elixir
%{type: :system_event, event: :swarm_started,
  swarm_id: String.t(), session_id: String.t(), task: String.t()}
```

**`:swarm_completed`**
```elixir
%{type: :system_event, event: :swarm_completed,
  swarm_id: String.t(), session_id: String.t(), result: String.t()}
```

**`:swarm_failed`**
```elixir
%{type: :system_event, event: :swarm_failed,
  swarm_id: String.t(), session_id: String.t(), reason: String.t()}
```

**`:swarm_cancelled`**
```elixir
%{type: :system_event, event: :swarm_cancelled,
  swarm_id: String.t(), session_id: String.t()}
```

**`:swarm_timeout`**
```elixir
%{type: :system_event, event: :swarm_timeout,
  swarm_id: String.t(), session_id: String.t()}
```

### Task Queue Sub-Events

**`:task_created`**
```elixir
%{type: :system_event, event: :task_created,
  task_id: String.t(), subject: String.t(), active_form: String.t(), session_id: String.t()}
```

**`:task_leased`**
```elixir
%{type: :system_event, event: :task_leased,
  task_id: String.t(), agent_id: String.t()}
```

**`:task_completed`**
```elixir
%{type: :system_event, event: :task_completed, task_id: String.t()}
```

### Skill Sub-Events

**`:skill_evolved`**
```elixir
%{type: :system_event, event: :skill_evolved, skill_name: String.t()}
```

**`:skill_bootstrap_created`**
```elixir
%{type: :system_event, event: :skill_bootstrap_created, skill_name: String.t()}
```

**`:skills_triggered`**
```elixir
%{type: :system_event, event: :skills_triggered,
  skills: [String.t()], session_id: String.t()}
```

### Agent Lifecycle Sub-Events

**`:doom_loop_detected`**
```elixir
%{type: :system_event, event: :doom_loop_detected,
  session_id: String.t(), iteration: integer()}
```

**`:agent_cancelled`**
```elixir
%{type: :system_event, event: :agent_cancelled, session_id: String.t()}
```

**`:budget_alert`**
```elixir
%{type: :system_event, event: :budget_alert,
  type: :daily | :monthly | :per_call, spent_usd: float(), limit_usd: float()}
```

**`:sub_agent_started`**
```elixir
%{type: :system_event, event: :sub_agent_started,
  task_id: String.t(), agent_name: String.t()}
```

**`:sub_agent_completed`**
```elixir
%{type: :system_event, event: :sub_agent_completed,
  task_id: String.t(), agent_name: String.t(), status: atom()}
```

---

## Versioning Strategy

Events have no explicit version field. The implicit versioning contract is:

- **Addition is backward compatible.** New fields can be added to any event payload without incrementing a version. All consumers must handle unknown fields gracefully (pattern match on required fields only, ignore extras).

- **Removal or rename is a breaking change.** Any removal or rename of an existing field requires a coordinated update of all consumers before the producer changes. Because OSA is a single-deployment system with no external consumers of the internal bus, this is coordinated at the code level.

- **New event types are additive.** Adding a new event type to the bus does not break existing consumers. PubSub subscribers that do not know about a type simply receive and discard the message.

The SSE event type name on the wire is `to_string(payload.type)` for top-level events, or `to_string(payload.event)` for `:system_event` sub-events. TUI parsers must handle unknown event type strings without crashing.
