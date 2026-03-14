# Debugging Core

Audience: developers diagnosing problems in a running OSA instance.

All techniques here assume you have IEx access to the running node or that
you can start OSA in development mode with `iex -S mix`.

---

## Enable Debug Logging

OSA uses `Logger` throughout. The default level in development is `:info`.
Switching to `:debug` exposes per-module trace output.

```elixir
# In IEx (takes effect immediately)
Logger.configure(level: :debug)

# Or set in config/dev.exs (requires restart)
config :logger, level: :debug
```

To filter to a single module:

```elixir
Logger.configure_backend(:console,
  format: "[$level] $message\n",
  metadata: [:module]
)
```

To suppress noisy modules while keeping others at debug:

```elixir
# In config.exs
config :logger,
  backends: [:console],
  compile_time_purge_matching: [
    [module: OptimalSystemAgent.Telemetry.Metrics, level_lower_than: :info]
  ]
```

---

## Inspect ETS Tables

OSA stores hot-path state in ETS tables. Inspect them directly from IEx.

```elixir
# Cancel flags — are any sessions cancelling?
:ets.tab2list(:osa_cancel_flags)

# Read-before-write tracking
:ets.tab2list(:osa_files_read)

# Session provider overrides
:ets.tab2list(:osa_session_provider_overrides)

# Pending ask_user questions
:ets.tab2list(:osa_pending_questions)

# Hooks registered by event type
:ets.tab2list(:osa_hooks)

# Hook metrics (call counts, timing)
:ets.tab2list(:osa_hooks_metrics)

# DLQ entries (failed event handlers awaiting retry)
:ets.tab2list(:osa_dlq)

# Registered slash commands
:ets.tab2list(:osa_commands)
```

---

## Inspect the Process Tree

The full OTP supervision tree is visible in `:observer`:

```elixir
:observer.start()
```

`:observer` opens a GUI. Navigate to the **Applications** tab, select
`optimal_system_agent`, and expand the supervision tree.

From the command line:

```elixir
# List all processes supervised by the session supervisor
DynamicSupervisor.which_children(OptimalSystemAgent.SessionSupervisor)

# List all channel adapters
DynamicSupervisor.which_children(OptimalSystemAgent.Channels.Supervisor)

# Inspect the registry (all active sessions)
Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
```

---

## Inspect GenServer State

```elixir
# Get the state of any named GenServer
:sys.get_state(OptimalSystemAgent.Agent.Hooks)
:sys.get_state(OptimalSystemAgent.Events.Bus)
:sys.get_state(OptimalSystemAgent.Agent.Memory)
:sys.get_state(OptimalSystemAgent.Tools.Registry)

# Get the state of a session's Agent.Loop
pid = Registry.lookup(OptimalSystemAgent.SessionRegistry, "cli:my_session_id")
      |> List.first()
      |> elem(0)
:sys.get_state(pid)
```

`:sys.get_state/1` sends a synchronous call to the GenServer and returns its
state. This can block if the GenServer is busy — use a timeout:

```elixir
:sys.get_state(pid, 5_000)
```

---

## Check Events.Bus Handlers

```elixir
# List all registered event handlers
OptimalSystemAgent.Events.Bus.list_handlers()

# Check which handlers are registered for a specific event type
OptimalSystemAgent.Events.Bus.list_handlers()
|> Map.get(:tool_call, [])
```

---

## Check Registered Tools

```elixir
# List all tools visible to the LLM
OptimalSystemAgent.Tools.Registry.list_tools()
|> Enum.map(& &1.name)

# List via direct ETS read (non-blocking, no GenServer call)
OptimalSystemAgent.Tools.Registry.list_tools_direct()
|> Enum.map(& &1.name)
```

---

## Check Hook Metrics

```elixir
# Hook execution metrics (call count, block count, avg timing)
OptimalSystemAgent.Agent.Hooks.metrics()

# List registered hooks with priorities
OptimalSystemAgent.Agent.Hooks.list_hooks()
```

---

## Check Provider Health

```elixir
# Is a provider available (circuit breaker state)?
MiosaLLM.HealthChecker.is_available?(:anthropic)
MiosaLLM.HealthChecker.is_available?(:openai)

# Full health state for all providers
MiosaLLM.HealthChecker.status()
```

---

## Check the DLQ

```elixir
# Are any events stuck in the dead letter queue?
OptimalSystemAgent.Events.DLQ.list()

# How many entries?
OptimalSystemAgent.Events.DLQ.size()

# Force retry all entries now
OptimalSystemAgent.Events.DLQ.retry_all()

# Flush the DLQ (drop all entries)
OptimalSystemAgent.Events.DLQ.flush()
```

---

## IEx Helpers

```elixir
# Recompile a module without restarting the application
recompile()

# Reload a specific module
:code.purge(OptimalSystemAgent.Agent.Hooks)
:code.load_file(OptimalSystemAgent.Agent.Hooks)

# Trace calls to a function (printed to console)
:dbg.tracer()
:dbg.p(:all, :c)
:dbg.tpl(OptimalSystemAgent.Agent.Loop, :process_message, :x)

# Stop tracing
:dbg.stop()

# Check memory usage
:erlang.memory()

# Check process count
length(Process.list())

# Check message queue length for a process
Process.info(pid, :message_queue_len)
```

---

## Common Log Prefixes

OSA uses `[ModuleName]` prefixes in log messages. Filter by prefix to isolate
a subsystem:

| Prefix | Subsystem |
|--------|-----------|
| `[loop]` | Agent.Loop — ReAct iterations and tool calls |
| `[Bus]` | Events.Bus — dispatch and failure modes |
| `[DLQ]` | Events.DLQ — retry queue |
| `[Hooks]` | Agent.Hooks — hook execution |
| `[Tools]` | Tools.Registry — registration and dispatch |
| `[Memory]` | Agent.Memory — reads and writes |
| `[Compactor]` | Agent.Compactor — context window management |
| `[HealthChecker]` | Provider circuit breaker |
| `[MyAdapter]` | Channel adapter (replace with adapter name) |

---

## Related

- [Tracing Execution](./tracing-execution.md) — follow a single message end-to-end
- [Troubleshooting Common Issues](./troubleshooting-common-issues.md) — known problems and fixes
