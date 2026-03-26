# Connecting to Core Events

Audience: developers who need to observe, react to, or publish events in the
Daemon runtime.

---

## Subscription Model

Daemon uses two complementary mechanisms for event distribution:

| Mechanism | Use case |
|-----------|----------|
| `Events.Bus` + goldrush | One-to-one handler registration. Compiled bytecode routing. Best for internal components. |
| `Phoenix.PubSub` | Fan-out to multiple subscribers on named topics. Best for SSE, WebSockets, and external consumers. |

Both are available simultaneously. Most internal integrations use `Events.Bus`.
External clients and SSE endpoints use `Phoenix.PubSub`.

---

## Subscribing via Events.Bus

```elixir
alias Daemon.Events.Bus

Bus.subscribe(:tool_call, fn event ->
  # event is %Daemon.Events.Event{}
  IO.puts("Tool called: #{event.payload[:tool]}")
end)
```

To subscribe to multiple event types:

```elixir
for event_type <- [:tool_call, :tool_result, :agent_response] do
  Bus.subscribe(event_type, &handle_event/1)
end

defp handle_event(%{type: :tool_call} = event) do
  Logger.debug("Tool call: #{inspect(event.payload)}")
end

defp handle_event(%{type: :agent_response} = event) do
  Logger.info("Response: #{event.payload[:content]}")
end

defp handle_event(_event), do: :ok
```

---

## Available Event Types

### user_message

Emitted when a user sends a message through any channel.

```elixir
%{
  type: :user_message,
  payload: %{
    content: "Hello, Daemon!",
    session_id: "cli:abc123",
    user_id: "user_1",
    channel: :cli
  }
}
```

### llm_request

Emitted immediately before the LLM is called.

```elixir
%{
  type: :llm_request,
  payload: %{
    session_id: "cli:abc123",
    provider: :anthropic,
    model: "claude-opus-4-5",
    message_count: 12,
    tool_count: 8
  }
}
```

### llm_response

Emitted when the LLM returns a response (before tool execution).

```elixir
%{
  type: :llm_response,
  payload: %{
    session_id: "cli:abc123",
    provider: :anthropic,
    model: "claude-opus-4-5",
    has_tool_calls: true,
    tool_call_count: 2,
    input_tokens: 1240,
    output_tokens: 89,
    latency_ms: 1340
  }
}
```

### tool_call

Emitted before a tool is executed (after hooks pass).

```elixir
%{
  type: :tool_call,
  payload: %{
    session_id: "cli:abc123",
    tool: "file_read",
    arguments: %{"path" => "/etc/hosts"},
    call_id: "call_abc123"
  }
}
```

### tool_result

Emitted after a tool completes execution.

```elixir
%{
  type: :tool_result,
  payload: %{
    session_id: "cli:abc123",
    tool: "file_read",
    call_id: "call_abc123",
    success: true,
    output_bytes: 512,
    latency_ms: 3
  }
}
```

### agent_response

Emitted when the agent loop produces a final response for the user.

```elixir
%{
  type: :agent_response,
  payload: %{
    session_id: "cli:abc123",
    content: "Here is the result...",
    channel: :cli,
    chat_id: nil,
    tool_calls_made: 3,
    iterations: 4
  }
}
```

### system_event

General-purpose internal event. Emitted by the scheduler, heartbeat, and
other infrastructure components.

```elixir
%{
  type: :system_event,
  payload: %{
    message: "Heartbeat tick",
    subsystem: :scheduler
  }
}
```

### signal_classified

Emitted after the Signal Theory classifier assigns mode, genre, type, and
signal-to-noise ratio to an inbound message.

```elixir
%{
  type: :system_event,    # emitted as system_event with signal fields
  signal_mode: :execute,
  signal_genre: :direct,
  signal_sn: 0.87,
  payload: %{session_id: "cli:abc123"}
}
```

Signal mode values: `:execute`, `:build`, `:analyze`, `:maintain`, `:assist`

Signal genre values: `:direct`, `:inform`, `:commit`, `:decide`, `:express`

### algedonic_alert

Emitted when a critical condition requires operator attention.

```elixir
%{
  type: :algedonic_alert,
  payload: %{
    reason: :budget_exceeded,
    detail: "Daily budget of $50.00 exceeded",
    session_id: "cli:abc123"
  }
}
```

Reasons: `:budget_exceeded`, `:dlq_overflow`, `:provider_unavailable`,
`:rate_limited`

---

## Subscribing via Phoenix.PubSub

```elixir
# In a GenServer or LiveView
Phoenix.PubSub.subscribe(Daemon.PubSub, "session:#{session_id}")

# Handle in handle_info
def handle_info({:event, event}, state) do
  # event is %Daemon.Events.Event{}
  process_event(event)
  {:noreply, state}
end
```

### SSE Event Stream

The HTTP channel exposes a Server-Sent Events stream per session:

```
GET /api/v1/stream/:session_id
Authorization: Bearer <jwt>
Accept: text/event-stream
```

Each SSE message is a JSON-encoded `Event` struct. The stream is backed by
`Daemon.EventStream`, which buffers up to 1,000 events per session
in a circular buffer. Late subscribers receive recent history before live events.

---

## Emitting Custom Events

Custom events must use an existing event type. Use `:system_event` for
subsystem-internal notifications:

```elixir
Daemon.Events.Bus.emit(:system_event, %{
  subsystem: :my_subsystem,
  action: :initialized,
  detail: "MySubsystem ready with 3 workers"
})
```

Do not emit on behalf of other sessions (do not spoof `session_id`) and do
not emit `:algedonic_alert` unless you have confirmed a genuine operator-level
condition.

---

## Related

- [Integrating a Subsystem](./integrating-a-subsystem.md) — connect to Memory, Vault, Tools
- [Debugging Core](../debugging/debugging-core.md) — inspect event handlers at runtime
