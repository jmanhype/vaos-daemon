# What is goldrush and Why OSA Uses It

OSA routes events, tool calls, and LLM provider requests through a library called
goldrush. If you look at the OSA codebase, you will see atoms like
`:osa_event_router`, `:osa_tool_dispatcher`, and `:osa_provider_router`. These
are not configuration strings — they are names of compiled BEAM bytecode modules
that goldrush creates at runtime.

This guide explains what goldrush is, how it works, and why OSA uses it instead
of simpler alternatives.

---

## What is goldrush?

goldrush is an Erlang library for event processing. Its distinguishing feature is
that it compiles event filters into real BEAM bytecode modules at runtime.

To understand why this matters, consider how you would normally filter a stream
of events in Elixir. You might write:

```elixir
# Typical approach: pattern match at runtime
def handle_event(event) do
  case event.type do
    :user_message -> dispatch_to_session(event)
    :tool_call    -> dispatch_to_tool(event)
    :llm_response -> dispatch_to_loop(event)
    _             -> :ignore
  end
end
```

This works, but it is a function call. Every event goes through a `case`
expression evaluated at runtime. The BEAM has to load the function, evaluate
the pattern match, and branch.

goldrush does something different. It takes your filter conditions and compiles
them into a new Erlang module — actual `.beam` bytecode — that the VM loads and
executes natively. The filtering happens at BEAM instruction speed, not at
Elixir/Erlang function-call speed.

The difference is roughly analogous to the difference between interpreting a SQL
query at runtime versus using a prepared statement that the database has already
planned and compiled.

---

## How goldrush Works

goldrush provides a small query DSL:

```erlang
% In Erlang (goldrush is an Erlang library)
glc:eq(key, value)           % equality predicate: event.key == value
glc:any([pred1, pred2, ...]) % OR: matches if any predicate matches
glc:all([pred1, pred2, ...]) % AND: matches only if all predicates match
glc:with(query, fun/1)       % attach a handler function to a query
glc:compile(module_name, query) % compile to a named BEAM module
glc:handle(module_name, event)  % run event through the compiled module
```

In Elixir, the same calls look like:

```elixir
# Build a filter for all known event types
type_filters = Enum.map(@event_types, &:glc.eq(:type, &1))

# Attach a dispatch handler
query = :glc.with(:glc.any(type_filters), fn event ->
  dispatch_event(event)
end)

# Compile to a BEAM module named :osa_event_router
:glc.compile(:osa_event_router, query)
```

After `glc:compile/2` runs, `:osa_event_router` is a real loaded module in the
VM. Sending an event through it looks like:

```elixir
gre_event = :gre.make(event_fields, [:list])
:glc.handle(:osa_event_router, gre_event)
```

The VM runs the compiled module's bytecode directly. No hash map lookup, no
function dispatch, no runtime pattern matching — just BEAM instructions.

---

## goldrush in OSA: Three Compiled Modules

OSA compiles three goldrush modules at boot. Each serves a different routing
purpose.

### 1. `:osa_event_router` — The Event Bus

Compiled by `OptimalSystemAgent.Events.Bus` during its `init` callback.

The event bus handles these event types:

```
user_message    — incoming message from any channel
llm_request     — agent loop → provider registry
llm_response    — provider → agent loop
tool_call       — agent loop → tools registry
tool_result     — tool → agent loop
agent_response  — agent loop → channels and bridge
system_event    — scheduler and internals → loop and memory
channel_connected / channel_disconnected / channel_error
ask_user_question / survey_answered
algedonic_alert — urgent bypass signal (VSM)
```

The compiled filter passes events of known types to `dispatch_event/1`, which
looks up registered handlers in the `:osa_event_handlers` ETS table and calls
each one.

A key architectural decision: the goldrush module is compiled once at init and
never recompiled. Handler registration is dynamic (via ETS), but the type filter
is static. This avoids a race condition where in-flight tasks hold references to
old compiled bytecode while a recompile wipes the `gr_param` ETS table.

### 2. `:osa_tool_dispatcher` — Tool Routing

Compiled by `OptimalSystemAgent.Tools.Registry` during init.

When the agent loop decides to call a tool, it sends an event through the tool
dispatcher. The compiled module routes based on the tool name field in the event,
dispatching to the correct tool module.

Unlike the event bus, the tool dispatcher is recompiled when new tools are
registered. This is safe because tool registration is infrequent (at boot, when
MCP servers connect, or when the operator registers a skill). OSA ensures no
in-flight tool calls are pending during recompilation.

### 3. `:osa_provider_router` — LLM Provider Routing

Compiled by `MiosaProviders.Registry` during init.

When the agent loop needs an LLM response, it routes through the provider router.
The compiled module dispatches based on the provider atom (`:anthropic`, `:groq`,
`:ollama`, etc.) to the correct provider module.

The provider router is also recompiled when providers are dynamically registered
(which happens rarely, primarily for testing).

---

## How Events Flow Through OSA

Here is a complete event flow for a user message arriving via HTTP:

```
1. HTTP handler receives POST /sessions/:id/messages

2. Handler calls Events.Bus.emit(:user_message, payload)

3. Bus creates an Event struct (UUID, timestamp, session_id, signal fields)
   Bus auto-classifies Signal Theory dimensions if not present
   Bus serializes to a goldrush proplist: :gre.make(fields, [:list])

4. Bus spawns a supervised Task:
   Task calls :glc.handle(:osa_event_router, gre_event)

5. :osa_event_router (compiled BEAM module) checks: is :type == :user_message?
   Yes → calls dispatch_event/1

6. dispatch_event/1 reads :osa_event_handlers ETS table
   Finds handler registered for :user_message
   Spawns another supervised Task to call the handler

7. Handler is the agent Loop process for this session
   Loop processes the message, calls LLM, executes tools, sends response

8. Loop calls Events.Bus.emit(:agent_response, response_payload)

9. :osa_event_router dispatches :agent_response to Bridge.PubSub and SSE stream
```

Every step after the initial emit is asynchronous. The HTTP handler returns
immediately. The event processing continues in supervised background tasks.

---

## goldrush vs Phoenix.PubSub

OSA uses both goldrush (via `Events.Bus`) and Phoenix.PubSub (via `Bridge.PubSub`).
They serve different purposes.

**Phoenix.PubSub** routes messages by topic string. A subscriber says "send me
everything published to topic `session:abc123`." It is topic-based fan-out — good
for sending a specific session's events to everyone who cares about that session.

**goldrush** routes by content. A compiled filter says "send me every event where
the `:type` field is `:tool_call`." It is content-based routing — good for
routing by event type regardless of which session it came from.

| Feature | Phoenix.PubSub | goldrush |
|---|---|---|
| Routing basis | Topic string | Event field values |
| Filter complexity | Simple (topic match) | Arbitrary predicates (eq, any, all) |
| Performance | Fast (ETS-backed) | Faster (compiled BEAM bytecode) |
| Dynamic subscribers | Yes, at any time | Yes, via ETS handler table |
| Recompilation needed | No | Only when filter changes |
| Best for | Fan-out to topic subscribers | Content-filtered event routing |

OSA's `Bridge.PubSub` uses Phoenix.PubSub to fan out session events to
connected frontends and external bridges. `Events.Bus` uses goldrush to route
events by type across the entire system.

---

## Why This Matters for OSA

OSA's event bus processes every message, every tool call, every LLM request, and
every response. In a busy session with complex tool chains, the bus might handle
dozens of events per second. In a multi-session setup with many concurrent users,
that multiplies.

By compiling the type filter into BEAM bytecode rather than evaluating it as a
function on each event, goldrush removes a constant overhead from every event
that flows through the system. At scale, this translates to lower latency and
higher throughput.

It also provides a clean separation: the bus does not know about sessions,
providers, or tools. It only knows about event types. The routing logic for each
subsystem lives in its own compiled module.

---

## Next Steps

Read [signal-theory-explained.md](./signal-theory-explained.md) to understand
how OSA classifies every incoming message before routing it — a layer that runs
even before the event hits the goldrush router.
