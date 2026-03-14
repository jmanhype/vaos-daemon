# Event Catalog

## Audience

Engineers subscribing to OSA events, debugging agent behavior, or adding new event emissions.

## Overview

All events are emitted via `OptimalSystemAgent.Events.Bus.emit/3` and carry the CloudEvents v1.0.2 envelope. This catalog describes the `data` field (payload) for each event type. All events also carry `id`, `type`, `source`, `time`, `session_id`, `correlation_id`, `parent_id`, and Signal Theory fields where relevant.

The event type atom is available as `payload.type` when received by handlers.

---

## :user_message

Emitted when a user sends a message to a channel. Currently not emitted in `Agent.Loop` (metrics track `llm_response` as a proxy for user turns). The handler is wired and will fire if emission is added.

```elixir
%{
  session_id: "sess-abc123",
  content: "Can you help me refactor this module?",
  channel: :cli                 # :cli | :telegram | :discord | :slack | :http | ...
}
```

---

## :llm_request

Emitted when the agent initiates an LLM call. Source: `"agent.loop"`.

```elixir
%{
  session_id: "sess-abc123",
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  message_count: 12,            # number of messages in context
  tool_count: 8                 # number of tools presented
}
```

---

## :llm_response

Emitted after a successful LLM call completes. Source: `"agent.loop"`. This is the primary event tracked by `Telemetry.Metrics` for latency, token usage, and provider call counts.

```elixir
%{
  session_id: "sess-abc123",
  provider: :anthropic,         # may be :unknown if not forwarded
  duration_ms: 1_243,
  success: true,
  usage: %{
    input_tokens: 2_150,
    output_tokens: 487
  },
  has_tool_calls: true,
  iteration: 3
}
```

---

## :tool_call

Emitted when the agent invokes a tool. Source: `"agent.loop"`.

```elixir
%{
  session_id: "sess-abc123",
  name: "read_file",            # tool name string
  call_id: "call_xyz789",       # LLM-assigned call ID
  args: %{"path" => "/foo/bar.ex"},
  iteration: 3
}
```

---

## :tool_result

Emitted when a tool execution completes. Source: `"tools.registry"` or `"tools.cached_executor"`. The `name` field (not `tool`) is used for metric tracking.

```elixir
%{
  session_id: "sess-abc123",
  name: "read_file",            # tool name (not :tool)
  call_id: "call_xyz789",
  success: true,
  duration_ms: 42,
  output_size_bytes: 1_024
}
```

---

## :agent_response

Emitted when the agent produces a final response for the user. Source: `"agent.loop"`.

```elixir
%{
  session_id: "sess-abc123",
  content: "I've refactored the module...",
  channel: :cli,
  iteration_count: 5,
  tools_used: ["read_file", "file_edit"]
}
```

---

## :system_event

Generic event for internal lifecycle signals. The `event` field specifies the subtype. Source varies. These events reach the TUI only for the subtypes listed in `Bridge.PubSub.@tui_system_events`.

### Subtypes relevant to TUI

```elixir
# sub-agent lifecycle
%{event: :sub_agent_started,   session_id: "...", agent_id: "...", task: "..."}
%{event: :sub_agent_completed, session_id: "...", agent_id: "...", result: "..."}

# orchestrator lifecycle
%{event: :orchestrator_started,          session_id: "...", task_count: 3}
%{event: :orchestrator_finished,         session_id: "...", success: true}
%{event: :orchestrator_agent_started,    session_id: "...", agent: "..."}
%{event: :orchestrator_agent_completed,  session_id: "...", agent: "...", result: "..."}

# skill / learning lifecycle
%{event: :skills_triggered,       session_id: "...", skills: ["skill_a"]}
%{event: :skill_evolved,          session_id: "...", skill: "skill_a", version: 2}
%{event: :skill_bootstrap_created, session_id: "...", skill: "skill_b"}

# safety / control
%{event: :doom_loop_detected,  session_id: "...", iteration: 15, reason: "repeated tool failure"}
%{event: :agent_cancelled,     session_id: "...", reason: "user_cancel"}
%{event: :budget_alert,        session_id: "...", spent_usd: 4.87, limit_usd: 5.0}
```

---

## :channel_connected

Emitted when a channel adapter establishes a connection. Source: the channel module name.

```elixir
%{
  channel: :telegram,
  channel_id: "chat-987",
  user_id: "tg-user-456"
}
```

---

## :channel_disconnected

Emitted when a channel adapter loses its connection.

```elixir
%{
  channel: :telegram,
  channel_id: "chat-987",
  reason: :timeout             # atom or string
}
```

---

## :channel_error

Emitted on non-fatal channel errors (e.g. message send failure).

```elixir
%{
  channel: :slack,
  error: "rate_limited",
  message: "Could not post to channel C01234"
}
```

---

## :ask_user_question

Emitted when the agent blocks waiting for user input via the `ask_user_question` tool. The HTTP endpoint `GET /sessions/:id/pending_questions` reads from `:osa_pending_questions` ETS which is also populated at this point.

```elixir
%{
  session_id: "sess-abc123",
  ref: "base64-encoded-ref",
  question: "Which test should I run first?",
  options: ["mix test", "mix test test/foo_test.exs"],
  asked_at: "2026-01-01T00:00:00Z"
}
```

---

## :survey_answered

Emitted when a user responds to an `ask_user_question` prompt.

```elixir
%{
  session_id: "sess-abc123",
  ref: "base64-encoded-ref",
  answer: "mix test test/foo_test.exs"
}
```

---

## :algedonic_alert

Emitted by `Events.Bus.emit_algedonic/3` for urgent bypass signals (Beer's VSM algedonic channel). Also emitted by `Events.DLQ` when a handler exhausts all retries.

```elixir
%{
  signal: :pain,                           # always :pain for alerts
  severity: :high,                         # :critical | :high | :medium | :low
  message: "DLQ: tool_result handler failed 3 times",
  metadata: %{
    event_type: :tool_result,
    last_error: "handler raised: FunctionClauseError",
    created_at: 1735689600000              # monotonic ms
  }
}
```

---

## Signal Theory Payload Fields

Every event struct carries Signal Theory dimensions. When auto-classified by `Events.Classifier.auto_classify/1`:

| Field | Type | Example values |
|-------|------|----------------|
| `signal_mode` | atom | `:data`, `:command`, `:query`, `:event`, `:stream` |
| `signal_genre` | atom | `:task`, `:conversation`, `:notification`, `:system` |
| `signal_type` | atom | `:request`, `:response`, `:acknowledgement` |
| `signal_format` | atom | `:json`, `:text`, `:binary` |
| `signal_structure` | atom | `:flat`, `:nested`, `:sequence` |
| `signal_sn` | float | `0.0`–`1.0` (signal-to-noise ratio) |

`signal_sn` below `0.20` causes `Agent.Loop` to skip tool dispatch and perform a plain chat call instead.
