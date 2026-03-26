# Integrating a Subsystem

Audience: developers connecting an external system, a new Daemon subsystem, or a
third-party library into the Daemon runtime.

---

## Integrating with Events.Bus

The event bus is the primary integration point for observing or reacting to
what happens inside Daemon. Every significant action emits an event.

### Subscribe to events

```elixir
alias Daemon.Events.Bus

Bus.subscribe(:tool_call, fn event ->
  IO.inspect(event.payload, label: "tool_call")
end)
```

`subscribe/2` takes an event type atom and a handler function. The handler
receives a full `%Daemon.Events.Event{}` struct with:

- `id` — UUID
- `type` — the event type atom
- `payload` — map of event data
- `timestamp` — `DateTime.t()` in UTC
- `source` — origin string
- `session_id` — associated session (if any)
- `signal_mode` — Signal Theory classification (`:execute`, `:build`, etc.)
- `signal_genre` — communicative purpose (`:direct`, `:inform`, etc.)

### Emit events

```elixir
Bus.emit(:system_event, %{
  message: "Subsystem initialized",
  subsystem: :my_subsystem
})
```

Only emit event types that are in the allowed list. The bus rejects unknown
types with a `FunctionClauseError`. Allowed types:

```
:user_message  :llm_request     :llm_response    :tool_call
:tool_result   :agent_response  :system_event    :channel_connected
:channel_disconnected  :channel_error  :ask_user_question
:survey_answered  :algedonic_alert
```

### Failed handlers go to the DLQ

If a subscribed handler crashes, the event is placed in the Dead Letter Queue
(`Events.DLQ`) for retry with exponential backoff (1 s, 2 s, 4 s max 30 s,
up to 3 retries). After all retries fail, an `:algedonic_alert` event is
emitted and the entry is dropped.

---

## Integrating with Agent.Memory

Agent.Memory provides conversation-level persistence backed by SQLite. Use it
to store and retrieve messages within a session.

```elixir
alias Daemon.Agent.Memory

# Append a message to a session's conversation
Memory.append(session_id, %{
  role: "user",
  content: "Hello, Daemon!"
})

# Load full session message history
messages = Memory.load_session(session_id)

# Recall relevant context for a given message (semantic + keyword search)
context = Memory.recall_relevant("deployment pipeline", max_tokens: 2000)

# Save a durable memory (persisted to ~/.daemon/memory/)
Memory.remember("The user prefers Python over JavaScript", "preference")

# Search saved memories
results = Memory.search("Python")
```

`Memory` is an alias module — the implementation lives in `MiosaMemory.Store`.
Call `Memory.memory_stats/0` to see counts and sizes.

---

## Integrating with the Vault

The Vault is the structured long-term memory system. Unlike `Agent.Memory`
(conversation buffer), the Vault extracts facts, profiles context, and
provides semantically-aware injection.

```elixir
alias Daemon.Vault

# Store a memory with automatic fact extraction
{:ok, path} = Vault.remember(
  "Roberto prefers short answers and code over prose.",
  :preference,
  %{title: "communication_style"}
)

# Search vault memories
results = Vault.recall("communication preferences")
# => [{:preference, "communication_style", 0.92}, ...]

# Build a profiled context string for prompt injection
context_str = Vault.context(:default, session_id: session_id)
```

Categories (second argument to `remember/3`):

```
:fact        — objective facts about the user or environment
:preference  — stated or inferred preferences
:project     — project-specific knowledge
:contact     — information about people
:event       — time-bound events or occurrences
:general     — anything that does not fit the above
```

---

## Integrating with Tools.Registry

Register your own tools and call existing tools programmatically.

```elixir
alias Daemon.Tools.Registry, as: Tools

# Register a tool module
Tools.register(MyApp.Tools.WeatherTool)

# List all registered tools (returns a list of tool descriptor maps)
tools = Tools.list_tools()

# Execute a tool directly (bypasses hooks and permission tier enforcement)
{:ok, result} = Tools.execute("get_weather", %{"location" => "San Francisco"})
```

Direct execution bypasses the hook pipeline. In production code, prefer
letting the agent loop invoke tools — this ensures hooks (security checks,
budget guards) run correctly.

---

## Integrating with Phoenix.PubSub

For fan-out to multiple subscribers (e.g., feeding a WebSocket or SSE
endpoint), use `Phoenix.PubSub` directly on the named PubSub instance
`Daemon.PubSub`.

```elixir
# Subscribe your process to a topic
Phoenix.PubSub.subscribe(Daemon.PubSub, "session:#{session_id}")

# Receive messages in handle_info
def handle_info({:event, %{type: :agent_response} = event}, state) do
  send_to_websocket(state.socket, event.payload)
  {:noreply, state}
end

# Broadcast to all subscribers (from another process)
Phoenix.PubSub.broadcast(
  Daemon.PubSub,
  "session:#{session_id}",
  {:event, event}
)
```

Topics used by Daemon:

| Topic | Content |
|-------|---------|
| `"session:SESSION_ID"` | All events for a session |
| `"osa:algedonic"` | Algedonic alerts (budget, DLQ overflow) |

---

## Integrating with Configuration

Read application config at runtime:

```elixir
# Read a config value with a default
Application.get_env(:daemon, :my_setting, :default_value)

# Check a feature flag
if Application.get_env(:daemon, :feature_enabled, false) do
  # feature code
end
```

Write config at runtime (for testing or hot configuration):

```elixir
Application.put_env(:daemon, :my_setting, new_value)
```

For persistent configuration, use environment variables loaded by
`config/runtime.exs`. See
[Configuration Integration](./configuration-integration.md).

---

## Related

- [Connecting to Core Events](./connecting-to-core-events.md) — full event type reference
- [Configuration Integration](./configuration-integration.md) — runtime config and feature flags
- [Extending the Runtime](../building-on-core/extending-the-runtime.md) — implement tools, skills, channels
