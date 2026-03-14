# Incident Handling

Audience: operators responding to production incidents in OSA deployments.

---

## Provider Failure

### What happens automatically

When the active provider returns an error (HTTP 5xx, timeout, connection
refused), OSA attempts the fallback chain in order:

1. `MiosaLLM.HealthChecker` records the failure.
2. After 3 consecutive failures, the circuit breaker opens for 30 seconds.
3. `Agent.Loop.LLMClient` retries with the next provider in the fallback chain.
4. The fallback chain is logged at `:info` level: `[loop] Provider fallback: anthropic → openai`.
5. If the chain is exhausted, the user receives an error response.

Recovery is automatic. When the circuit breaker half-opens (30-second
cooldown), the next request probes the provider. A successful probe closes
the breaker.

### Manual intervention

If a provider is failing and you need to route all traffic to a different one
immediately, change the default provider at runtime:

```elixir
# In IEx (takes effect for new sessions immediately)
Application.put_env(:optimal_system_agent, :default_provider, :groq)
```

For a permanent change, set `OSA_DEFAULT_PROVIDER` and restart.

To force a provider's circuit breaker to reset (e.g., after confirming the
provider is back):

```elixir
MiosaLLM.HealthChecker.reset(:anthropic)
```

### Rate limiting (HTTP 429)

The provider returns 429. `HealthChecker` marks it `:rate_limited` for 60
seconds (or the `Retry-After` duration if provided). During this window,
the provider is skipped by the fallback logic.

If the rate limit persists, check your API key's quota and consider upgrading
the plan or distributing load across multiple keys via `OSA_FALLBACK_CHAIN`.

---

## DLQ Overflow

### What happens automatically

When a subscribed event handler crashes, the failed event is placed in the DLQ
with retry metadata. The DLQ retries with exponential backoff:

- Retry 1: after 1 second
- Retry 2: after 2 seconds
- Retry 3: after 4 seconds (capped at 30 seconds)

After all retries fail, an `:algedonic_alert` event is emitted and the entry
is dropped.

### Manual intervention

Inspect the DLQ:

```elixir
OptimalSystemAgent.Events.DLQ.list()
# Each entry shows: event_type, payload, handler MFA, error, retry count
```

Identify the failing handler from the `:handler` field. The handler is stored
as an MFA tuple (module, function, args) for restartability.

Fix the handler code, then flush the DLQ:

```elixir
# Drop all pending entries (fixes symptom; does not replay events)
OptimalSystemAgent.Events.DLQ.flush()

# Force immediate retry of all entries (if handler is now fixed)
OptimalSystemAgent.Events.DLQ.retry_all()
```

If the same event type keeps failing, consider deregistering the handler
until the fix is deployed:

```elixir
OptimalSystemAgent.Events.Bus.unsubscribe(:tool_call, handler_ref)
```

---

## Session Crash

### What happens automatically

Each `Agent.Loop` process runs under `SessionSupervisor` (a DynamicSupervisor
with `:one_for_one` strategy). When a loop crashes:

1. The DynamicSupervisor restarts the loop with its original `start_link`
   arguments.
2. The restarted loop begins with empty `messages` state.
3. Previously persisted messages in SQLite remain — the user can `/resume`
   to recover context.
4. ETS cancel flags for that session are cleared on restart.
5. Other sessions are unaffected.

### Manual intervention

If a session crashes repeatedly (exceeding the supervisor's restart intensity),
the supervisor stops attempting restarts and the session is removed from the
registry. The user receives no response.

To diagnose:

```elixir
# Check if the session still exists in the registry
Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
# => []  means the session was removed after too many crashes

# Check the supervisor's restart intensity settings
Supervisor.count_children(OptimalSystemAgent.SessionSupervisor)
```

To recover the user's conversation:

```elixir
# From IEx, load the persisted message history
OptimalSystemAgent.Agent.Memory.load_session(session_id)
```

Ask the user to start a new session and use `/resume SESSION_ID` to reload
the history.

---

## Budget Exceeded

### What happens automatically

When `MiosaBudget.Budget` records that the daily or per-call limit has been
reached:

1. The `spend_guard` pre-tool-use hook returns `{:block, "Budget exceeded"}`.
2. All tool calls for all sessions are blocked.
3. The LLM can still respond with text (no tool calls), but complex multi-step
   tasks will fail.
4. An `:algedonic_alert` event is emitted with `reason: :budget_exceeded`.
5. A `[:optimal_system_agent, :budget, :exceeded]` telemetry event fires.

### Manual intervention

Check current status:

```elixir
MiosaBudget.Budget.status()
```

If the limit was hit legitimately (user workload), you have two options:

**Option A: Raise the limit temporarily**

```elixir
Application.put_env(:optimal_system_agent, :daily_budget_usd, 100.0)
# Restart the budget GenServer to pick up the new limit
GenServer.stop(MiosaBudget.Budget)
# The supervisor will restart it with the new limit
```

**Option B: Reset the daily counter**

```elixir
MiosaBudget.Budget.reset()
```

`reset/0` sets all counters to zero. Use this only if you are certain the
previous spend was legitimate and you are willing to accept additional spend.

---

## System Prompt Leak (Bug 17)

### Status

Bug 17 is a known issue: weak LLMs (particularly small local models) sometimes
echo the system prompt in their response, despite the input-side guardrail
blocking prompt extraction attempts.

OSA includes an output-side guardrail in `Agent.Loop.Guardrails` that
detects and replaces prompt-leaking responses before they are returned to the
user. The guardrail is logged at warning level:

```
[loop] Output guardrail: LLM response contained system prompt content — replacing with refusal
```

### Mitigation

Until Bug 17 is fixed:

1. Do not use OSA with highly sensitive system prompt content in production.
2. Monitor for `Output guardrail` log lines.
3. If the leak rate is high with your model, switch to a stronger model that
   does not leak.

Models known to leak: small Ollama models (7B and below) when given
adversarial inputs. Anthropic and OpenAI models do not exhibit this behavior
in normal use.

### Fix status

The definitive fix requires a redesign of how the system prompt is structured
to make it harder to elicit via prompt injection. This is tracked as Bug 17.
Do not deploy to untrusted users until Bug 17 is resolved.

---

## Infrastructure Failure (Events.Bus crash)

### What happens

If `Events.Bus` crashes, the `:rest_for_one` strategy in
`Supervisors.Infrastructure` stops and restarts every child that started after
the Bus (DLQ, Bridge.PubSub, Telemetry, HealthChecker, Providers.Registry,
Tools.Registry, and all subsequent children).

This is effectively a full infrastructure restart. All active sessions lose
their in-flight tool calls and receive an error. Persisted messages in SQLite
are unaffected.

### Recovery time

The infrastructure restart takes 1–5 seconds on a healthy system. New session
requests during this window receive connection errors from the HTTP layer.

### Prevention

The Bus uses goldrush's compiled bytecode for routing — there is no runtime
dispatch overhead that could spike CPU and cause starvation. Bus crashes are
caused by:

- An `init/1` crash (startup failure — check configuration)
- An unexpected message to `handle_info` — `Logger.warning` is logged but
  the process does not crash by default

If the Bus crashes repeatedly in production, enable debug logging and
capture the crash reason from the supervisor's crash log.

---

## Escalation Checklist

When an incident cannot be resolved with the above steps:

1. Capture the crash report: `Application.get_env(:logger, :backends)` and
   check the log file or remote shell output.
2. Dump the current ETS state for relevant tables (see
   [Debugging Core](../how-to/debugging/debugging-core.md)).
3. Capture provider health: `MiosaLLM.HealthChecker.status()`.
4. Restart the application as a last resort:
   ```sh
   bin/osa stop
   bin/osa start
   ```
5. If the issue is data corruption in SQLite:
   ```sh
   sqlite3 ~/.osa/osa.db "PRAGMA integrity_check;"
   ```

---

## Related

- [Monitoring](./monitoring.md) — alerts, telemetry, DLQ status
- [Runtime Behavior](./runtime-behavior.md) — supervision strategy and state persistence
- [Debugging Core](../how-to/debugging/debugging-core.md) — inspect the running system
- [Troubleshooting Common Issues](../how-to/debugging/troubleshooting-common-issues.md) — known problems
