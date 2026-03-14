# Metrics

## Telemetry.Metrics GenServer

`OptimalSystemAgent.Telemetry.Metrics` is a GenServer under
`Supervisors.Infrastructure` that collects runtime metrics by subscribing to
`Events.Bus` and exposing a query API.

All metric state lives in ETS `:osa_telemetry` (`:set`, `:public`, named table).
This allows concurrent reads from any process without going through the GenServer.
Writes go through `GenServer.cast/2` to serialize updates.

```elixir
# Read from any process (no GenServer call)
Telemetry.Metrics.get_metrics()
Telemetry.Metrics.get_summary()
Telemetry.Metrics.get_analytics_summary()

# Write through GenServer (serialized)
Telemetry.Metrics.record_tool_execution("search_files", 42)
Telemetry.Metrics.record_provider_call(:anthropic, 1200, true)
Telemetry.Metrics.record_noise_filter_result(:filtered)
Telemetry.Metrics.record_signal_weight(0.73)
```

## Collected Metrics

### Tool Executions

Keyed by tool name. Per-tool stats:

```elixir
%{
  "read_file" => %{
    count:    142,
    total_ms: 5880,
    min_ms:   8,
    max_ms:   312,
    window:   [12, 18, 9, ...]  # last 100 durations for p99
  }
}
```

Populated by `tool_result` event subscriptions. The `name` field in the event
payload identifies the tool (falls back to `"tool"` or `"unknown"` if absent).

Summary output adds computed fields:

```elixir
%{
  "read_file" => %{
    count:   142,
    avg_ms:  41.41,
    min_ms:  8,
    max_ms:  312,
    p99_ms:  287     # 99th percentile from last 100 calls
  }
}
```

### Provider Latency

Rolling window of the last 100 call durations per provider:

```elixir
%{
  anthropic: [1842, 2103, 987, ...],  # last 100 latencies in ms
  openai:    [892, 1204, 756, ...]
}
```

Populated by `llm_response` event subscriptions.

Summary output:

```elixir
%{
  anthropic: %{avg_ms: 1644.0, p99_ms: 2890, count: 47},
  openai:    %{avg_ms: 950.7,  p99_ms: 1802, count: 12}
}
```

### Provider Call Counts

Simple counters per provider atom:

```elixir
%{anthropic: 47, openai: 12, groq: 3}
```

### Provider Error Counts

Counts failed calls (where `success: false` in the `llm_response` event):

```elixir
%{anthropic: 2, groq: 1}
```

### Session Statistics

```elixir
%{
  turns_by_session: %{
    "session-abc" => 12,
    "session-def" => 3
  },
  messages_today:  15,   # incremented per llm_response event
  sessions_today:  2     # incremented when a new session_id is first seen
}
```

Note: `messages_today` is incremented on `llm_response` events (not
`user_message`), because `user_message` events are not currently emitted in the
codebase. This means the count approximates the number of LLM calls today.

### Token Statistics

Cumulative token counts from `usage` maps in `llm_response` events:

```elixir
%{
  input_tokens:  48920,
  output_tokens: 12344
}
```

### Noise Filter Rate

Tracks outcomes of `NoiseFilter.check/2`:

```elixir
%{
  filtered: 23,   # messages discarded as noise
  clarify:  4,    # messages that triggered clarification requests
  pass:     201   # messages that passed to the LLM
}
```

Summary: `noise_filter_rate` is `(filtered + clarify) / total * 100` as a
percentage.

### Signal Weight Distribution

Messages bucketed by their Signal Theory weight (0.0–1.0):

```elixir
%{
  "0.0-0.2": 12,   # low signal — noise/chat
  "0.2-0.5": 34,   # medium-low signal
  "0.5-0.8": 89,   # medium-high signal
  "0.8-1.0": 93    # high signal — task-oriented
}
```

## Analytics Summary

The `/analytics` command and `GET /api/analytics` HTTP endpoint use
`get_analytics_summary/0`:

```elixir
%{
  sessions_today: 2,
  total_messages: 15,
  tokens_used: 61264,       # input_tokens + output_tokens
  top_tools: [
    {"read_file", 142},
    {"run_command", 87},
    {"write_file", 34}
  ],
  provider_calls: %{anthropic: 47, openai: 12}
}
```

## Hooks Metrics

The `Agent.Hooks` system maintains separate per-hook metrics in ETS
`:osa_hooks_metrics` with `:write_concurrency: true`:

```elixir
:ets.new(:osa_hooks_metrics, [:named_table, :public, :set, {:write_concurrency, true}])
```

Per-hook counters:

| Key | Type | Description |
|-----|------|-------------|
| `{event, :call_count}` | integer | Total invocations |
| `{event, :total_us}` | integer | Cumulative microseconds |
| `{event, :blocks_count}` | integer | Times a hook returned `{:block, _}` |

Updated by `Hooks.run/2` in the caller's process after each hook chain
execution:

```elixir
defp update_metrics_ets(event, elapsed_us, result) do
  :ets.update_counter(:osa_hooks_metrics, {event, :call_count}, {2, 1}, {{event, :call_count}, 0})
  :ets.update_counter(:osa_hooks_metrics, {event, :total_us},   {2, elapsed_us}, {{event, :total_us}, 0})

  if match?({:blocked, _}, result) do
    :ets.update_counter(:osa_hooks_metrics, {event, :blocks_count}, {2, 1}, {{event, :blocks_count}, 0})
  end
end
```

Average latency per hook event: `total_us / call_count`.

## Disk Persistence

`Telemetry.Metrics` writes a snapshot to `~/.osa/metrics.json` every 5 minutes
and on supervisor shutdown (`terminate/2`):

```json
{
  "schema_version": 1,
  "flushed_at": "2026-03-14T12:00:00Z",
  "tool_executions": { ... },
  "provider_latency": { ... },
  "provider_calls": { ... },
  "provider_errors": { ... },
  "session_stats": { ... },
  "token_stats": { ... },
  "noise_filter_rate": 11.82,
  "signal_weight_distribution": { ... }
}
```

The file is overwritten on each flush, not appended. It represents a point-in-time
snapshot of the current runtime, not a historical log. Historical analysis should
use the JSONL session files in `~/.osa/sessions/`.
