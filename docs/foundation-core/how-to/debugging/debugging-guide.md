# Debugging OSA

A practical guide to debugging a running OSA instance using IEx, `:observer`, process
inspection, event tracing with goldrush, and log analysis.

## Audience

Developers investigating issues in a running or recently-crashed OSA instance.

---

## Starting an IEx Session

```bash
# Development — start OSA with an interactive shell:
iex -S mix

# Attach to a running node (if started with --name):
iex --name debug@127.0.0.1 --cookie osa_dev --remsh osa@127.0.0.1
```

---

## Supervision Tree Inspection

### View the Full Tree

```elixir
# In IEx:
Supervisor.which_children(OptimalSystemAgent.Supervisor)
# => [
#   {OptimalSystemAgent.Supervisors.Infrastructure, #PID<0.123.0>, :supervisor, [...]},
#   {OptimalSystemAgent.Supervisors.Sessions, #PID<0.124.0>, :supervisor, [...]},
#   ...
# ]

# Drill into a subsystem:
Supervisor.which_children(OptimalSystemAgent.Supervisors.AgentServices)
```

### Check Process Status

```elixir
# Is a specific GenServer alive?
Process.whereis(OptimalSystemAgent.Events.Bus)
Process.whereis(OptimalSystemAgent.Agent.Hooks)
Process.whereis(OptimalSystemAgent.Tools.Registry)

# Get process info:
Process.info(Process.whereis(OptimalSystemAgent.Agent.Hooks))
# => [registered_name: OptimalSystemAgent.Agent.Hooks, memory: 12345, ...]
```

### List All Sessions

```elixir
# All active agent sessions in the SessionRegistry:
Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
# => ["cli_abc123", "telegram_456", ...]

# Get info about a specific session:
case Registry.lookup(OptimalSystemAgent.SessionRegistry, "cli_abc123") do
  [{pid, _}] ->
    :sys.get_state(pid)
  [] ->
    IO.puts("Session not found")
end
```

---

## Observer

`:observer` is the graphical process inspector. It shows the full process tree, memory usage,
ETS tables, and message queues.

```elixir
:observer.start()
```

Key tabs:
- **System** — BEAM VM overview, scheduler utilization.
- **Processes** — All running processes, sortable by memory or message queue length. A
  growing message queue on a GenServer indicates it is falling behind.
- **Tables** — All ETS tables. Inspect `:osa_hooks`, `:osa_event_handlers`,
  `:osa_cancel_flags`, `:osa_files_read`, `:osa_survey_answers` directly.
- **Applications** — The OSA supervision tree in graphical form.

---

## Inspecting GenServer State

```elixir
# Hooks state:
:sys.get_state(OptimalSystemAgent.Agent.Hooks)

# Tools registry state (built-in tools map + skills map):
:sys.get_state(OptimalSystemAgent.Tools.Registry)

# Events bus state:
:sys.get_state(OptimalSystemAgent.Events.Bus)

# A specific session's loop state:
[{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, "cli_abc123")
:sys.get_state(pid)
# => %{session_id: "cli_abc123", messages: [...], provider: :anthropic, ...}
```

---

## ETS Table Inspection

OSA stores hot-path data in named ETS tables. Inspect them directly:

```elixir
# List all event handlers:
:ets.tab2list(:osa_event_handlers)

# Check which files have been read (read-before-write tracking):
:ets.tab2list(:osa_files_read)

# Check cancel flags (active loop cancellation):
:ets.tab2list(:osa_cancel_flags)

# Check session provider overrides:
:ets.tab2list(:osa_session_provider_overrides)

# Look up a specific key:
:ets.lookup(:osa_context_cache, "llama3.2:latest")
```

---

## Event Tracing with Goldrush

OSA uses goldrush to compile event routing into real BEAM bytecode. The compiled module
is `:osa_event_router`.

```elixir
# Check if the router module is loaded:
:code.which(:osa_event_router)
# => '/path/to/osa_event_router.beam' or :non_existing

# Inspect the router — goldrush stores params in a GenServer:
:gr_param.start()

# Trace all events flowing through the bus:
ref = OptimalSystemAgent.Events.Bus.register_handler(:tool_call, fn event ->
  IO.inspect(event, label: "TOOL_CALL")
end)

# Later, unregister:
OptimalSystemAgent.Events.Bus.unregister_handler(:tool_call, ref)
```

To trace all events simultaneously:

```elixir
Enum.each(OptimalSystemAgent.Events.Bus.event_types(), fn type ->
  OptimalSystemAgent.Events.Bus.register_handler(type, fn event ->
    IO.puts("[EVENT] #{type}: #{inspect(Map.get(event, :payload, %{}))}")
  end)
end)
```

---

## Log Analysis

OSA uses structured Logger output. All log lines include the module prefix in brackets.

### Key Log Patterns

```
[Application] Platform enabled — starting Platform.Repo
[Ollama] Auto-selected model: llama3.3-70b (41.2 GB)
[Providers.Registry] Ollama not reachable at boot — skipping in fallback chain
[Bus] Router dispatch error: ...
[Bus] Handler crash for tool_call: ...
[Tools.Registry] Registered tool: my_tool (hot reload)
[MyFeature] unexpected message: ...
```

### Increase Log Verbosity

```elixir
# In IEx — set debug level for a specific module:
Logger.put_module_level(OptimalSystemAgent.Providers.Ollama, :debug)
Logger.put_module_level(OptimalSystemAgent.Agent.Loop, :debug)

# Reset to default:
Logger.delete_module_level(OptimalSystemAgent.Providers.Ollama)
```

In `config/dev.exs`, set globally:

```elixir
config :logger, level: :debug
```

### Checking Dead Letter Queue

Failed event handlers are enqueued in `Events.DLQ`:

```elixir
OptimalSystemAgent.Events.DLQ.list()
# => [%{type: :tool_call, payload: %{...}, error: "...", timestamp: ...}]

# Drain the DLQ:
OptimalSystemAgent.Events.DLQ.flush()
```

---

## Common Issues and Quick Checks

### Agent not responding

```elixir
# Is the session process alive?
Process.whereis(OptimalSystemAgent.SessionRegistry)
Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)

# Is the session loop stuck? Check message queue length:
[{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
Process.info(pid, :message_queue_len)

# Cancel an in-flight loop:
:ets.insert(:osa_cancel_flags, {session_id, true})
```

### Tool never executes

Verify the tool is registered and the hook chain is not blocking it:

```elixir
# Check tool exists:
:persistent_term.get({OptimalSystemAgent.Tools.Registry, :builtin_tools}, %{})
|> Map.keys()
|> Enum.member?("my_tool")

# Run the pre_tool_use hook chain manually:
payload = %{tool_name: "my_tool", arguments: %{"query" => "test"}, session_id: "debug"}
OptimalSystemAgent.Agent.Hooks.run(:pre_tool_use, payload)
# => {:ok, payload} or {:blocked, reason}
```

### Provider not connecting

```elixir
# Check if the provider is configured:
OptimalSystemAgent.Providers.Registry.provider_configured?(:anthropic)
OptimalSystemAgent.Providers.Registry.provider_configured?(:ollama)

# Test a direct chat call:
OptimalSystemAgent.Providers.Registry.chat(
  [%{role: "user", content: "hello"}],
  provider: :groq
)
```

### ETS table missing

If a module's ETS table was not created (e.g., the module crashed during `init/1`):

```elixir
:ets.whereis(:osa_hooks)
# => :undefined means the table does not exist
```

Restart the owning process:

```elixir
# Restart a supervised child (cascades under rest_for_one):
pid = Process.whereis(OptimalSystemAgent.Agent.Hooks)
Supervisor.terminate_child(OptimalSystemAgent.Supervisors.AgentServices, pid)
# The supervisor restarts it automatically
```
