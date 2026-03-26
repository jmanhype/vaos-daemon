# ADR-001: OTP Supervision Tree as Core Architecture

## Status

Accepted

## Date

2024-01-01

## Context

Daemon needs to run as a long-lived, continuously available AI agent process. The
core requirements driving the architecture decision were:

- **Fault tolerance**: Individual component failures must not crash the entire
  agent. A broken tool handler, a stalled LLM call, or a crashed session must
  be recovered automatically.
- **Concurrency**: Multiple user sessions, parallel tool calls, and background
  tasks (scheduler, learning, proactive mode) must run concurrently without
  shared mutable state causing races.
- **Observability**: The state of every component must be inspectable at
  runtime. Process health must be monitorable without external instrumentation.
- **Low operational overhead**: The system should self-heal without operator
  intervention for routine failures.

The initial prototype used a single-process GenServer loop. This was
straightforward but could not satisfy fault tolerance or concurrency
requirements at production scale: a single process crash killed all sessions,
and blocking on LLM API calls stalled all other activity.

The alternative approaches considered were:

1. **Actor model in another runtime** (Akka/JVM, Erlang): Requires the team
   to operate a separate runtime. JVM startup overhead is significant for an
   agent binary. Erlang without Elixir lacks the ecosystem (Ecto, Plug, Req).

2. **Async task queue** (Celery, Sidekiq, Oban): Introduces an external
   dependency (Redis, PostgreSQL) for something the BEAM provides natively.
   Supervision semantics are weaker — a failed worker does not automatically
   restart the failed unit of work.

3. **Elixir/OTP with supervised GenServers**: The BEAM was designed for
   exactly this workload. OTP supervisors provide automatic restart, process
   isolation, and dependency-ordered startup out of the box. The Elixir
   ecosystem provides Ecto (SQLite), Plug/Bandit (HTTP), Phoenix.PubSub, and
   a robust package ecosystem.

## Decision

Use Elixir/OTP as the runtime, organized into a four-subsystem supervision
tree:

- **Infrastructure**: Registries, event bus, storage, provider routing
- **Sessions**: Channel adapters, session DynamicSupervisor
- **AgentServices**: Memory, hooks, budget, learning, scheduler
- **Extensions**: Opt-in subsystems (fleet, sidecar, sandbox, wallet, AMQP)

The root supervisor uses `:rest_for_one` to enforce dependency ordering
between subsystems. Each subsystem uses the strategy appropriate to its
child relationships (`:rest_for_one` for Infrastructure, `:one_for_one`
for Sessions/AgentServices/Extensions).

Every concurrent unit of work is a named GenServer or a DynamicSupervisor
child. No raw `Task.async` calls exist outside `Task.Supervisor` contexts.

## Consequences

### Benefits

- **Automatic crash recovery**: OTP restarts failed processes within
  milliseconds. Session recovery from SQLite takes seconds. Most failures
  are invisible to the user.
- **Isolated failure domains**: A sandbox crash does not affect unrelated
  agent sessions. A provider circuit breaker opening does not stall the
  event bus.
- **Built-in observability**: `:observer.start()` or `iex> :sys.get_state/1`
  gives complete process tree visibility at runtime. No external APM required
  for basic health inspection.
- **Hot code loading**: The BEAM supports hot code upgrades. Mix releases
  enable rolling upgrades without full restarts (advanced usage).
- **Preemptive scheduling**: The BEAM scheduler preempts long-running
  reductions, preventing one busy process from starving others.

### Costs

- **OTP expertise required**: Understanding supervision strategies,
  GenServer lifecycle, and process linking is prerequisite knowledge for
  contributors modifying the supervision tree. This is a higher bar than
  thread-based concurrency in most languages.
- **Erlang/Elixir ecosystem**: Some integrations (Python ML models, Go
  tokenizers) require out-of-process sidecars. The shim layer adds
  indirection.
- **Single-node by default**: OTP clustering (`:distributed_supervisor`,
  `Horde`) is not used. Multi-node deployment requires explicit design work.
  Daemon is currently designed for single-node operation.

## Compliance

All new concurrent components must be:
- Started as a named GenServer or supervised Task
- Added to the appropriate subsystem supervisor
- Documented with their restart strategy rationale

Raw `Process.spawn` and anonymous `Task.async` (outside Task.Supervisor) are
not permitted in production code paths.
