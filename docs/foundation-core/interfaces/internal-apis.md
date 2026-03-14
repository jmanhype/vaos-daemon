# Internal Module APIs

This document describes the public function signatures and GenServer interfaces
that modules within OSA call on each other. These are internal contracts — not
exposed over HTTP.

---

## Agent Loop (`OptimalSystemAgent.Agent.Loop`)

The core ReAct reasoning engine. Each live session has one Loop GenServer,
registered in `OptimalSystemAgent.SessionRegistry` under the `session_id` key.

**GenServer interface:**

```elixir
# Start a loop for a session (called by Channels.Session.ensure_loop/3)
{Loop, session_id: String.t(), user_id: String.t(), channel: atom()}

# Process a message in an existing session (async via Task)
Loop.process_message(session_id :: String.t(), message :: String.t(), opts :: keyword()) :: :ok

# Cancel an active loop iteration
Loop.cancel(session_id :: String.t()) :: :ok | {:error, :not_running}

# Ask the user an in-session survey question (used by Orchestrator during decomposition)
Loop.ask_user_question(
  session_id :: String.t(),
  survey_id :: String.t(),
  questions :: [map()],
  opts :: keyword()
) :: {:ok, [map()]} | {:skipped} | {:error, term()}
```

**GenServer calls handled:**

```elixir
# Hot-swap provider on a live session
GenServer.call(pid, {:swap_provider, provider :: String.t(), model :: String.t() | nil})
# Returns :ok | {:error, reason}
```

**Key options for `process_message/3`:**
- `skip_plan: boolean` — bypass planning mode
- `working_dir: String.t()` — override the working directory for file tools
- `strategy: module` — override the reasoning strategy module

---

## Orchestrator (`OptimalSystemAgent.Agent.Orchestrator`)

Single named GenServer managing all multi-agent tasks.

```elixir
# Launch a multi-agent task (async; reply is immediate)
Orchestrator.execute(
  message :: String.t(),
  session_id :: String.t(),
  opts :: keyword()
) :: {:ok, task_id :: String.t()} | {:error, term()}

# Poll task progress
Orchestrator.progress(task_id :: String.t()) :: {:ok, map()} | {:error, :not_found}

# List all tasks (running + recently completed)
Orchestrator.list_tasks() :: [map()]

# Dynamic skill creation
Orchestrator.create_skill(
  name :: String.t(),
  description :: String.t(),
  instructions :: String.t(),
  tools :: [String.t()]
) :: {:ok, String.t()} | {:error, term()}

# Check for existing skills before creating a new one
Orchestrator.find_matching_skills(task_description :: String.t())
  :: {:matches, [map()]} | :no_matches

Orchestrator.suggest_or_create_skill(name, description, instructions, tools)
  :: {:existing_matches, [map()]} | {:created, String.t()} | {:error, term()}
```

**`execute/3` options:**
- `strategy: "auto" | "pact"` — orchestration strategy
- `max_agents: integer` — cap on sub-agent count
- `tier: :specialist | :elite` — agent tier for model selection
- `cached_tools: [map()]` — pre-fetched tool list to avoid GenServer deadlock
- `quality_threshold: float` — PACT quality gate (0.0–1.0)

**GenServer casts received:**
```elixir
# Progress update from a running sub-agent
{:agent_progress, task_id, agent_id, update :: map()}

# PACT workflow completion
{:pact_complete, task_id, session_id, synthesis :: String.t(), status :: atom()}
```

---

## SwarmMode (`OptimalSystemAgent.Agent.Orchestrator.SwarmMode`)

Manages swarm lifecycles. Max 10 concurrent swarms.

```elixir
SwarmMode.launch(task :: String.t(), opts :: keyword())
  :: {:ok, swarm_id :: String.t()} | {:error, term()}

SwarmMode.status(swarm_id :: String.t())
  :: {:ok, swarm_map} | {:error, :not_found}

SwarmMode.cancel(swarm_id :: String.t())
  :: :ok | {:error, :not_found | term()}

SwarmMode.list_swarms()
  :: {:ok, [swarm_map]} | {:error, term()}
```

**launch opts:** `:pattern` (`:parallel | :pipeline | :debate | :review`), `:timeout_ms`, `:max_agents`, `:session_id`

---

## Memory (`OptimalSystemAgent.Agent.Memory`)

Thin delegate to `MiosaMemory.Store`. All functions are synchronous.

```elixir
Memory.append(session_id :: String.t(), entry :: map()) :: :ok
Memory.load_session(session_id :: String.t()) :: [map()] | nil
Memory.remember(content :: String.t(), category :: String.t()) :: {:ok, String.t()} | {:error, term()}
Memory.recall() :: String.t()
Memory.recall_relevant(message :: String.t(), max_tokens :: integer()) :: String.t()
Memory.search(query :: String.t(), opts :: keyword()) :: [map()]
Memory.list_sessions() :: [map()]
Memory.session_stats(session_id :: String.t()) :: map()
Memory.memory_stats() :: map()
Memory.archive(max_age_days :: integer()) :: {:ok, integer()}
```

**Session entry shape** (persisted as JSONL):
```elixir
%{
  "role"      => "user" | "assistant" | "tool" | "system",
  "content"   => String.t() | nil,
  "tool_calls" => map() | nil,
  "timestamp" => String.t()
}
```

---

## Tools Registry (`OptimalSystemAgent.Tools.Registry`)

Manages builtin tools, SKILL.md files, and MCP tools.

```elixir
# List tools for LLM function calling schema (GenServer call)
Tools.Registry.list_tools() :: [%{name: String.t(), description: String.t(), parameters: map()}]

# List tools without GenServer (safe inside callbacks — reads :persistent_term)
Tools.Registry.list_tools_direct() :: [tool_map]

# Execute a tool by name (safe inside callbacks — reads :persistent_term)
Tools.Registry.execute_direct(name :: String.t(), args :: map()) :: {:ok, any()} | {:error, String.t()}

# Register a new tool module at runtime
Tools.Registry.register(module :: module()) :: :ok | {:error, term()}

# Match skill triggers against a message
Tools.Registry.match_skill_triggers(message :: String.t()) :: [{name :: String.t(), trigger :: String.t()}]
```

Tool modules implement `MiosaTools.Behaviour`:
```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()           # JSON Schema object
@callback execute(args :: map()) :: {:ok, any()} | {:error, String.t()}
@callback available?() :: boolean()
@callback safety() :: :safe | :write_safe | :destructive
```

---

## Session Management (`OptimalSystemAgent.Channels.Session`)

```elixir
# Ensure a Loop GenServer exists for a session; creates one if not present
Session.ensure_loop(
  session_id :: String.t(),
  user_id :: String.t(),
  channel :: atom()
) :: :ok | {:error, term()}
```

Sessions are registered in `OptimalSystemAgent.SessionRegistry` (a `Registry` with `:unique` keys). Registry value is the `user_id` (owner).

---

## Events Bus (`OptimalSystemAgent.Events.Bus`)

goldrush-backed in-process event bus. All events are fan-out to the Bridge.PubSub bridge.

```elixir
# Emit an event to all handlers registered for event_type
Bus.emit(event_type :: atom(), payload :: map()) :: :ok

# List all registered event types
Bus.event_types() :: [atom()]

# Register a handler for an event type
Bus.register_handler(event_type :: atom(), handler :: (map() -> any())) :: :ok
```

**Core event types emitted by the agent loop:**

| Event type | When |
|---|---|
| `:llm_request` | Before calling the LLM |
| `:llm_response` | After LLM returns |
| `:llm_chunk` | Each streaming token |
| `:agent_response` | Final agent turn response |
| `:tool_result` | After each tool execution |
| `:tool_error` | When a tool fails |
| `:signal_classified` | After Signal Theory classification |
| `:system_event` | Lifecycle events (see below) |

**`:system_event` sub-events** (in `payload.event`):
`orchestrator_task_started`, `orchestrator_task_decomposed`, `orchestrator_agents_spawning`,
`orchestrator_wave_started`, `orchestrator_agent_progress`, `orchestrator_task_completed`,
`orchestrator_task_failed`, `swarm_started`, `swarm_completed`, `swarm_failed`,
`task_created`, `task_completed`, `task_leased`, `skill_evolved`, `budget_alert`,
`doom_loop_detected`, `agent_cancelled`, `streaming_token`, `thinking_delta`.

---

## PubSub Bridge (`OptimalSystemAgent.Bridge.PubSub`)

Bridges goldrush events to `Phoenix.PubSub`. Subscription functions:

```elixir
Bridge.PubSub.subscribe_firehose()              # topic: "osa:events"
Bridge.PubSub.subscribe_session(session_id)     # topic: "osa:session:{id}"
Bridge.PubSub.subscribe_type(event_type)        # topic: "osa:type:{atom}"
Bridge.PubSub.subscribe_tui_output()            # topic: "osa:tui:output"
```

All subscribers receive `{:osa_event, event_map}` messages.

**TUI-visible topic** (`osa:tui:output`) receives a filtered subset:
`llm_chunk`, `llm_response`, `agent_response`, `tool_result`, `tool_error`,
`thinking_chunk`, `agent_message`, `signal_classified`, plus system sub-events:
`skills_triggered`, `sub_agent_started`, `sub_agent_completed`,
`orchestrator_started`, `orchestrator_finished`, `skill_evolved`, `budget_alert`.

---

## Provider Registry (`OptimalSystemAgent.Providers.Registry`)

Routes LLM calls across 18 providers with automatic fallback.

```elixir
# Primary entry point — routes to default or specified provider
Providers.Registry.chat(
  messages :: [map()],
  opts :: keyword()
) :: {:ok, %{content: String.t(), tool_calls: [map()] | nil, model: String.t()}}
   | {:error, term()}

# List all available providers
Providers.Registry.list_providers() :: [{atom(), map()}]

# Get info about a specific provider
Providers.Registry.provider_info(provider :: atom()) :: {:ok, map()} | {:error, :not_found}
```

**`chat/2` options:** `:provider` (atom), `:model` (string), `:temperature`, `:max_tokens`, `:tools` (function schema list), `:stream` (boolean), `:thinking` (boolean)

Provider modules implement `OptimalSystemAgent.Providers.Behaviour`:
```elixir
@callback name() :: atom()
@callback default_model() :: String.t()
@callback available_models() :: [String.t()]
@callback chat(messages :: [map()], opts :: keyword()) :: {:ok, map()} | {:error, term()}
@callback chat_stream(messages, callback :: function(), opts) :: :ok | {:error, term()}
```

---

## Vault (`OptimalSystemAgent.Vault`)

Facade over the filesystem-backed structured memory system.

```elixir
Vault.remember(content :: String.t(), category :: atom() | String.t(), opts :: map())
  :: {:ok, path :: String.t()} | {:error, term()}

Vault.recall(query :: String.t(), opts :: keyword())
  :: [{category :: atom(), path :: String.t(), score :: float()}]

Vault.context(profile :: atom(), opts :: keyword()) :: String.t()   # for prompt injection
Vault.inject(message :: String.t()) :: String.t()   # keyword-matched prompt injection
Vault.wake(session_id :: String.t()) :: {:ok, :clean | :recovered}
Vault.sleep(session_id :: String.t(), context :: map()) :: :ok
Vault.checkpoint(session_id :: String.t()) :: :ok
```

Categories: `:fact`, `:decision`, `:lesson`, `:preference`, `:commitment`, `:relationship`, `:project`, `:observation`

Storage path: `~/.osa/vault/{category}/{slug}.md` (markdown with YAML frontmatter)
