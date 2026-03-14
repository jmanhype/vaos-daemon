# Error Taxonomy

## Audience

Engineers debugging failures, adding error handling, or understanding how OSA categorizes and responds to different error conditions.

## Overview

OSA categorizes errors by their source and recoverability. Most errors are handled locally with a result tuple; only errors that affect the entire session surface to the user. The `Providers.Registry` wraps all LLM calls; tool errors are returned as tool results (not exceptions) so the agent can reason about them.

---

## LLM Provider Errors

Handled in `OptimalSystemAgent.Providers.Registry` and `MiosaLLM.HealthChecker`.

### Rate Limit (HTTP 429)

**Pattern:** `{:error, {:rate_limited, retry_after_seconds}}`

**Source:** Any cloud LLM provider returning HTTP 429.

**Handling:**
1. `Providers.Registry.with_retry/1` sleeps for `min(retry_after, 60)` seconds and retries up to 3 times total.
2. After 3 rate-limited retries, calls `HealthChecker.record_rate_limited/2` which marks the provider as unavailable for 60 seconds (or `Retry-After` duration).
3. The fallback chain skips rate-limited providers during the window.

**User impact:** Transparent if a fallback provider is available. If not: the agent session receives `{:error, "Provider ... rate-limited and no fallback available"}`.

### Timeout

**Pattern:** `{:error, "timeout"}` or `Req.TransportError{reason: :timeout}`

**Source:** Slow LLM response exceeding the HTTP client timeout.

**Handling:** `HealthChecker.record_failure/2` increments the consecutive failure counter. After 3 consecutive failures, the circuit opens.

### Bad Response

**Pattern:** `{:error, "bad response: ..."}`

**Source:** Malformed JSON, unexpected response structure, missing `choices` field.

**Handling:** Same as timeout — treated as a provider failure, circuit breaker updated.

### Network Error

**Pattern:** `{:error, "connection refused"}` or `Req.TransportError{reason: :econnrefused}`

**Source:** Ollama not running, provider endpoint unreachable.

**Handling:** For Ollama specifically, a TCP probe at boot (`gen_tcp.connect/4` with 1s timeout) excludes it from the fallback chain if not reachable. For cloud providers, the circuit breaker handles repeated connection failures.

### Context Overflow

**Pattern:** `{:error, "context_length_exceeded"}` or similar

**Source:** Total token count exceeds the model's context window.

**Handling:** `Agent.Loop` catches this case and triggers `Agent.Compactor` to summarize the conversation history. Up to 3 compaction attempts are made before giving up:

```
Context overflow — compacting and retrying (overflow_retry 1/3, iteration N)
Context overflow after 3 compaction attempts (iteration N)  ← error, session ends
```

---

## Circuit Breaker States

`OptimalSystemAgent.Providers.HealthChecker` tracks each provider independently:

| State | Condition | Behavior |
|-------|-----------|---------|
| `:closed` | Default | All requests pass through |
| `:open` | 3+ consecutive failures | `is_available?/1` returns `false`; requests skip this provider |
| `:half_open` | 30 seconds after opening | Next request is a probe; success closes, failure re-opens |

Rate-limited state is orthogonal to circuit state — a provider can be both `:closed` and rate-limited.

---

## Tool Errors

### Execution Failure

**Pattern:** Tool module raises exception or returns `{:error, reason}`

**Source:** Any `Tools.Behaviour` implementation.

**Handling:** `Agent.Loop.ToolExecutor` rescues exceptions and returns them as error strings to the agent. The agent sees the error in the tool result and can decide to retry, use a different approach, or report failure. Tool errors do not crash the session.

### Permission Denied

**Pattern:** `{:error, "permission denied: ..."}` or `{:error, :permission_denied}`

**Source:** File system tools when the agent's `permission_tier` is `:read_only` or `:workspace` and a write is attempted outside allowed paths.

**Handling:** Returned as a tool error. The agent is expected to reason about the permission constraint and stop attempting the operation.

### Tool Output Truncation

**Pattern:** Not an error — large outputs are silently truncated to `max_tool_output_bytes` (default 51,200 bytes).

**Source:** `Tools.Registry` truncation logic.

**Handling:** The truncated output still includes a marker so the agent knows more content exists. No error is returned.

### MCP Tool Failure

**Pattern:** `{:error, "MCP tool error: ..."}` or JSON-RPC error response

**Source:** External MCP server returning an error.

**Handling:** Treated as a normal tool error and returned to the agent.

---

## Session Errors

### Session Not Found

**Pattern:** `{:error, :not_found}` from `Agent.Loop.get_state/1` or `Events.Stream` operations

**Source:** Session ID does not exist in `SessionRegistry` or `EventStreamRegistry`.

**Handling:** HTTP API returns 404. CLI reports the error and exits the command.

### Max Iterations Exceeded

**Pattern:** Internal — agent loop exits after `max_iterations` (default 20) tool-call cycles.

**Source:** `Agent.Loop.run_loop/2` counting iterations.

**Handling:** The current partial response is returned with a note that the iteration limit was reached. Logged at warning level:

```
Agent loop hit max iterations (20)
```

### Checkpoint Restore

When a session process restarts after a crash, `Agent.Loop.init/1` calls `Checkpoint.restore_checkpoint/1`. If a checkpoint exists, the session resumes from the last saved state:

```
[loop] Restored checkpoint for session sess-abc — iteration=5, messages=12
```

If no checkpoint: the session starts fresh.

---

## Config Errors

### Missing Required Secret

**Pattern:** Runtime error during `Application.start/2`

**Source:** `OSA_REQUIRE_AUTH=true` set without `OSA_SHARED_SECRET`.

**Handling:** `runtime.exs` raises immediately at startup:
```elixir
raise "OSA_SHARED_SECRET must be set when OSA_REQUIRE_AUTH=true"
```
The application does not start. This is the correct behavior — running without auth when auth is required would be a security failure.

### Invalid Env Var Format

**Pattern:** Silently uses default

**Source:** `OSA_DAILY_BUDGET_USD=not-a-number` or similar.

**Handling:** `parse_float` and `parse_int` helpers in `runtime.exs` return the default value on parse failure. No warning is logged. Check your values if budget limits seem wrong.

---

## Memory / Storage Errors

### SQLite BUSY

**Pattern:** `{:error, :busy}` from `Store.Repo`

**Source:** Concurrent writes hitting the SQLite `busy_timeout`.

**Handling:** `busy_timeout: 5000` in the SQLite config causes the driver to wait up to 5 seconds before returning busy. In practice this rarely fires because WAL mode allows concurrent reads with one writer.

### Vault Storage

Vault errors are internal to `OptimalSystemAgent.Vault.Supervisor`. Observation write failures are logged at debug level and do not affect the agent's response.

---

## Error Propagation Summary

| Error type | Propagates to user? | Recovery mechanism |
|-----------|--------------------|--------------------|
| LLM rate limit | No (transparent) | Retry + fallback chain |
| LLM timeout | No (transparent) | Fallback chain |
| All providers exhausted | Yes | Error message in session |
| Context overflow | No (transparent, up to 3x) | Compaction |
| Tool execution failure | Yes (agent sees it) | Agent reasoning |
| Session not found | Yes | HTTP 404 / CLI error |
| Max iterations | Yes (partial response) | User retries |
| Missing required config | App won't start | Fix config |
