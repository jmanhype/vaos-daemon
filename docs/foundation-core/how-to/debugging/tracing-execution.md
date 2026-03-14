# Tracing Execution

Audience: developers who need to follow a single user message through the
entire OSA pipeline to understand where it was processed, modified, or stalled.

---

## Overview

A message passes through up to nine stages before a response is returned.
Each stage has a dedicated inspection point.

```
1. Channel receives message
2. Agent.Loop.process_message/2 is called
3. NoiseFilter and Guardrails run
4. Message is persisted to Agent.Memory
5. Context is built (identity + memory + tools)
6. LLM is called (possibly multiple times with tool calls)
7. Tools execute (with hooks)
8. Final response is returned to channel
9. Events are emitted and persisted
```

---

## Step 1: Check the EventStream

Every event emitted during a session is buffered in `Events.Stream`. Query the
stream for a session to see every significant action, in order.

```elixir
# Retrieve recent events for a session
alias OptimalSystemAgent.Events.Stream

events = Stream.events("cli:my_session_id", limit: 50)

# Filter to a specific event type
tool_calls = Stream.events("cli:my_session_id", type: :tool_call, limit: 20)

# Replay a time range
alias DateTime
range_events = Stream.replay(
  "cli:my_session_id",
  ~U[2026-03-14 00:00:00Z],
  ~U[2026-03-14 01:00:00Z]
)
```

If the session ID is unknown, list all active sessions:

```elixir
Registry.select(
  OptimalSystemAgent.SessionRegistry,
  [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}]
)
```

---

## Step 2: Check Agent.Loop State

The `Agent.Loop` GenServer holds the current state of a session mid-execution:
messages accumulated so far, current provider and model, and iteration count.

```elixir
# Find the loop PID for a session
[{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, "cli:my_session_id")

# Inspect the state
:sys.get_state(pid)
# Returns a struct with: session_id, messages, provider, model,
# working_dir, permission_tier, tool_calls_count, iteration_count
```

If `:sys.get_state/1` blocks, the loop is busy (executing a tool or waiting
on the LLM). Use a short timeout and retry:

```elixir
:sys.get_state(pid, 1_000)
```

The loop's message queue length reveals whether it is backed up:

```elixir
Process.info(pid, :message_queue_len)
```

---

## Step 3: Check Memory for Persisted Messages

`Agent.Memory` persists each message to SQLite after it passes the noise
filter and guardrail checks. If a message is missing from memory, it was
blocked at the filter stage.

```elixir
alias OptimalSystemAgent.Agent.Memory

# Load the full session history
messages = Memory.load_session("cli:my_session_id")

# Count messages
length(messages)

# Inspect the last few messages
Enum.take(messages, -5)
```

If the session has zero messages but the loop exists, the message was:
- Blocked by Guardrails (prompt injection detected), or
- Filtered by NoiseFilter (low signal weight or regex match)

Check the logs at `:debug` level for `[loop]` prefixed lines to confirm.

---

## Step 4: Check Hook Metrics for Blocked Operations

The `:pre_tool_use` hook chain can block tool calls. Check whether a hook is
firing and blocking:

```elixir
alias OptimalSystemAgent.Agent.Hooks

# Per-hook metrics: call count, block count, avg latency
Hooks.metrics()
```

To see which hooks are registered:

```elixir
Hooks.list_hooks()
# Returns a map of event => [%{name: String, priority: integer}]
```

If `spend_guard` is blocking (high block count), the session has exceeded its
budget. Check with:

```elixir
MiosaBudget.Budget.status()
```

---

## Step 5: Check the DLQ for Failed Events

If an event handler crashed during dispatch, the event lands in the DLQ.

```elixir
alias OptimalSystemAgent.Events.DLQ

# List all entries
DLQ.list()

# Check count
DLQ.size()
```

Each entry shows: event type, original payload, the error, retry count, and
time until next retry. If retries are exhausted, an `:algedonic_alert` event
is emitted.

---

## End-to-End Trace with Erlang Tracing

For deep tracing, use BEAM's built-in tracing facilities. This shows every
function call and return value in the traced modules.

```elixir
# Start the tracer (prints to console)
:dbg.tracer()

# Trace all calls to Agent.Loop
:dbg.p(:all, :c)
:dbg.tpl(OptimalSystemAgent.Agent.Loop, :process_message, :x)
:dbg.tpl(OptimalSystemAgent.Agent.Loop, :run_loop, :x)

# Trace tool execution
:dbg.tpl(OptimalSystemAgent.Agent.Loop.ToolExecutor, :execute_tool_call, :x)

# Send a message to the session — watch the trace output

# Stop tracing
:dbg.stop()
```

This generates significant output. Use it for isolated scenarios only — not on
production systems under load.

---

## Following Provider Latency

If the response is slow but tools are not the cause, the LLM call itself is
taking time. Track provider latency:

```elixir
# Provider health and latency stats
MiosaLLM.HealthChecker.status()

# Check if the fallback chain is being used
# (logged at :info level with "[loop] Provider fallback:" prefix)
Logger.configure(level: :debug)
```

---

## Quick Checklist

Use this checklist when a message produces no response or an unexpected
response:

1. `Stream.events(session_id)` — did the message arrive at all?
2. `Memory.load_session(session_id)` — was it persisted (passed filters)?
3. `:sys.get_state(loop_pid)` — what state is the loop in?
4. `Hooks.metrics()` — is a hook blocking tool calls?
5. `DLQ.list()` — did an event handler crash?
6. `MiosaLLM.HealthChecker.status()` — is the provider available?
7. `Logger` at `:debug` — full trace of `[loop]` messages

---

## Related

- [Debugging Core](./debugging-core.md) — enable logging, inspect ETS, check registries
- [Troubleshooting Common Issues](./troubleshooting-common-issues.md) — known error patterns and fixes
