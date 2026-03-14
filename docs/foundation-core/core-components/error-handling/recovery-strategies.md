# Recovery Strategies

## Audience

Engineers understanding OSA's fault tolerance model and operators diagnosing degraded-mode operation.

## Overview

OSA uses layered recovery: retry within a provider, then fall back across providers, then degrade gracefully if all providers are unavailable. The OTP supervision tree handles process crashes automatically. Circuit breakers prevent cascading failures across provider calls.

---

## Provider Fallback Chain

The primary recovery mechanism for LLM failures. `Providers.Registry` maintains a prioritized list of providers; when the active provider fails, the next available provider in the chain is tried.

### Chain Construction

Built at boot in `runtime.exs` from configured API keys, excluding the default provider:

```
OSA_FALLBACK_CHAIN=anthropic,openai,ollama   ← explicit override
OR (auto-built):
  All providers with configured API keys + Ollama if TCP-reachable
  → default provider removed from chain
```

Example: with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` set, default `:anthropic`, Ollama running:

```
default:         :anthropic
fallback chain:  [:openai, :ollama]
```

### Fallback Trigger Conditions

The fallback chain is tried when the primary provider returns:

1. Any `{:error, reason}` that is not a rate-limit (rate limits trigger the retry wrapper first)
2. `{:error, {:rate_limited, _}}` after exhausting `@max_retries` (3) retry attempts

```elixir
# In Providers.Registry.call_with_fallback/4
case with_retry(fn -> apply_provider(module, messages, opts) end) do
  {:ok, _} = result ->
    HealthChecker.record_success(provider)
    result

  {:error, {:rate_limited, retry_after}} ->
    HealthChecker.record_rate_limited(provider, retry_after)
    try_fallback_chain(provider, messages, opts, "rate-limited (HTTP 429)")

  {:error, reason} ->
    HealthChecker.record_failure(provider, reason)
    # filter chain to available providers, try each in order
    chat_with_fallback(messages, remaining_chain, opts)
end
```

### Fallback Chain Filtering

Before trying fallbacks, the chain is filtered for availability:

```elixir
remaining_chain
|> Enum.drop_while(&(&1 == failed_provider))   # skip past the failed one
|> filter_boot_excluded_providers()             # skip Ollama if TCP-probe failed at boot
|> Enum.filter(&HealthChecker.is_available?/1) # skip open circuits and rate-limited providers
```

Log output when fallback is triggered:

```
Provider :anthropic failed: timeout. Trying fallback chain: [:openai, :ollama]
Provider :anthropic rate-limited (HTTP 429), trying next available: [:openai]
```

### No Available Fallback

If the filtered chain is empty, the error is returned to the caller:

```
Provider :anthropic failed, no fallback configured: timeout
```

This propagates to `Agent.Loop` which surfaces it to the user.

---

## Retry with Backoff

`Providers.Registry.with_retry/1` wraps individual provider calls with automatic rate-limit retry:

| Attempt | Condition | Sleep before retry |
|---------|-----------|-------------------|
| 1 | `{:error, {:rate_limited, N}}` | `min(N, 60)` seconds |
| 2 | `{:error, {:rate_limited, N}}` | `1s * 2^1 = 2s` (if no `N`) |
| 3 | `{:error, {:rate_limited, N}}` | `1s * 2^2 = 4s` (if no `N`) |
| 4+ | any | Not retried, return error |

Non-rate-limit errors are not retried — they go directly to the fallback chain.

---

## Circuit Breaker

`OptimalSystemAgent.Providers.HealthChecker` implements a circuit breaker per provider.

| State | Entry condition | Exit condition |
|-------|----------------|----------------|
| `:closed` | Initial state | — |
| `:open` | 3 consecutive failures | Automatic after 30 seconds |
| `:half_open` | 30 seconds after `:open` | Success → `:closed`; Failure → `:open` |

The circuit opens to prevent wasted requests to a clearly broken provider. The 30-second cooldown allows temporary outages to self-heal.

Rate limiting is tracked separately — a provider can be rate-limited while its circuit is `:closed`. `is_available?/1` returns `false` for both open circuits and active rate limits:

```elixir
HealthChecker.is_available?(:anthropic)  # => false if open circuit OR rate-limited
```

Log messages:

```
[HealthChecker] anthropic: circuit OPENED after 3 consecutive failures (last reason: timeout)
[HealthChecker] anthropic: circuit half-open (cooldown expired)
[HealthChecker] anthropic: circuit closed (probe succeeded)
[HealthChecker] openai: rate-limited for 60s
```

---

## Context Overflow Recovery

When an LLM call fails with a context overflow error, `Agent.Loop` invokes `Agent.Compactor` to summarize the conversation history:

1. Compactor makes an LLM call with a summarization prompt
2. The summary replaces older messages in the conversation
3. The original LLM call is retried with the compacted history

Up to 3 compaction attempts are made per session turn. If all 3 fail:

```
Context overflow after 3 compaction attempts (iteration N)
```

The session returns an error to the user.

The three compaction thresholds (from `config.exs`) determine when proactive compaction triggers before an overflow:

```elixir
compaction_warn: 0.80,        # 80% — log warning
compaction_aggressive: 0.85,  # 85% — compact aggressively
compaction_emergency: 0.95    # 95% — emergency compact before next LLM call
```

---

## OTP Supervision Recovery

The supervision tree provides automatic process restart on crash. Restart strategies:

| Supervisor | Strategy | Implication |
|------------|----------|-------------|
| `OptimalSystemAgent.Supervisor` (root) | `:rest_for_one` | Infrastructure crash restarts all children above it |
| `Supervisors.Infrastructure` | `:rest_for_one` | Events.Bus crash restarts DLQ, Bridge.PubSub, Telemetry, and everything above |
| `Supervisors.Sessions` | `:one_for_one` | Channel adapter crash does not affect session supervisor |
| `Supervisors.AgentServices` | `:one_for_one` | Scheduler crash does not restart Memory or Budget |
| `Supervisors.Extensions` | `:one_for_one` | Fleet crash does not restart Python sidecar |
| `Agent.Loop` (per session) | `:transient` | Restarts on crash; normal exit is not restarted |

`Agent.Loop` uses `:transient` restart so completed sessions (normal exit) are not restarted, but crashed sessions are given one recovery attempt. On restart, `Checkpoint.restore_checkpoint/1` attempts to resume from the last saved state.

---

## Graceful Degradation

When optional features are unavailable, OSA falls back to simpler implementations:

| Feature | Failure | Fallback |
|---------|---------|---------|
| Python semantic search | Sidecar not running | Keyword-based memory search |
| Go BPE tokenizer | Binary missing | Word-count heuristic for token estimation |
| Ollama not reachable | TCP probe fails at boot | Excluded from fallback chain; cloud providers used |
| Vault storage write fails | Debug log | Response proceeds without observation write |
| Tool output > 51,200 bytes | Truncated | Agent receives truncated output with size indicator |
| `Events.DLQ.enqueue` fails (table gone) | `rescue ArgumentError` | Silent no-op — avoids crash in dispatch path |

---

## Event Handler Recovery

Failed event handlers are recovered by `Events.DLQ` (see [Dead Letter Queue](dead-letter-queue.md)). The key design principle: handler failures are never surfaced to the event emitter. `Events.Bus.emit/3` always returns `{:ok, event}` regardless of handler outcomes.

---

## Sidecar Circuit Breaker

`Sidecar.Manager` maintains circuit breaker ETS tables for each sidecar process (Go tokenizer, Python semantic search, etc.). When a sidecar becomes unresponsive, its circuit opens and OSA falls back to the BEAM-native implementation. The sidecar continues running — the circuit closes automatically when it responds successfully again.
