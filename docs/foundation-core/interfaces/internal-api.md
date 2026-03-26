# Internal API

Audience: Daemon core contributors and developers building integrations that call
into Daemon from within the same BEAM node.

This document covers the internal Elixir API surface — the public functions on
Daemon's core GenServers and registries that are safe to call from application code.
All modules listed here are part of the `Daemon` OTP application.

---

## Agent.Loop

**Module:** `Daemon.Agent.Loop`

The bounded ReAct agent loop. One process per session, started on demand and
registered in `Daemon.SessionRegistry` under `{session_id, user_id}`.

### send_message / process_message

```elixir
@spec process_message(session_id :: String.t(), message :: String.t(), opts :: keyword()) ::
  {:ok, String.t()} | {:error, term()}
```

Deliver a user message to the agent loop for a session. Blocks until the agent
produces a final response (synchronous call with `:infinity` timeout).

```elixir
{:ok, reply} = Daemon.Agent.Loop.process_message(
  "session-abc",
  "Summarise the last deployment",
  provider: :anthropic,
  model: "claude-opus-4-5"
)
```

Options:

| Key | Type | Description |
|---|---|---|
| `:provider` | atom | Override the default LLM provider for this call. |
| `:model` | string | Override the default model for this call. |
| `:signal_weight` | float | Pre-computed signal weight (0.0–1.0). Weights below 0.20 suppress tool calls. |

### get_state

```elixir
@spec get_state(session_id :: String.t()) ::
  {:ok, map()} | {:error, :not_found}
```

Return the current loop state for a running session.

```elixir
{:ok, state} = Daemon.Agent.Loop.get_state("session-abc")
# state.status       => :idle | :running
# state.turn_count   => integer
# state.last_meta    => %{iteration_count: 3, tools_used: ["file_read", "shell_execute"]}
```

### cancel

```elixir
@spec cancel(session_id :: String.t()) :: :ok
```

Signal a running loop to stop after its current iteration. Sets an ETS flag
read by the loop at each iteration. Returns `:ok` immediately; the loop may
run one more iteration before halting.

```elixir
:ok = Daemon.Agent.Loop.cancel("session-abc")
```

---

## Agent.Memory

**Module:** `Daemon.Agent.Memory`

Delegate module over `MiosaMemory.Store`. Manages per-session conversation
history and long-term cross-session memories. Storage: JSONL files at
`~/.daemon/sessions/<session_id>.jsonl` and `~/.daemon/memory.jsonl`.

### save / remember

```elixir
@spec remember(content :: String.t(), category :: String.t()) :: :ok
```

Save a fact to long-term memory. Category is used for retrieval grouping.

```elixir
:ok = Daemon.Agent.Memory.remember(
  "User prefers dark mode and uses neovim",
  "preferences"
)
```

### recall

```elixir
@spec recall() :: String.t()
```

Return the full long-term memory file content as a string, formatted for
prompt injection.

```elixir
context = Daemon.Agent.Memory.recall()
```

### search

```elixir
@spec search(query :: String.t(), opts :: keyword()) ::
  {:ok, [map()]} | {:error, term()}
```

Search memory entries by keyword match.

```elixir
{:ok, entries} = Daemon.Agent.Memory.search("neovim", limit: 5)
```

### append

```elixir
@spec append(session_id :: String.t(), entry :: map()) :: :ok
```

Append a message entry to a session's conversation log. Used internally by
the loop after each turn.

---

## Tools.Registry

**Module:** `Daemon.Tools.Registry`

Central registry for all callable tools (built-in Elixir modules + SKILL.md
files + MCP server tools). The registry maintains an ETS-backed persistent_term
store for lock-free reads from concurrent session processes.

### register

```elixir
@spec register(tool_module :: module()) :: :ok
```

Register a module implementing `MiosaTools.Behaviour`. The goldrush dispatcher
is recompiled automatically. The tool is immediately available to the LLM.

```elixir
:ok = Daemon.Tools.Registry.register(MyApp.Tools.SlackPost)
```

### lookup / list_tools_direct

```elixir
@spec list_tools_direct() :: [%{name: String.t(), description: String.t(), parameters: map()}]
```

Return all registered tools in the LLM schema format. Lock-free via
`:persistent_term`. Safe to call from inside GenServer callbacks.

```elixir
tools = Daemon.Tools.Registry.list_tools_direct()
# [%{name: "file_read", description: "...", parameters: %{...}}, ...]
```

### dispatch / execute

```elixir
@spec execute(tool_name :: String.t(), arguments :: map()) ::
  {:ok, any()} | {:error, String.t()}
```

Execute a named tool with the given arguments. Arguments are validated against
the tool's JSON Schema before `execute/1` is called on the module.

```elixir
{:ok, result} = Daemon.Tools.Registry.execute(
  "file_read",
  %{"path" => "/tmp/report.txt"}
)
```

MCP tools (prefixed `mcp_`) are routed to `Daemon.MCP.Client.call_tool/2`.

### search

```elixir
@spec search(query :: String.t()) :: [{String.t(), String.t(), float()}]
```

Search registered tools and skills by keyword. Returns `{name, description, score}` tuples,
sorted by relevance (0.0–1.0).

```elixir
results = Daemon.Tools.Registry.search("read file")
# [{"file_read", "Read the contents of a file", 0.85}, ...]
```

---

## Providers.Registry

**Module:** `Daemon.Providers.Registry`

LLM provider routing, fallback chains, and dynamic provider registration.
Supports 18 providers across local, OpenAI-compatible, and native API categories.

### chat

```elixir
@spec chat(messages :: list(map()), opts :: keyword()) ::
  {:ok, %{content: String.t(), tool_calls: list(map())}} | {:error, String.t()}
```

Send a chat completion request. Uses the configured default provider unless
overridden via options. Applies the fallback chain automatically on failure.

```elixir
{:ok, response} = Daemon.Providers.Registry.chat(
  [%{role: "user", content: "Hello"}],
  provider: :groq,
  model: "llama-3.3-70b-versatile",
  temperature: 0.7
)

response.content    # => "Hello! How can I help?"
response.tool_calls # => []
```

### swap_provider / register_provider

```elixir
@spec register_provider(name :: atom(), module :: module()) :: :ok
```

Register a custom provider module at runtime.

```elixir
:ok = Daemon.Providers.Registry.register_provider(
  :bedrock,
  MyApp.Providers.Bedrock
)
```

### provider_configured?

```elixir
@spec provider_configured?(provider :: atom()) :: boolean()
```

Check whether a provider has the required API keys configured.

```elixir
Daemon.Providers.Registry.provider_configured?(:anthropic)
# => true | false
```

---

## Events.Bus

**Module:** `Daemon.Events.Bus`

Zero-overhead event bus backed by a goldrush-compiled BEAM bytecode router.
All internal agent lifecycle events flow through this bus.

### emit

```elixir
@spec emit(event_type :: atom(), payload :: map(), opts :: keyword()) ::
  {:ok, Daemon.Events.Event.t()}
```

Emit an event. The payload is wrapped in an `Event` struct with UUID, timestamp,
and signal classification before routing.

Valid event types: `:user_message`, `:llm_request`, `:llm_response`,
`:tool_call`, `:tool_result`, `:agent_response`, `:system_event`,
`:channel_connected`, `:channel_disconnected`, `:channel_error`,
`:ask_user_question`, `:survey_answered`, `:algedonic_alert`.

```elixir
{:ok, event} = Daemon.Events.Bus.emit(
  :system_event,
  %{event: :deployment_complete, environment: "production"},
  source: "deploy-agent",
  session_id: "session-abc"
)
```

Options:

| Key | Type | Description |
|---|---|---|
| `:source` | string | Origin identifier. Default: `"bus"`. |
| `:parent_id` | string | Parent event ID for causality tracing. |
| `:session_id` | string | Session context. Enables per-session event streaming. |
| `:correlation_id` | string | Groups related events for distributed tracing. |
| `:signal_mode` | atom | Signal Theory mode override. |
| `:signal_genre` | atom | Signal Theory genre override. |
| `:signal_sn` | float | Signal-to-noise ratio (0.0–1.0). |

### subscribe / register_handler

```elixir
@spec register_handler(event_type :: atom(), handler_fn :: (map() -> any())) :: reference()
```

Register a handler function for an event type. Returns a reference for
later deregistration. Handlers run in supervised Task processes — a crashing
handler is logged and enqueued to the dead-letter queue.

```elixir
ref = Daemon.Events.Bus.register_handler(:tool_call, fn event ->
  Logger.info("Tool called: #{event.payload.tool_name}")
end)
```

### unsubscribe / unregister_handler

```elixir
@spec unregister_handler(event_type :: atom(), ref :: reference()) :: :ok
```

Remove a previously registered handler.

```elixir
:ok = Daemon.Events.Bus.unregister_handler(:tool_call, ref)
```

---

## Commands

Custom commands are markdown files loaded from `~/.daemon/commands/`. They are
not a GenServer API but a file-driven extension mechanism. See
[extension-interfaces.md](./extension-interfaces.md) for authoring commands.

### register (file-based)

Place a `.md` file in `~/.daemon/commands/`:

```
~/.daemon/commands/
└── deploy.md
```

### dispatch

```elixir
Daemon.Command.Center.dispatch("/deploy staging")
```

The command center parses the slash command, matches it to a registered command
file, and calls the associated skill or handler.

---

## Agent.Hooks

**Module:** `Daemon.Agent.Hooks`

Middleware pipeline for agent lifecycle events. Hooks run in priority order
before and after tool calls.

### register

```elixir
@spec register(
  event :: hook_event(),
  name :: String.t(),
  handler :: hook_fn(),
  opts :: keyword()
) :: :ok
```

Register a hook. Lower priority number runs first (default: 50).

```elixir
Daemon.Agent.Hooks.register(
  :pre_tool_use,
  "rate-limit-check",
  fn payload ->
    if RateLimiter.exceeded?(payload.session_id) do
      {:block, "Rate limit exceeded for this session"}
    else
      {:ok, payload}
    end
  end,
  priority: 20
)
```

Hook handler return values:

| Return | Effect |
|---|---|
| `{:ok, payload}` | Continue to next hook with (possibly modified) payload. |
| `{:block, reason}` | Stop the chain; tool call is rejected with `reason`. Only valid for `pre_tool_use`. |
| `:skip` | Skip this hook silently; pass the unmodified payload to the next hook. |

### run

```elixir
@spec run(event :: hook_event(), payload :: map()) ::
  {:ok, map()} | {:blocked, String.t()}
```

Execute all hooks for an event in priority order. Called internally by the
agent loop. Reads from ETS in the caller's process — no GenServer bottleneck.
