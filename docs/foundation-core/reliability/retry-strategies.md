# Retry Strategies

## Overview

Daemon applies different retry strategies to different failure domains. The
strategies are chosen based on whether the failure is transient (network
hiccup, rate limit) or structural (wrong API key, provider outage), and
whether the caller can tolerate latency for a retry or needs a fast failure.

---

## Provider Fallback Chain

### Mechanism

`MiosaProviders.Registry` maintains an ordered list of LLM providers. On each
LLM request, it evaluates the fallback chain in order, skipping providers whose
`MiosaLLM.HealthChecker` circuit is open or rate-limited.

### Configuration

The chain is configured at boot and is provider-ordered. A typical production
chain:

```
Anthropic → OpenAI → Groq → Ollama
```

Providers are health-checked at startup via `MiosaProviders.Ollama.auto_detect_model/0`
and `Agent.Tier.detect_ollama_tiers/0` (for local models). Remote providers are
checked lazily on first request failure via `HealthChecker`.

### Behavior

- Fallback is transparent: the caller receives a response from whichever
  provider answered, with no change to the return type
- The provider that answered is available in the response metadata
- If all chain members are unavailable, the registry returns
  `{:error, :no_providers_available}` — no retry is attempted at this layer
  because the caller's session-level hook pipeline handles user feedback

### Why No Backoff Here

Provider fallback does not use backoff. The circuit breaker in `HealthChecker`
already enforces a 30-second cooldown on open circuits. Introducing additional
wait at the fallback layer would stall the user interaction. Instead, failing
fast to the next provider gives the user a response immediately.

---

## Dead Letter Queue Retry

### Mechanism

`Events.DLQ` retries failed event handler dispatches with exponential backoff.

### Parameters

| Parameter | Value |
|---|---|
| Base delay | 1,000 ms |
| Backoff multiplier | 2x |
| Maximum delay | 30,000 ms |
| Maximum attempts | 3 |
| Jitter | None (deterministic retry) |

### Retry Schedule

| Attempt | Delay after previous failure |
|---|---|
| 1 (initial) | Immediate enqueue, retry after 1 second |
| 2 | 2 seconds after attempt 1 |
| 3 | 4 seconds after attempt 2 |
| Exhausted | Algedonic alert emitted; entry dropped |

The retry scheduler runs on a periodic tick (every 1 second). Entries with
`next_retry_at <= System.monotonic_time(:millisecond)` are dispatched in that
tick.

### Handler Identity

Handlers are stored as MFA (module, function, args) tuples in ETS, not as
closures. This ensures that even if the DLQ GenServer restarts mid-retry
cycle, the handler reference remains valid and callable after restart.

---

## MCP Server Reconnection

### Mechanism

When an MCP server's OS process exits, its managing GenServer begins a
reconnection loop. Reconnection uses exponential backoff with jitter.

### Parameters

| Parameter | Value |
|---|---|
| Base delay | 1,000 ms |
| Backoff multiplier | 2x |
| Maximum delay | 60,000 ms |
| Jitter | ±20% of computed delay |
| Maximum attempts | Unlimited (retries indefinitely) |

### Reconnection Sequence

1. OS process exits — GenServer receives `:DOWN` from Port monitor
2. Tools for this MCP server are un-registered from `Tools.Registry`
3. Reconnection attempt with base delay
4. On success: re-execute JSON-RPC initialize handshake, re-register tools
5. On failure: back off and retry

Jitter prevents synchronized reconnection storms when multiple MCP servers
restart simultaneously (e.g., after a host reboot).

---

## SSE Reconnection (Desktop Channel)

The desktop channel uses Server-Sent Events (SSE) over HTTP for streaming
agent responses. The client-side reconnection strategy is:

### Parameters

| Parameter | Value |
|---|---|
| Initial delay | 1,000 ms |
| Backoff multiplier | 2x |
| Maximum delay | 30,000 ms |
| Maximum attempts | 5 |
| Reset after successful connection | Yes |

### Backoff Sequence

| Attempt | Reconnect delay |
|---|---|
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 | 16 seconds (capped at 30 seconds) |

After 5 failed reconnection attempts, the client surfaces an error to the user
and stops retrying automatically. The user can manually trigger reconnection via
the channel UI.

The server-side SSE stream in `Daemon.EventStream` is stateless
per connection. Reconnecting clients receive the current agent state via the
initial SSE `data:` payload — they do not need to replay missed events.

---

## Tool Execution: LLM Self-Correction

### Mechanism

Tool errors are not retried by Daemon's infrastructure. Instead, errors are
returned to the LLM as tool result messages. The LLM is then responsible for
deciding how to proceed: retry with corrected parameters, use a different tool,
or ask the user for clarification.

### Iteration Limit

The agent loop enforces a maximum iteration count to prevent infinite
tool-call loops. The default maximum is 20 iterations per agent turn. If the
iteration limit is reached, the loop returns the last assistant message and a
notice to the user.

### Why LLM-Level Self-Correction

Automatic infrastructure-level tool retry is counterproductive for LLM-driven
agents. If a tool call fails because the LLM passed an incorrect parameter, an
automatic retry with the same parameters will fail again. The LLM has the
context to understand why the call failed (from the error message in the tool
result) and can generate a corrected call. Infrastructure retry is reserved for
infrastructure failures (network, timeouts), not semantic errors.

### Tool Timeout Retry

Sandbox tool timeouts (`{:error, :timeout}`) follow the same path: the error
is returned to the LLM as a tool result. The LLM can choose to retry the
operation with a smaller input, a simpler task, or to inform the user that the
operation timed out.

---

## Summary

| Domain | Strategy | Max Attempts | Backoff |
|---|---|---|---|
| LLM provider fallback | Ordered chain, next available | Chain length | None (circuit breaker handles cooldown) |
| DLQ event retry | Exponential backoff | 3 | 1s → 2s → 4s (max 30s) |
| MCP reconnection | Exponential backoff + jitter | Unlimited | 1s → 2s → ... → 60s |
| SSE reconnection | Exponential backoff | 5 | 1s → 2s → 4s → 8s → 16s (max 30s) |
| Tool execution | LLM self-correction | 20 iterations | N/A (LLM-driven) |
