# Monitoring

Audience: operators running OSA in production who need visibility into agent health and performance.

## Health Endpoint

OSA exposes a health check at `GET /health`. This endpoint is used by the Docker healthcheck and any load balancer or uptime monitor:

```bash
curl http://localhost:8089/health
# {"status":"ok"}
```

HTTP 200 means the Bandit HTTP server is accepting connections. The endpoint does not verify LLM provider reachability or database connectivity — it confirms only that the OTP application is running and the HTTP channel is live.

For the Docker deployment, the healthcheck is configured as:

```
interval: 30s
timeout: 5s
start-period: 10s
retries: 3
```

## Metrics

`OptimalSystemAgent.Telemetry.Metrics` is a GenServer that subscribes to the internal event bus and tracks runtime statistics. It writes a JSON snapshot to `~/.osa/metrics.json` every 5 minutes.

Read the current metrics via the API:

```bash
curl http://localhost:8089/api/v1/analytics
```

The analytics endpoint returns:

```json
{
  "sessions_today": 12,
  "total_messages": 347,
  "tokens_used": 184320,
  "top_tools": [
    ["file_read", 89],
    ["search_files", 45],
    ["run_command", 38]
  ],
  "provider_calls": {
    "anthropic": 180,
    "ollama": 12
  }
}
```

### Tracked Metrics

| Metric | Description |
|--------|-------------|
| `tool_executions` | Call count and duration histogram per tool name |
| `provider_latency` | Average and p99 latency per provider (sliding window of last 100 calls) |
| `provider_calls` | Total call count per provider atom |
| `session_stats` | Turns per session, messages per day, sessions today |
| `token_stats` | Cumulative input and output tokens from LLM response usage maps |
| `noise_filter_rate` | Percentage of messages filtered by the noise filter |
| `signal_weights` | Distribution across buckets: 0–0.2, 0.2–0.5, 0.5–0.8, 0.8–1.0 |

The metrics snapshot file at `~/.osa/metrics.json` is updated every 5 minutes (`@flush_interval_ms = 5 * 60 * 1_000` in `Telemetry.Metrics`).

## Erlang VM Metrics

OSA runs on the BEAM. The following VM metrics are available via `:erlang` BIFs and are useful for diagnosing resource pressure:

```elixir
# Total process count (warn if approaching scheduler count × 1000)
:erlang.system_info(:process_count)

# Memory breakdown
:erlang.memory()
# => [total: N, processes: N, binary: N, ets: N, atom: N, ...]

# Scheduler utilization (0.0–1.0)
:scheduler.utilization(1)

# ETS table count
length(:ets.all())
```

From the shell (requires a running release with `--remsh` or IEx):

```bash
./_build/prod/rel/osagent/bin/osagent_release remote
# then in IEx:
iex> :erlang.system_info(:process_count)
iex> :erlang.memory()
```

## ETS Tables

OSA creates the following named ETS tables at startup in `Application.start/2`:

| Table | Type | Purpose |
|-------|------|---------|
| `:osa_cancel_flags` | `:set, :public` | Per-session cancel flags for the agent loop |
| `:osa_files_read` | `:set, :public` | Read-before-write tracking per session |
| `:osa_survey_answers` | `:set, :public` | HTTP endpoint answers for `ask_user_question` polling |
| `:osa_context_cache` | `:set, :public` | Cached Ollama model context window sizes |
| `:osa_survey_responses` | `:bag, :public` | Survey/waitlist responses when platform DB is not enabled |
| `:osa_session_provider_overrides` | `:set, :public` | Per-session provider/model hot-swap overrides |
| `:osa_pending_questions` | `:set, :public` | Pending `ask_user` questions visible via API |

None of these tables are bounded in size by the ETS table itself — OSA's logic clears entries when sessions end. Monitor total ETS memory with `:erlang.memory(:ets)` if running many concurrent sessions.

## Process Monitoring

The supervision tree has four subsystem supervisors under a top-level `:rest_for_one` strategy:

- `OptimalSystemAgent.Supervisors.Infrastructure` — registries, PubSub, event bus, storage, telemetry
- `OptimalSystemAgent.Supervisors.Sessions` — channel adapters, session DynamicSupervisor
- `OptimalSystemAgent.Supervisors.AgentServices` — memory, workflow, orchestration, hooks, scheduler
- `OptimalSystemAgent.Supervisors.Extensions` — opt-in subsystems (treasury, intelligence, swarm, fleet, sidecars)

A crash in Infrastructure restarts all supervisors above it (`:rest_for_one`). Monitor the process count for unexpected growth — each active agent session spawns GenServer processes.

Check process count via the API:

```bash
curl http://localhost:8089/api/v1/command-center/metrics
```

## Budget Alerts

OSA's budget subsystem tracks spend per API call. When the daily or monthly limit is reached, the agent stops making LLM calls and returns an error to the user.

Monitor budget status:

```bash
curl http://localhost:8089/api/v1/analytics
# Look for budget fields in the response
```

Set conservative daily limits in production to prevent runaway spend:

```bash
OSA_DAILY_BUDGET_USD=10.0
OSA_PER_CALL_LIMIT_USD=1.0
```

## Provider Response Times

Provider latency p99 is tracked in `Telemetry.Metrics` with a sliding window of 100 calls. Access it via `Metrics.get_metrics()` from IEx or via the `/api/v1/analytics` endpoint.

Alert thresholds to consider:

| Provider type | p99 warning | p99 critical |
|---------------|------------|-------------|
| Cloud API (Anthropic, OpenAI) | > 10s | > 30s |
| Local (Ollama) | > 60s | > 120s |

High p99 from a cloud provider usually indicates rate limiting or model overload — check the provider status page.

## Log Levels

OSA uses the Elixir Logger with these defaults by environment:

| Environment | Logger level |
|-------------|-------------|
| `dev` | `:debug` |
| `prod` | `:info` |

In production, set the log level via `config/prod.exs` or override at runtime. Critical errors (`Logger.error/1`) are always emitted. Agent turn details, tool calls, and provider requests are logged at `:debug`.

To temporarily increase verbosity on a running release:

```elixir
# In IEx remote shell
Logger.configure(level: :debug)
```

## Alerting Recommendations

| Condition | Check | Action |
|-----------|-------|--------|
| Health endpoint down | `GET /health` returns non-200 | Page on-call; the OTP application may have crashed |
| Process count growing | `:erlang.system_info(:process_count)` > 5000 | Investigate session leak; restart if memory grows |
| Memory > 1 GB | `:erlang.memory(:total)` | Profile with `:recon_alloc` or restart |
| Budget exceeded | `/api/v1/analytics` budget fields | Review cost, adjust limits, or add API credits |
| Provider p99 > 30s | analytics endpoint | Switch to fallback provider via `OSA_DEFAULT_PROVIDER` |
| DB file > 1 GB | `~/.osa/osa.db` size | Truncate old sessions; see backup-recovery.md |
