# Events: Telemetry

OSA instruments key operations through the standard Elixir `:telemetry` library, the event Bus, and ETS atomic counters in hook metrics. This document catalogs the instrumentation points, metric names, and what each measures.

---

## Hook Metrics (ETS Atomic Counters)

Hook execution is tracked via the `:osa_hook_metrics` ETS table. Counters use `:atomics` for lock-free increments — no GenServer bottleneck.

Each hook execution records:

| Counter key | Description |
|-------------|-------------|
| `{hook_name, :calls}` | Total invocations of this hook |
| `{hook_name, :errors}` | Total hook execution errors |
| `{hook_name, :duration_us}` | Cumulative execution time in microseconds |

Hooks tracked by name:
- `security-check`
- `context-optimizer`
- `hierarchical-compaction`
- `mcp-cache`
- `auto-format`
- `send-event`
- `learning-capture`
- `error-recovery`
- `telemetry`
- `episodic-memory`
- `metrics-dashboard`
- `validate-prompt`
- `log-session`
- `pattern-consolidation`

---

## Bus Event Metrics

The Bus emits events that downstream subscribers can use to build metrics. Key events with observability value:

| Event type | Payload fields | What to measure |
|-----------|----------------|----------------|
| `:llm_request` | `model`, `session_id`, `token_estimate` | LLM call volume, model distribution |
| `:llm_response` | `usage.input_tokens`, `usage.output_tokens`, `duration_ms` | Latency, token usage, cost |
| `:tool_call` | `name`, `phase` (`:start`/`:end`), `duration_ms` | Tool latency, call frequency |
| `:tool_result` | `name`, `success`, `error` | Tool error rates |
| `:agent_response` | `session_id`, `duration_ms` | End-to-end response latency |
| `:channel_connected` | `channel`, `pid` | Channel availability |
| `:channel_disconnected` | `channel` | Channel loss |
| `:algedonic_alert` | `severity`, `message`, `metadata` | System health issues |
| `:system_event` | `event` (sub-type), various | Orchestrator, task, context pressure |

### Context pressure events

The `:system_event` with `event: :context_pressure` payload:

| Field | Type | Description |
|-------|------|-------------|
| `utilization` | float | Context window % used |
| `estimated_tokens` | integer | Current token count |
| `max_tokens` | integer | Context window limit |

Thresholds: warn at 85%, auto-compact at 90%, hard-stop protection at 95%.

---

## Noise Filter Metrics

`NoiseFilter.calibrate_weights/2` accepts a `stats` map with message count buckets:

| Bucket | Range |
|--------|-------|
| `"0.0-0.2"` | Very low signal |
| `"0.2-0.5"` | Low signal |
| `"0.5-0.8"` | Medium signal |
| `"0.8-1.0"` | High signal |

Track these counts to assess filter calibration effectiveness. Calibration requires at least 50 samples.

---

## Rate Limiter Metrics

The `RateLimiter` ETS table `:osa_rate_limits` can be queried for current state:

```elixir
:ets.tab2list(:osa_rate_limits)
# => [{ip_string, token_count, last_refill_unix_seconds}, ...]
```

Log entries are written at `:warning` level on every 429 response:
```
[RateLimiter] 429 for 1.2.3.4 on /api/v1/orchestrate
```

---

## DLQ Metrics

`Events.DLQ` exposes:

| Function | Description |
|----------|-------------|
| `DLQ.depth/0` | Number of items currently in the queue |
| `DLQ.entries/0` | Full entry list with retry counts and error details |

Exhausted entries emit `:algedonic_alert` with severity `:high`.

---

## Scheduler Metrics

`Agent.Scheduler.status/0` returns:

| Field | Description |
|-------|-------------|
| `cron_active` | Number of enabled cron jobs |
| `cron_total` | Total cron jobs |
| `trigger_active` | Number of enabled triggers |
| `trigger_total` | Total triggers |
| `heartbeat_pending` | Pending tasks in HEARTBEAT.md |
| `next_heartbeat` | DateTime of next heartbeat check |

Circuit breaker state per job: `failure_count` and `circuit_open` boolean are included in `Scheduler.list_jobs/0` output.

---

## HTTP Analytics Endpoint

`GET /api/v1/analytics` returns system-level metrics via `DataRoutes`. The exact schema is provider-dependent, but typically includes:

- Active session count.
- Tool call counts.
- LLM request/response totals.
- Memory store statistics.

---

## Command Center Dashboard

`GET /api/v1/command-center/metrics` returns aggregated system metrics for the command center UI. Includes event bus stats, hook metrics, and agent fleet status.

`GET /api/v1/command-center/events` returns recent system events (last N events from the Bus).

---

## Recommended Instrumentation

For production deployments, attach `:telemetry` handlers to log or forward Bus events to an external metrics system:

```elixir
# In your application supervisor or a dedicated GenServer:
Bus.register_handler(:llm_response, fn %{usage: usage, duration_ms: ms} ->
  :telemetry.execute([:osa, :llm, :response], %{
    duration: ms,
    input_tokens: Map.get(usage, :input_tokens, 0),
    output_tokens: Map.get(usage, :output_tokens, 0)
  })
end)

Bus.register_handler(:algedonic_alert, fn %{severity: sev, message: msg} ->
  Logger.error("[ALGEDONIC] #{sev}: #{msg}")
  # page on-call, etc.
end)
```

---

## See Also

- [bus.md](bus.md) — Full event type catalog
- [protocol.md](protocol.md) — CloudEvents and OSCP encoding
