# Failure Modes

## Overview

This document describes the failure modes that Daemon is designed to handle,
the detection mechanism for each, and the recovery path. Understanding these
failure modes is prerequisite to operating Daemon in production.

---

## LLM Provider Failure

### Detection

`Daemon.Providers.HealthChecker` (exposed as `MiosaLLM.HealthChecker`)
is a GenServer that tracks per-provider health state. It is started before
`MiosaProviders.Registry` in the Infrastructure supervisor, ensuring the circuit
breaker is in place before any requests flow.

State transitions:

```
:closed  ──(3 consecutive failures)──> :open
:open    ──(30 seconds elapsed)──────> :half_open
:half_open ──(1 successful probe)────> :closed
:half_open ──(probe fails)───────────> :open
```

Rate limiting is handled separately: an HTTP 429 response puts the provider into
a `:rate_limited` sub-state for 60 seconds (or the `Retry-After` duration if
present). `is_available?/1` returns false during this window.

### Recovery

`MiosaProviders.Registry` maintains an ordered provider fallback chain. When the
requested provider is unavailable (circuit open or rate-limited), Registry walks
the chain and selects the first available provider. A typical production chain:

```
Anthropic → OpenAI → Groq → Ollama
```

Fallback is transparent to the caller. The agent session continues without
interruption. Provider availability is re-evaluated on every request, so
recovery is automatic once the circuit closes.

If all providers in the chain are unavailable, the request returns
`{:error, :no_providers_available}` and the agent loop surfaces an error
message to the user rather than hanging.

---

## Session Crash

### Detection

Each agent session runs as a supervised child of `Daemon.SessionSupervisor`
(a `DynamicSupervisor`). OTP detects a crash immediately when the `Agent.Loop`
process exits abnormally.

### Recovery

OTP restarts the `Agent.Loop` process under the same child spec. On restart:

1. The Loop reinitializes with the same session ID
2. It queries `Agent.Memory` (GenServer, separate process — unaffected by Loop crash)
   to retrieve the conversation history persisted to SQLite
3. It queries `MiosaMemory.Store` for relevant working-memory entries
4. The session resumes with full conversation context

The Loop state held only in process memory (streaming state, intermediate tool
results) is lost. Completed tool calls and LLM exchanges are durable because
they were persisted to SQLite via `Agent.Memory` before the crash occurred.

`osa_cancel_flags` and `osa_pending_questions` ETS entries for the session are
re-created by the new Loop process on first use.

### Isolation

A session crash does not affect other sessions. Each session is an independent
DynamicSupervisor child. `SessionRegistry` de-registers the old PID and
re-registers the new one transparently.

---

## Event Handler Failure

### Detection

`Events.Bus` wraps handler dispatch in a try/rescue. If a handler function
raises or returns an error, the Bus catches it and calls
`Events.DLQ.enqueue/4` synchronously before continuing to the next handler.

### Recovery

`Events.DLQ` stores failed events in an ETS table (`:daemon_dlq`). A retry
scheduler runs periodically and re-dispatches events whose `next_retry_at`
timestamp has passed.

Retry policy:

| Attempt | Delay |
|---|---|
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds (capped at 30 seconds) |

After `max_retries` (3) exhausted, the DLQ emits an `:algedonic_alert` event
and drops the entry. Algedonic alerts are observable via `Events.Bus` subscribers
and the SSE stream.

DLQ state is ETS-only and does not survive a DLQ process restart. Events queued
at the time of a DLQ crash are lost. This is an acceptable tradeoff: events are
ephemeral by design, and the Learning engine captures durable patterns from
successfully processed events.

---

## Sandbox Timeout

### Detection

`Daemon.Sandbox.Supervisor` manages sandboxed code execution
processes. Each sandbox task runs with an OS-level timeout enforced by the
sandbox runtime (Docker or native process group).

### Recovery

Timeout handling per execution mode:

| Mode | Default Timeout | Behavior on Timeout |
|---|---|---|
| `safe` | 30 seconds | Process killed, `{:error, :timeout}` returned to Loop |
| `restricted` | 30 seconds | Process killed, error returned |
| `unrestricted` | Configurable | Process killed, error returned |

The Loop receives `{:error, :timeout}` from the tool executor and returns the
error to the LLM as a tool result. The LLM can then decide to retry with
different inputs, ask the user for guidance, or proceed without the tool result.

Timeouts are configurable per invocation by passing `timeout_ms` in the tool
parameters. The default is 30,000 ms.

---

## Token Budget Exhaustion

### Detection

`MiosaBudget.Budget` tracks daily and monthly token spend. On every LLM call,
`Agent.Hooks` executes the `spend_guard` hook via `Agent.Hooks.run_pre_llm/2`
before dispatching to the provider.

The hook calls `MiosaBudget.Budget.check_budget/0`. If the return is
`{:over_limit, :daily}` or `{:over_limit, :monthly}`, the hook returns
`{:halt, :budget_exceeded}`.

### Recovery

When the hook halts:

- The LLM call is blocked immediately — no provider request is made
- The agent loop returns a budget-exceeded message to the user
- The session remains alive; the user can continue non-LLM interactions
- Budget resets automatically at the daily or monthly boundary (handled by
  `MiosaBudget.Budget`'s internal timer check on each `check_budget` call)

Daily limit default: $50 USD. Monthly limit default: $200 USD. Both are
configurable via application environment.

---

## Database Failure

### Detection

`Daemon.Store.Repo` uses Ecto with the `ecto_sqlite3` adapter.
SQLite is configured in WAL (Write-Ahead Logging) mode, which prevents database
corruption on crash and allows concurrent reads during writes.

Repo operations return `{:error, reason}` on failure. Critical paths (memory
persistence, conversation history) log the error and continue with degraded
behavior rather than crashing the caller.

### Recovery

| Scenario | Recovery |
|---|---|
| SQLite file locked | WAL mode allows concurrent read; write retries at Ecto level |
| Disk full | Write fails gracefully; in-memory state preserved for session duration |
| Corruption (unexpected crash) | WAL mode prevents corruption; WAL file is replayed on reopen |
| Repo process crash | OTP restarts `Store.Repo` (supervised under Infrastructure) |

Because Infrastructure uses `:rest_for_one`, a `Store.Repo` crash restarts
all subsequent Infrastructure children, then Sessions, AgentServices, and
Extensions. Active sessions are interrupted and restarted. Conversation history
persisted before the crash is recoverable from the SQLite file.

Disk-backed SQLite means no data is lost for completed writes even if the
BEAM process is killed externally (e.g., OS OOM). Only in-flight transactions
at crash time are rolled back.

---

## MCP Server Failure

### Detection

MCP (Model Context Protocol) server processes run as individual GenServers under
`Daemon.MCP.Supervisor` (a DynamicSupervisor under Infrastructure).
Each server's GenServer monitors its OS process via `Port` monitoring. A dead
OS process causes the GenServer to receive a `:DOWN` message.

### Recovery

The GenServer handles `:DOWN` by:

1. Logging the failure with the server name and exit reason
2. Attempting reconnection with exponential backoff and jitter
3. Un-registering the server's tools from `Tools.Registry` during the outage
4. Re-registering tools after successful reconnection

Backoff sequence (approximate): 1s, 2s, 4s, 8s, ... capped at 60s. Jitter
(±20%) prevents thundering herd on multi-server restarts.

Tool calls targeting an unavailable MCP server return
`{:error, :mcp_server_unavailable}`, which is returned to the LLM as a tool
result for self-correction.

---

## Sidecar Failure (Go/Python)

### Detection

`Daemon.Sidecar.Manager` maintains circuit breaker state for each
sidecar in ETS table `:daemon_circuit_breakers`. The circuit breaker is a
three-state machine: `:closed`, `:open`, `:half_open`.

Sidecar-level thresholds:
- Opens after 5 consecutive failures (vs. 3 for LLM providers)
- Recovery timeout: 30 seconds
- Half-open probe: 1 request allowed; success closes, failure re-opens

### Recovery

When a sidecar circuit is open, calls to that sidecar return
`{:error, :circuit_open}` immediately without attempting the RPC. The agent
loop treats sidecar errors as tool errors and returns them to the LLM for
self-correction or alternative approach selection.

Individual sidecar GenServers are supervised under Extensions with `:one_for_one`.
An OS-level sidecar crash triggers the GenServer to restart and attempt
process re-launch.

---

## Failure Mode Summary

| Failure | Detection | Recovery | Data Loss |
|---|---|---|---|
| LLM provider down | HealthChecker circuit breaker | Automatic fallback to next provider in chain | None |
| All providers down | HealthChecker, all circuits open | Error returned to user; session preserved | None |
| Session crash | OTP supervisor exit signal | DynamicSupervisor restart; history from SQLite | In-flight exchange |
| Event handler crash | Events.Bus try/rescue | DLQ enqueue with exponential backoff retry | None (up to 3 retries) |
| DLQ exhausted | Algedonic alert emitted | Entry dropped; alert observable via SSE | Specific event |
| Sandbox timeout | OS process kill | `{:error, :timeout}` to LLM for self-correction | Tool output |
| Token budget hit | spend_guard hook halt | LLM call blocked; user notified | None |
| Database failure | Ecto error return | Degraded write; WAL prevents corruption | In-flight write |
| MCP server down | Port :DOWN message | Reconnect with backoff; tools un-registered | None |
| Sidecar crash | ETS circuit breaker | GenServer restart; sidecar re-launched | In-flight call |
