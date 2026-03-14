# Logging System

## Logger Configuration

OSA uses the standard Elixir `Logger` application. Configuration in
`config/config.exs`:

```elixir
config :logger,
  level: :warning
```

Environment-specific overrides in `config/dev.exs`:

```elixir
config :logger,
  level: :debug
```

In production (`config/prod.exs`), the `:warning` level from `config.exs`
applies. Debug and info logs are compiled out of production builds by Elixir's
macro-based Logger unless `compile_time_purge_matching` is adjusted.

## Log Levels

| Level | Used for | Environment |
|-------|----------|-------------|
| `:debug` | Checkpoint written, compaction triggered, DLQ entry created | Dev only |
| `:info` | Process started, feature flag enabled, MCP server connected | Dev + prod (when explicitly enabled) |
| `:warning` | Expected failures: provider timeout, stream append failed, cancel table not found | All environments |
| `:error` | Permanent failures: DLQ exhausted, unrecoverable crash | All environments |

## Structured Metadata

Logger metadata is set per-process at the start of each session and propagated
to all log entries in that process context:

```elixir
Logger.metadata(
  session_id: state.session_id,
  channel: state.channel,
  provider: state.provider,
  model: state.model
)
```

This means every log line from an `Agent.Loop` process automatically includes
the session identifier, active channel, and LLM provider — no manual inclusion
required.

Example log output in dev:

```
[debug] [loop] Checkpoint written for session abc-123 at iteration 5
  session_id=abc-123 channel=cli provider=anthropic model=claude-sonnet-4-6
```

## Component Prefixes

All log messages include a bracketed component prefix for quick filtering:

```elixir
Logger.info("[Application] Platform enabled — starting Platform.Repo")
Logger.warning("[Bus] Router dispatch error: #{inspect(reason)}")
Logger.warning("[DLQ] Enqueued failed #{event_type} event: #{inspect(error)}")
Logger.info("[vault/lifecycle] Session #{id} woke (clean)")
Logger.warning("[loop] Cancel table not found — agent may not be running")
Logger.info("[Telemetry.Metrics] Started — flushing to ~/.osa/metrics.json every 5m")
Logger.info("[Extensions] Treasury enabled — starting MiosaBudget.Treasury")
```

Prefix conventions:

| Prefix | Module area |
|--------|-------------|
| `[Application]` | `OptimalSystemAgent.Application` |
| `[Bus]` | `Events.Bus` |
| `[DLQ]` | `Events.DLQ` |
| `[loop]` | `Agent.Loop` and its submodules |
| `[vault/lifecycle]` | `Vault.SessionLifecycle` |
| `[Telemetry.Metrics]` | `Telemetry.Metrics` |
| `[Extensions]` | `Supervisors.Extensions` |
| `[LLMClient]` | `Agent.Loop.LLMClient` |
| `[MCP]` | MCP client and server modules |

## Security Logging Rules

Never log:
- API keys or tokens (even partial)
- User conversation content
- File contents read by tools
- Passwords or hashed passwords
- JWT tokens or session secrets

Always log (at `:warning` or above):
- Authentication failures
- Authorization blocks (security_check, spend_guard)
- Provider failures and fallback activations
- DLQ handler exhaustion
- Dirty death detections

## Log Output Format

Elixir Logger outputs to stdout in the default format:

```
HH:MM:SS.mmm [level] message
```

In dev with `config :logger, :console, format: "$time $metadata[$level] $message\n"`,
metadata fields are appended.

For production deployments behind a log aggregator (e.g., Vector, Fluentd), set
the Logger backend to JSON format via `:logger_json` or a custom formatter. OSA
does not ship a custom formatter; this is left to the deployment operator.

## Telemetry Metrics Disk Flush

`Telemetry.Metrics` logs its own flush activity:

```elixir
case File.write(path, payload) do
  :ok ->
    Logger.debug("[Telemetry.Metrics] Metrics written to #{path}")
  {:error, reason} ->
    Logger.warning("[Telemetry.Metrics] Failed to write metrics: #{inspect(reason)}")
end
```

The flush happens every 5 minutes to `~/.osa/metrics.json`. The JSON file is
human-readable and can be tailed for debugging:

```sh
watch -n 30 cat ~/.osa/metrics.json
```

## MCP Server Logging

MCP server subprocesses write to stdout/stderr, which is captured by the BEAM
port and forwarded to Logger:

```elixir
def handle_info({port, {:data, data}}, state) when port == state.port do
  Logger.debug("[MCP:#{state.server_name}] #{String.trim(data)}")
  {:noreply, state}
end
```

Noisy MCP servers can be silenced by raising the Logger level to `:info` or
`:warning` in dev config.
