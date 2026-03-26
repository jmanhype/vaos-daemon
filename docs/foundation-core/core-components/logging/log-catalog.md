# Log Catalog

## Audience

Operators monitoring Daemon in production who need to know what specific log messages mean and what action to take.

## How to Use This Catalog

Grep for the bracketed prefix or key phrase. Messages use the format:
```
[LEVEL] [prefix] message content
```

---

## Startup and Initialization

### `Event bus started — :daemon_event_router compiled`
**Level:** info
**Source:** `Events.Bus`
**Meaning:** goldrush routing module compiled successfully. Normal startup.
**Action:** None.

### `[Application] Platform enabled — starting Platform.Repo`
**Level:** info
**Source:** `Application`
**Meaning:** `DATABASE_URL` was set; PostgreSQL Ecto repo is starting.
**Action:** None. Absence of this message when you expect it means `DATABASE_URL` is not set.

### `Providers: anthropic, openai, ollama`
**Level:** info
**Source:** `Providers.Registry`
**Meaning:** These providers were detected as configured at boot.
**Action:** Verify this list matches your expected providers.

### `[Providers.Registry] Ollama not reachable at boot — skipping in fallback chain`
**Level:** info
**Source:** `Providers.Registry`
**Meaning:** TCP probe to Ollama endpoint failed at startup. Ollama will not be used as a fallback.
**Action:** If Ollama is intended to be used, verify it is running and `OLLAMA_URL` is correct.

### `[Extensions] Treasury enabled — starting MiosaBudget.Treasury`
**Level:** info
**Source:** `Supervisors.Extensions`
**Meaning:** `DAEMON_TREASURY_ENABLED=true` was set; Treasury GenServer is starting.
**Action:** None.

### `Failed to compile :daemon_event_router: ...`
**Level:** warning
**Source:** `Events.Bus`
**Meaning:** goldrush compilation failed. Events will not be routed.
**Action:** Check goldrush dependency is present in `mix.lock`. Look at the error detail for the specific failure.

---

## Provider and LLM

### `Rate limited (attempt N/3). Retrying in Xs...`
**Level:** warning
**Source:** `Providers.Registry`
**Meaning:** Provider returned HTTP 429. Automatic retry in progress.
**Action:** None. If this appears frequently, consider adding `DAEMON_FALLBACK_CHAIN` or raising budget limits on the provider.

### `Provider :anthropic failed: timeout. Trying fallback chain: [:openai, :ollama]`
**Level:** warning
**Source:** `Providers.Registry`
**Meaning:** Primary provider failed; switching to next provider in chain.
**Action:** Investigate why the primary provider is failing. Check provider status page.

### `Provider :anthropic failed, no fallback configured: timeout`
**Level:** error
**Source:** `Providers.Registry`
**Meaning:** Provider failed and no fallback is available. The agent call will fail.
**Action:** Configure a fallback provider via `DAEMON_FALLBACK_CHAIN`, or investigate why the primary provider is unreachable.

### `[HealthChecker] anthropic: circuit OPENED after 3 consecutive failures (last reason: timeout)`
**Level:** warning
**Source:** `Providers.HealthChecker`
**Meaning:** Anthropic is now temporarily bypassed. All requests will route to the fallback chain for 30 seconds.
**Action:** Check provider connectivity. Circuit will self-heal after 30 seconds; no manual intervention required.

### `[HealthChecker] anthropic: rate-limited for 60s`
**Level:** warning
**Source:** `Providers.HealthChecker`
**Meaning:** Provider returned HTTP 429 and is now excluded from the chain for 60 seconds.
**Action:** Check if you are exceeding provider tier limits. Consider upgrading plan or adding more fallback providers.

### `[HealthChecker] anthropic: circuit closed (probe succeeded)`
**Level:** info
**Source:** `Providers.HealthChecker`
**Meaning:** Provider recovered successfully after being in a degraded state.
**Action:** None.

---

## Agent Loop

### `[loop] Restored checkpoint for session sess-abc — iteration=5, messages=12`
**Level:** info
**Source:** `Agent.Loop`
**Meaning:** A session was restarted (after a crash or restart) and picked up from where it left off.
**Action:** None. This is the crash recovery mechanism working correctly.

### `[loop] Cancel requested for session sess-abc`
**Level:** info
**Source:** `Agent.Loop`
**Meaning:** `Loop.cancel/1` was called, either by user command or HTTP API.
**Action:** None.

### `Agent loop hit max iterations (20)`
**Level:** warning
**Source:** `Agent.Loop`
**Meaning:** The agent reached the `max_iterations` limit without completing its task. The current partial response is returned.
**Action:** If this is frequent, increase `max_iterations` in config, or investigate whether the agent is in a repetitive pattern.

### `Context overflow — compacting and retrying (overflow_retry 1/3, iteration N)`
**Level:** warning
**Source:** `Agent.Loop`
**Meaning:** The conversation history exceeded the model's context window. Auto-compaction is running.
**Action:** None on first occurrence. Repeated occurrences for the same session may indicate very long-running tasks; consider breaking them into smaller steps.

### `Context overflow after 3 compaction attempts (iteration N)`
**Level:** error
**Source:** `Agent.Loop`
**Meaning:** Compaction failed 3 times. The session will return an error.
**Action:** Check if the `Compactor` service is running (`Agent.Compactor` GenServer). May indicate a provider error blocking the compaction LLM call.

### `[loop] Output guardrail: LLM response contained system prompt content — replacing with refusal`
**Level:** warning
**Source:** `Agent.Loop`
**Meaning:** The LLM echoed back parts of the system prompt in its response. The response was replaced with a refusal message.
**Action:** This may indicate a prompt injection attempt or a weak model. Consider switching to a stronger model or tightening the system prompt.

### `[loop] Auto-continue: model described intent without tool calls (nudge 1/2)`
**Level:** info
**Source:** `Agent.Loop`
**Meaning:** The agent responded with text describing what it would do instead of calling tools. A nudge prompt was injected.
**Action:** None for occasional occurrences. Frequent occurrences may indicate the model is poorly suited for tool use.

### `[loop] signal_weight=0.12 < 0.20 — skipping tools for low-weight input`
**Level:** debug
**Source:** `Agent.Loop`
**Meaning:** The signal classifier rated the message as low-signal; tool dispatch was disabled. A plain LLM call was made.
**Action:** None. This prevents hallucinated tool sequences for inputs like "ok" or "thanks".

---

## Events and DLQ

### `[Bus] Handler crash for tool_result: FunctionClauseError ...`
**Level:** warning
**Source:** `Events.Bus`
**Meaning:** An event handler raised an exception. The event was routed to the DLQ for retry.
**Action:** Investigate the handler implementation. Check if this is happening for one handler or many.

### `[DLQ] Enqueued failed tool_result event: handler raised: ...`
**Level:** warning
**Source:** `Events.DLQ`
**Meaning:** A failed event has entered the retry queue.
**Action:** None immediately. Watch for escalation to error if retries exhaust.

### `[DLQ] Event tool_result exhausted 3 retries, dropping. Last error: ...`
**Level:** error
**Source:** `Events.DLQ`
**Meaning:** A handler failed permanently after 3 retry attempts. An algedonic alert was emitted.
**Action:** Investigate the handler logic. This represents a persistent bug in an event handler. Look at the "Last error" detail.

### `[Bus] Signal failure mode :noise on tool_result: high noise content`
**Level:** warning
**Source:** `Events.Bus`
**Meaning:** Signal Theory failure mode detected on a sampled event.
**Action:** Informational. No immediate action required. Persistent warnings for the same event type may indicate a noisy signal source.

---

## HTTP and Rate Limiting

### `[RateLimiter] 429 for 1.2.3.4 on /api/v1/sessions`
**Level:** warning
**Source:** `Channels.HTTP.RateLimiter`
**Meaning:** A client IP exceeded the rate limit (60 req/min for general routes, 10 req/min for auth routes).
**Action:** Investigate if this is a legitimate client hitting limits (raise limits or add client-side backoff) or an attack.

### `[API] Unhandled exception: ...`
**Level:** error
**Source:** `Channels.HTTP.API`
**Meaning:** An unhandled exception occurred in an API handler. The client received a 500 response.
**Action:** Investigate the exception. This indicates a bug in a route handler.

---

## Telemetry

### `[Telemetry.Metrics] Started — flushing to ~/.daemon/metrics.json every 5m`
**Level:** info
**Source:** `Telemetry.Metrics`
**Meaning:** Metrics GenServer started. Metrics will be written to disk every 5 minutes.
**Action:** None.

### `[Telemetry.Metrics] Failed to write metrics: ...`
**Level:** warning
**Source:** `Telemetry.Metrics`
**Meaning:** Disk write for metrics.json failed.
**Action:** Check disk space and permissions on `~/.daemon/`. This does not affect agent operation.
