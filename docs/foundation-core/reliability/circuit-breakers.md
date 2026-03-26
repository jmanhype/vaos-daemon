# Circuit Breakers

## Overview

Daemon uses circuit breakers in two distinct domains: LLM provider health tracking
(managed by `MiosaLLM.HealthChecker`) and sidecar process fault isolation
(managed by `Daemon.Sidecar.CircuitBreaker`). Both follow the
standard three-state circuit breaker pattern but are tuned for their respective
workloads.

---

## LLM Provider Circuit Breaker

### Implementation

`Daemon.Providers.HealthChecker` is a named GenServer started
under `Supervisors.Infrastructure` before `MiosaProviders.Registry`. It stores
per-provider health state in GenServer state (a map keyed by provider atom).

The GenServer is aliased as `MiosaLLM.HealthChecker` via the shim layer in
`lib/miosa/shims.ex`.

### States

| State | Meaning | Request behavior |
|---|---|---|
| `:closed` | Provider is healthy | Requests flow normally |
| `:open` | Provider has failed repeatedly | Requests are rejected immediately |
| `:half_open` | Cooldown expired, probing | One request allowed through as probe |
| `:rate_limited` | HTTP 429 received | Requests rejected until window expires |

`:rate_limited` is a sub-state that coexists with the circuit state. A provider
can be both `:closed` (circuit) and `:rate_limited` at the same time, in which
case `is_available?/1` returns false.

### Thresholds

| Parameter | Value |
|---|---|
| Failure threshold (open trigger) | 3 consecutive failures |
| Open timeout (half-open transition) | 30,000 ms |
| Probe success (close trigger) | 1 successful call in `:half_open` |
| Default rate-limit window | 60,000 ms |
| Rate-limit window with `Retry-After` | `Retry-After` value in seconds × 1,000 ms |

### Transition Logic

```
record_failure/2 called:
  failure_count + 1 >= 3  →  state = :open, opened_at = now

record_success/1 called:
  state == :half_open  →  state = :closed, failure_count = 0
  state == :closed     →  failure_count = 0 (reset streak)

is_available?/1 called:
  state == :open AND (now - opened_at) >= 30_000  →  transition to :half_open, return true
  state == :open AND within cooldown               →  return false
  state == :half_open                              →  return true (probe allowed)
  rate_limited AND within window                   →  return false
  otherwise                                         →  return true
```

### Public API

```elixir
# Record outcomes
MiosaLLM.HealthChecker.record_success(:anthropic)
MiosaLLM.HealthChecker.record_failure(:groq, :timeout)
MiosaLLM.HealthChecker.record_rate_limited(:openai, 30)

# Query
MiosaLLM.HealthChecker.is_available?(:anthropic)  # => true | false

# Inspect all states (debugging/monitoring)
MiosaLLM.HealthChecker.state()
# => %{anthropic: %{state: :closed, failures: 0, ...}, ...}
```

### Integration Point

`MiosaProviders.Registry` calls `MiosaLLM.HealthChecker.is_available?/1` for
each provider in the fallback chain before attempting a request. Unavailable
providers are skipped without an RPC call.

`MiosaProviders.Registry` calls `record_success/1` and `record_failure/2` on
each LLM response, keeping the circuit state current.

---

## Sidecar Circuit Breaker

### Implementation

`Daemon.Sidecar.CircuitBreaker` is a pure ETS-based circuit
breaker with no GenServer. State is stored in the `:daemon_circuit_breakers` ETS
table, initialized by `Daemon.Sidecar.Manager` at startup.

Using ETS (with `read_concurrency: true`) allows lock-free concurrent reads
from multiple agent Loop processes calling sidecar tools simultaneously.

### Table Schema

```
{sidecar_module :: atom(), state :: :closed | :open | :half_open, failure_count :: non_neg_integer(), opened_at :: integer()}
```

`opened_at` is `System.monotonic_time(:millisecond)`.

### States and Thresholds

| Parameter | Value |
|---|---|
| Failure threshold (open trigger) | 5 consecutive failures |
| Recovery timeout (half-open transition) | 30,000 ms |
| Probe success (close trigger) | 1 successful call in `:half_open` |

The sidecar threshold is 5 (vs. 3 for LLM providers) because sidecar failures
are more often transient (process restart, RPC timeout) and less catastrophic
than provider API failures. A higher threshold reduces false positives.

### Transition Logic

```
allow?(name):
  no entry         →  true  (first call; circuit starts closed)
  :closed          →  true
  :open, cooldown expired  →  write :half_open to ETS, return true (probe)
  :open, within cooldown   →  false
  :half_open               →  false (probe already in flight; block others)

record_success(name):
  :half_open  →  delete entry (= :closed, failure_count = 0)
  :closed     →  :ets.delete (no-op if absent)

record_failure(name):
  :closed, failures + 1 >= 5   →  write :open, opened_at = now
  :closed, failures + 1 < 5    →  increment failure_count
  :half_open                    →  write :open, opened_at = now
  :open                         →  no change (already open)
```

### Public API

```elixir
# Initialize table (called by Sidecar.Manager)
Daemon.Sidecar.CircuitBreaker.init()

# Check before calling sidecar
if Daemon.Sidecar.CircuitBreaker.allow?(Daemon.Go.Tokenizer) do
  call_sidecar(...)
else
  {:error, :circuit_open}
end

# Report outcomes
Daemon.Sidecar.CircuitBreaker.record_success(Daemon.Go.Tokenizer)
Daemon.Sidecar.CircuitBreaker.record_failure(Daemon.Go.Tokenizer)

# Inspect state
Daemon.Sidecar.CircuitBreaker.state(Daemon.Go.Tokenizer)
# => :closed | :open | :half_open
```

### Sidecar Coverage

The circuit breaker is applied to all sidecar modules managed under
`Supervisors.Extensions`:

| Sidecar | Module |
|---|---|
| Go Tokenizer | `Daemon.Go.Tokenizer` |
| Go Git | `Daemon.Go.Git` |
| Go Sysmon | `Daemon.Go.Sysmon` |
| Python | `Daemon.Python.Supervisor` |
| WhatsApp Web | `Daemon.WhatsAppWeb` |

---

## Comparison

| Property | LLM HealthChecker | Sidecar CircuitBreaker |
|---|---|---|
| Storage | GenServer state | ETS (`:daemon_circuit_breakers`) |
| Concurrency model | Serialized via GenServer | Lock-free ETS reads |
| Failure threshold | 3 | 5 |
| Recovery timeout | 30 seconds | 30 seconds |
| Rate limiting | Yes (HTTP 429) | No |
| Scope | Per LLM provider (atom) | Per sidecar module (atom) |
| Initialized by | `Infrastructure` supervisor start | `Sidecar.Manager` start |
| Survives process restart | No (GenServer state lost) | No (ETS owned by Manager) |

Both circuit breakers reset to `:closed` on process restart. This is acceptable
because after a restart, it is reasonable to probe providers and sidecars
anew — the previous failure may have been caused by the restarted process
itself rather than the external dependency.
