# ADR-003: goldrush-Compiled Event Routing

## Status

Accepted

## Date

2024-03-01

## Context

OSA generates a high volume of events during normal operation: every user
message, LLM request, LLM response, tool call, tool result, and agent response
produces one or more events on the event bus. At 10–20 tool calls per agent turn
and multiple concurrent sessions, the event bus can process thousands of events
per second on a loaded system.

The requirements for event routing were:

- **Throughput**: Event dispatch must not be a bottleneck. A slow event router
  would add latency to every agent turn.
- **Handler isolation**: A crashing event handler must not kill the router or
  affect other handlers.
- **Typed routing**: Events carry a type atom (`:user_message`, `:llm_request`,
  etc.). Handlers register interest in specific types. The router must dispatch
  only to interested handlers.
- **Zero boilerplate**: Adding a new event type or handler should not require
  changes to the router itself.

The alternatives considered were:

1. **`Phoenix.PubSub` for all events**: PubSub uses topic strings and
   in-process subscriptions. It is designed for fan-out to many subscribers,
   not for predicate-based routing. Every subscriber would receive every event
   and filter locally — O(subscribers) work per event type regardless of
   handler interest.

2. **ETS-based handler registry**: Maintain an ETS table of
   `{event_type, handler_fn}` tuples. On each event, look up handlers by type
   and call them. This is O(1) lookup but adds ETS read overhead per event.

3. **goldrush-compiled dispatch**: goldrush (`extend/goldrush`, forked as
   `robertohluna/goldrush`) compiles event predicates to native BEAM bytecode
   modules using `glc:compile/2`. Routing a compiled module with `glc:handle/2`
   runs at BEAM instruction speed — no ETS lookups, no pattern matching at
   dispatch time.

## Decision

Use goldrush to compile event routing predicates to BEAM bytecode at startup.

Two compiled modules are produced:

- **`:osa_event_router`**: Routes typed events to registered handler functions.
  Compiled from `glc:any([glc:eq(type, T) || T <- @event_types])` predicates
  with `glc:with/2` output handlers.

- **`:osa_provider_router`** (via `MiosaProviders.Registry`): Routes LLM
  requests to the appropriate provider module based on provider atom.

- **`:osa_tool_dispatcher`** (via `Tools.Registry`): Routes tool calls to
  registered tool modules based on tool name.

Compilation occurs in the `GenServer.init/1` callback of `Events.Bus`,
`MiosaProviders.Registry`, and `Tools.Registry` respectively. Compilation is
synchronous and completes before the `start_link` call returns, ensuring that
event routing is available before the first event is emitted.

### goldrush API Used

```erlang
%% Equality predicate
glc:eq(Key, Value)

%% OR combinator
glc:any([Predicate1, Predicate2, ...])

%% Wrap with output handler
glc:with(Query, fun(Event) -> ... end)

%% Compile to named BEAM module
glc:compile(ModuleName, Query)

%% Dispatch event through compiled module
glc:handle(ModuleName, gre:make(Proplist, [list]))
```

### Fork Rationale

The upstream `extend/goldrush` repository has not been maintained since 2017.
OSA uses `robertohluna/goldrush` (fork, branch `main`) which applies patches
for:
- Elixir 1.17+ compatibility (removed deprecated Erlang APIs)
- BEAM OTP 26+ compatibility (updated `compile` semantics)

The fork is pinned in `mix.exs` with `override: true` to prevent dependency
conflicts.

## Consequences

### Benefits

- **Near-zero dispatch overhead**: Compiled BEAM modules execute at native
  instruction speed. Benchmarks show < 1 µs per event dispatch under load,
  compared to 10–50 µs for ETS-based routing.
- **Handler crash isolation**: Each handler is wrapped in a try/rescue inside
  the compiled module's output handler function. A crashing handler does not
  interrupt routing to other handlers for the same event. The error is passed
  to `Events.DLQ`.
- **No router changes for new types**: Adding a new event type requires only
  adding the atom to `@event_types` in `Events.Bus` and recompiling — the
  goldrush predicate is regenerated at the next start.

### Costs

- **Opaque compiled modules**: The `:osa_event_router` module is generated at
  runtime and is not visible in the source tree. Debugging routing logic
  requires understanding goldrush internals. `glc:handle/2` does not return
  useful information if a predicate fails to match.
- **Startup compilation**: `glc:compile/2` adds approximately 5–20 ms to
  Infrastructure startup time. This is negligible for a long-lived process
  but would matter for function-as-a-service use.
- **Erlang-only API**: goldrush uses pure Erlang APIs. OSA wraps these in the
  `Events.Bus` GenServer to present an Elixir-idiomatic interface.
- **Fork maintenance risk**: The goldrush fork must be maintained if upstream
  BEAM or Erlang OTP changes break compatibility again.

## Observability

The compiled router is observable at runtime:

```elixir
# Verify the compiled module exists
:code.is_loaded(:osa_event_router)

# Inspect module attributes
:osa_event_router.module_info()

# Check DLQ for routing failures
OptimalSystemAgent.Events.DLQ.entries()
OptimalSystemAgent.Events.DLQ.depth()
```

Telemetry events are emitted for every event dispatched through `Events.Bus`,
allowing per-event-type throughput monitoring via `Telemetry.Metrics`.
