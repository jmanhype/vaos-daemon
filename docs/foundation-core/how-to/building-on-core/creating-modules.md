# Creating Modules in Daemon

This guide covers how to create a new module that integrates properly with the Daemon supervision
tree, event bus, and tool registry.

## Audience

Elixir developers extending Daemon with new GenServers, tools, or subsystems.

## The Supervision Tree

Daemon organizes processes into four subsystem supervisors under a top-level `:rest_for_one`
supervisor. Pick the right home for your module:

| Subsystem | Supervisor | Purpose |
|-----------|-----------|---------|
| Registries, pub/sub, event bus, tools | `Supervisors.Infrastructure` | Core infrastructure |
| Channel adapters, session DynamicSupervisor | `Supervisors.Sessions` | User-facing I/O |
| Memory, hooks, scheduler, learning | `Supervisors.AgentServices` | Agent intelligence |
| Treasury, swarm, fleet, sidecars | `Supervisors.Extensions` | Optional subsystems |

A crash in Infrastructure restarts everything above it. A crash in AgentServices only restarts
sibling agent services. Choose your supervisor based on how critical your module is.

## GenServer Template

Here is the standard pattern used throughout Daemon. The key conventions are:

- Use a module-level `name: __MODULE__` registration for singletons.
- Use `Registry`-based naming for per-session processes.
- Store hot-path read data in `:persistent_term` to avoid GenServer bottlenecks.
- Store mutable shared data in ETS with `:public` access when many callers read concurrently.

```elixir
defmodule Daemon.MyFeature do
  @moduledoc """
  One-line description of what this module does.

  Describe its role in the system, what it depends on, and what depends on it.
  """
  use GenServer
  require Logger

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Public function that reads from :persistent_term — zero GenServer overhead."
  def get_cached_data do
    :persistent_term.get({__MODULE__, :data}, %{})
  end

  @doc "Public function that goes through the GenServer for serialized writes."
  def update_data(new_data) do
    GenServer.call(__MODULE__, {:update, new_data})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      data: Keyword.get(opts, :initial_data, %{})
    }

    # Seed :persistent_term so get_cached_data/0 works immediately after init.
    :persistent_term.put({__MODULE__, :data}, state.data)

    Logger.info("[MyFeature] started")
    {:ok, state}
  end

  @impl true
  def handle_call({:update, new_data}, _from, state) do
    updated = Map.merge(state.data, new_data)
    :persistent_term.put({__MODULE__, :data}, updated)
    {:reply, :ok, %{state | data: updated}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[MyFeature] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
```

## Registering in the Supervision Tree

Add your module to the appropriate supervisor's `init/1` child list. Order matters when
the supervisor strategy is `:rest_for_one`.

```elixir
# In Supervisors.AgentServices.init/1:
children = [
  Daemon.Agent.Memory,
  Daemon.Agent.Hooks,
  Daemon.MyFeature,   # Add here, after deps, before dependents
  # ...
]
```

For per-session processes (one process per conversation), use the existing
`Daemon.SessionSupervisor` DynamicSupervisor:

```elixir
# To start a session-scoped process:
DynamicSupervisor.start_child(
  Daemon.SessionSupervisor,
  {Daemon.MySessionModule, session_id: session_id, channel: :cli}
)
```

## Subscribing to Events

Daemon routes events through a goldrush-compiled `:daemon_event_router`. Valid event types are
declared in `Events.Bus` and include: `:user_message`, `:llm_request`, `:llm_response`,
`:tool_call`, `:tool_result`, `:agent_response`, `:system_event`.

Subscribe in your `init/1` callback. The handler runs in a supervised `Task`, so
crashes do not propagate to your GenServer.

```elixir
@impl true
def init(opts) do
  # Register an event handler for tool results.
  # The ref can be used later to unregister.
  ref = Daemon.Events.Bus.register_handler(:tool_result, fn event ->
    # event is a plain map with all Event struct fields:
    # :id, :type, :source, :payload, :session_id, :correlation_id, :timestamp
    payload = event[:payload] || %{}
    tool_name = Map.get(payload, :tool_name, "unknown")
    Logger.debug("[MyFeature] tool result received: #{tool_name}")
  end)

  {:ok, %{event_ref: ref}}
end
```

To emit an event from your module:

```elixir
Daemon.Events.Bus.emit(:system_event, %{
  event: :my_feature_updated,
  data: some_data
}, session_id: session_id, source: "my_feature")
```

## ETS Tables

If your module needs concurrent reads from many callers (e.g., during LLM loop execution),
create a named ETS table. Daemon creates its own tables at boot in `Application.start/2`
before the supervision tree starts.

For module-owned tables, create in `init/1`:

```elixir
@impl true
def init(_opts) do
  :ets.new(:my_feature_table, [
    :named_table,
    :public,
    :set,
    read_concurrency: true,
    write_concurrency: true
  ])
  {:ok, %{}}
end
```

Use `:bag` instead of `:set` when one key maps to multiple values (as `Events.Bus` does
for its `:daemon_event_handlers` table).

## Registry-Based Naming for Sessions

When you need one process per session rather than one singleton:

```elixir
def start_link(opts) do
  session_id = Keyword.fetch!(opts, :session_id)
  name = {:via, Registry, {Daemon.SessionRegistry, session_id}}
  GenServer.start_link(__MODULE__, opts, name: name)
end

# To look up a session process:
case Registry.lookup(Daemon.SessionRegistry, session_id) do
  [{pid, _}] -> pid
  [] -> nil
end
```

## What to Do Next

- To add a new tool the agent can call, see `building-on-core/extending-services.md`.
- To intercept tool calls before or after execution, see `building-on-core/custom-middleware.md`.
- To write tests for your GenServer, see `testing/test-patterns.md`.
