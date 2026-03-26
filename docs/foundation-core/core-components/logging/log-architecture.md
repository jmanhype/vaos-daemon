# Log Architecture

## Audience

Operators running Daemon in production and engineers adding log output to new modules.

## Overview

Daemon uses the standard Elixir `Logger` with no external logging dependencies. Log level is controlled by environment. Structured metadata is passed as keyword lists. No log aggregation pipeline is built in — operators are expected to collect stdout/stderr via their infrastructure (systemd, Docker, Kubernetes log drivers, etc.).

## Logger Configuration

| Environment | Level | Set in |
|-------------|-------|--------|
| development | `:debug` | `config/dev.exs` |
| production | `:info` | `config/prod.exs` |
| test | `:warning` | `config/test.exs` |

Base config (`config/config.exs`):
```elixir
config :logger, level: :warning
```

The base default is `:warning`; environment files override it. In dev you get full debug output; in prod you see info and above; in test, only warnings and errors appear to keep test output clean.

## Adding Structured Metadata

Always `require Logger` at the top of a module. Pass metadata as the second argument:

```elixir
require Logger

Logger.info("Provider switched", provider: :anthropic, session_id: session_id)
Logger.warning("Rate limited", provider: provider, retry_after: 60)
Logger.error("Tool execution failed", tool: "file_write", reason: reason)
```

Metadata keys are arbitrary atoms. They appear in the log output if the formatter includes them.

## Log Prefix Convention

Daemon modules use bracketed prefixes in the message string for easy grepping. This is a convention, not enforced by the framework:

| Prefix | Module |
|--------|--------|
| `[loop]` | `Agent.Loop` |
| `[Bus]` | `Events.Bus` |
| `[DLQ]` | `Events.DLQ` |
| `[HealthChecker]` | `Providers.HealthChecker` |
| `[RateLimiter]` | `Channels.HTTP.RateLimiter` |
| `[Telemetry.Metrics]` | `Telemetry.Metrics` |
| `[Extensions]` | `Supervisors.Extensions` |
| `[Application]` | `Application` |
| `[API]` | `Channels.HTTP.API` |
| `[CommCoach]` | `Intelligence.CommCoach` |

## Log Levels by Category

### `:debug`

- Tool execution details (input args, raw output before truncation)
- Session strategy switches
- Signal weight gate decisions: `signal_weight=0.12 < 0.20 — skipping tools`
- HealthChecker availability checks: `anthropic: circuit open, skipping (14s left)`
- Telemetry flush: `Metrics written to ~/.daemon/metrics.json`
- Rate limiter stale entry cleanup

### `:info`

- Application lifecycle: agent boot, MCP tool registration
- Event bus startup: `Event bus started — :daemon_event_router compiled`
- Session lifecycle: checkpoint restore, strategy initialization
- Provider registration: `Registered custom provider: my_provider -> MyModule`
- Providers initialization: `Providers: anthropic, openai, ollama`
- Circuit breaker state changes: `anthropic: circuit closed (probe succeeded)`
- DLQ startup: `[DLQ] Started`
- Cancellation receipt: `[loop] Cancel requested for session sess-abc`
- Auto-continue nudges: `Auto-continue: model described intent without tool calls (nudge 1/2)`

### `:warning`

- Provider failures triggering fallback: `Provider :anthropic failed: timeout. Trying fallback chain: [:openai]`
- Rate limiting: `Rate limited (attempt 1/3). Retrying in 30s...`
- Circuit breaker opened: `anthropic: circuit OPENED after 3 consecutive failures`
- Max iterations reached: `Agent loop hit max iterations (20)`
- Context overflow: `Context overflow — compacting and retrying (overflow_retry 1/3, iteration 5)`
- Event handler crashes: `[Bus] Handler crash for tool_result: ...`
- DLQ enqueue: `[DLQ] Enqueued failed tool_result event: ...`
- Signal failure modes: `[Bus] Signal failure mode :noise on tool_result: high noise`
- Output guardrail: `[loop] Output guardrail: LLM response contained system prompt content`
- HTTP 429 rate limit: `[RateLimiter] 429 for 1.2.3.4 on /api/v1/sessions`
- goldrush compile failure: `Failed to compile :daemon_event_router: ...`

### `:error`

- All providers exhausted: `Provider :anthropic failed, no fallback configured: timeout`
- DLQ exhaustion: `[DLQ] Event tool_result exhausted 3 retries, dropping. Last error: ...`
- Context overflow unrecoverable: `Context overflow after 3 compaction attempts (iteration 7)`
- LLM call failure: `LLM call failed: ...`
- HTTP API unhandled exception: `[API] Unhandled exception: ...`
- Provider module raised: `Provider module MyModule raised: ...`

## What Is Not Logged

By design, Daemon never logs:

- API keys or bearer tokens
- JWT contents or signing secrets
- User message content (to protect privacy)
- LLM response content (to protect privacy)
- Password fields from any input

`Channels.HTTP.Auth` handles JWTs and explicitly avoids logging token values.

## Log Output Format

Default Elixir Logger format:

```
2026-03-14 12:34:56.789 [info] [loop] Restored checkpoint for session sess-abc
— iteration=5, messages=12
```

For production deployments, configure JSON log format using a formatter library (e.g. `logger_json`) and add it to `config/prod.exs`. Daemon does not ship a JSON formatter but is compatible with any standard Logger backend.

## Enabling Debug Logs at Runtime

In a running IEx session:

```elixir
Logger.configure(level: :debug)
```

To target a specific module only (Elixir Logger does not support per-module levels natively, but you can filter with `Logger.configure(compile_time_purge_matching: [...])` in config).

## Log Rotation

Daemon writes to stdout/stderr. Log rotation is the responsibility of the host process manager:

- **systemd**: `StandardOutput=journal` with journald rotation
- **Docker**: configure the `json-file` log driver with `max-size` and `max-file`
- **Kubernetes**: kubelet captures stdout; use a sidecar log aggregator

One file Daemon does write to disk: `~/.daemon/metrics.json` (flushed every 5 minutes by `Telemetry.Metrics`). This is not a log file and does not rotate — it is overwritten on each flush.
