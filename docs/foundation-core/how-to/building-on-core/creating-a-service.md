# Creating a Service

Audience: developers adding a new GenServer to the Daemon supervision tree.

A "service" in Daemon terms is a supervised GenServer that runs for the lifetime
of the application (or a session). This guide covers how to choose the right
supervisor, implement the GenServer, and wire it into the tree.

---

## Choose the Right Supervisor

Daemon has four subsystem supervisors. Pick the one whose lifecycle and failure
semantics match your service.

| Supervisor | Strategy | Use when |
|------------|----------|----------|
| `Supervisors.Infrastructure` | `:rest_for_one` | Your service is a foundational dependency (registries, buses, storage). A crash here should restart everything above. |
| `Supervisors.Sessions` | `:one_for_one` | Your service manages channels or sessions. Failures are isolated. |
| `Supervisors.AgentServices` | `:one_for_one` | Your service provides agent intelligence (memory, learning, scheduling). Failures should not cascade. |
| `Supervisors.Extensions` | `:one_for_one` | Your service is opt-in, feature-flagged, or external. Failures must never affect core. |

Most new services belong in `AgentServices` or `Extensions`.

If you are adding a channel adapter, see
[Creating a Channel](../extending-the-runtime.md) instead — channel adapters
start under `Channels.Supervisor` (a DynamicSupervisor), not a static child
list.

---

## Define the Module

Create the file in the appropriate subdirectory of `lib/daemon/`.
Follow the naming convention: `snake_case.ex` for the file,
`Daemon.YourModule` for the module.

```elixir
defmodule Daemon.MyService do
  @moduledoc """
  One-sentence summary of what this service does.

  Longer description: purpose, data owned, interactions with other components.
  """

  use GenServer
  require Logger

  # Client API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Description of what this call does."
  @spec do_something(term()) :: {:ok, term()} | {:error, term()}
  def do_something(arg) do
    GenServer.call(__MODULE__, {:do_something, arg})
  end

  @doc "Fire-and-forget operation."
  @spec notify(term()) :: :ok
  def notify(payload) do
    GenServer.cast(__MODULE__, {:notify, payload})
  end

  # Callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Logger.info("[MyService] Starting")
    state = %{
      option: Keyword.get(opts, :option, :default)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:do_something, arg}, _from, state) do
    result = compute(arg, state)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast({:notify, payload}, state) do
    Logger.debug("[MyService] Received notification: #{inspect(payload)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_tick, state) do
    # Handle messages sent via Process.send_after/3
    {:noreply, state}
  end

  # Private ────────────────────────────────────────────────────────────

  defp compute(arg, _state) do
    # Implementation
    arg
  end
end
```

### Rules

- Use `handle_call` for synchronous operations that return a value.
- Use `handle_cast` for fire-and-forget updates where the caller does not need
  a result.
- Use `handle_info` for messages sent with `send/2` or `Process.send_after/3`.
- Keep `init/1` fast. Do not make network calls or blocking operations in
  `init`. Use `{:ok, state, {:continue, :init}}` to defer slow initialization:

```elixir
@impl true
def init(opts) do
  {:ok, %{opts: opts}, {:continue, :init}}
end

@impl true
def handle_continue(:init, state) do
  # slow initialization here
  {:noreply, state}
end
```

---

## Add to the Supervisor

Open the supervisor file for the subsystem you chose. Add your module to the
`children` list.

Example: adding to `AgentServices`:

```elixir
# lib/daemon/supervisors/agent_services.ex

children = [
  Daemon.Agent.Memory,
  Daemon.Agent.HeartbeatState,
  # ...existing children...
  Daemon.MyService,   # <-- add here
  Daemon.Agent.Scheduler,
  # ...
]
```

Child order matters when the strategy is `:rest_for_one`. In `AgentServices`
the strategy is `:one_for_one`, so order is less critical — but place your
service after any services it depends on.

### Child spec

`use GenServer` provides a default `child_spec/1` that is sufficient in most
cases. If you need to customize the restart strategy or shutdown timeout:

```elixir
def child_spec(opts) do
  %{
    id: __MODULE__,
    start: {__MODULE__, :start_link, [opts]},
    restart: :permanent,
    shutdown: 5_000,
    type: :worker
  }
end
```

---

## Verify the Service Starts

```sh
iex -S mix
```

```elixir
# In IEx
Process.whereis(Daemon.MyService)
# => #PID<0.xxx.0>

:sys.get_state(Daemon.MyService)
# => %{option: :default}
```

If `Process.whereis/1` returns `nil`, the service did not start. Check:

1. The module name in the supervisor's `children` list matches exactly.
2. `start_link/1` is defined and returns `{:ok, pid}`.
3. `init/1` does not crash — check logs with `:observer.start()` or
   `Logger` output.

---

## Using ETS for Shared State

If your service needs concurrent read access from multiple callers, back it
with ETS rather than funneling every read through the GenServer.

Pattern: GenServer owns writes, ETS serves reads.

```elixir
@table :my_service_data

def init(_opts) do
  :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
  {:ok, %{}}
end

def handle_call({:put, key, value}, _from, state) do
  :ets.insert(@table, {key, value})
  {:reply, :ok, state}
end

# Call from any process without going through the GenServer
def get(key) do
  case :ets.lookup(@table, key) do
    [{^key, value}] -> {:ok, value}
    [] -> :error
  end
end
```

Create the ETS table in `application.ex` instead of `init/1` if the table
must survive process restarts (i.e., it is owned by the application-level
process, not by your GenServer).

---

## Related

- [Creating a Module](./creating-a-module.md) — naming and placement conventions
- [Registering Components](./registering-components.md) — register tools, hooks, commands
- [Debugging Core](../debugging/debugging-core.md) — inspect running services
