# Retry Policy

## LLM Provider Retry — Fallback Chain

Daemon does not retry the same provider on failure. Instead, it fails over to the
next provider in the `fallback_chain`. This is more reliable than per-provider
retry because most LLM failures are either rate limits (where backing off helps
less than switching providers) or service outages (where retrying is futile).

### Fallback Chain Construction

The chain is built at boot in `config/runtime.exs`:

```elixir
fallback_chain: (
  case System.get_env("DAEMON_FALLBACK_CHAIN") do
    nil ->
      # Auto-detect from configured API keys
      candidates = [
        {:anthropic, System.get_env("ANTHROPIC_API_KEY")},
        {:openai,    System.get_env("OPENAI_API_KEY")},
        {:groq,      System.get_env("GROQ_API_KEY")},
        {:openrouter, System.get_env("OPENROUTER_API_KEY")},
        # ... more providers
      ]
      configured = for {name, key} <- candidates, key not in [nil, ""], do: name

      # Ollama added only if TCP reachable (1s probe)
      ollama_reachable = tcp_probe("localhost", 11434, 1_000)
      (configured ++ if(ollama_reachable, do: [:ollama], else: []))
      |> Enum.reject(&(&1 == default_provider))

    csv ->
      csv |> String.split(",") |> Enum.map(&String.to_existing_atom(String.trim(&1)))
  end
)
```

The active provider is excluded from the chain (no point failing back to the
same provider that just failed).

### Fallback Behavior

```elixir
defp try_with_fallback(request, providers) do
  Enum.reduce_while(providers, {:error, "No providers"}, fn provider, _acc ->
    case call_provider(provider, request) do
      {:ok, response} ->
        {:halt, {:ok, response}}
      {:error, reason} ->
        Logger.warning("[LLMClient] #{provider} failed: #{reason}")
        HealthChecker.record_failure(provider)
        {:cont, {:error, reason}}
    end
  end)
end
```

When all providers fail, the loop receives `{:error, "All providers failed"}` and
returns an error message to the user without crashing.

## Circuit Breaker — MiosaLLM.HealthChecker

`MiosaLLM.HealthChecker` tracks provider health and implements the circuit
breaker pattern:

| State | Condition | Effect |
|-------|-----------|--------|
| Closed | Normal operation | Requests pass through |
| Open | N consecutive failures | Requests rejected immediately (no HTTP call) |
| Half-open | After backoff period | One probe request allowed |

The HealthChecker is started under `Supervisors.Infrastructure` before
`MiosaProviders.Registry` so that provider registration can query initial health
state.

```elixir
case HealthChecker.check(provider) do
  :healthy    -> call_provider(provider, request)
  :unhealthy  -> {:error, "Provider #{provider} is circuit-broken"}
  :half_open  -> probe_and_decide(provider, request)
end
```

## DLQ Retry — Exponential Backoff

Event handler failures are retried by `Events.DLQ` with exponential backoff:

| Parameter | Value |
|-----------|-------|
| Base delay | 1,000 ms |
| Multiplier | 2× per attempt |
| Maximum delay | 30,000 ms |
| Maximum attempts | 3 |
| Check interval | 60,000 ms |

```elixir
backoff = min(@base_backoff_ms * :math.pow(2, retries) |> trunc(), @max_backoff_ms)
next_retry_at = now + backoff
```

Backoff schedule:

```
Failure 0 → enqueue: retry after 1,000 ms
Failure 1 → retry 1: retry after 2,000 ms
Failure 2 → retry 2: retry after 4,000 ms
Failure 3 → exhausted: drop + algedonic_alert(:high)
```

The DLQ processes ready entries every 60 seconds. An entry becomes "ready" when
`monotonic_time(:millisecond) >= next_retry_at`.

## MCP Server Reconnection

MCP servers start asynchronously after the supervision tree is up. Each server
GenServer runs under `MCP.Supervisor` (a `DynamicSupervisor` with `:one_for_one`
strategy). When a server crashes, the supervisor restarts it automatically.

Reconnection uses exponential backoff managed by the MCP client's `init/1`:

```elixir
def init(server_config) do
  # Start JSON-RPC handshake
  case start_server_process(server_config) do
    {:ok, port} ->
      {:ok, %{config: server_config, port: port, status: :initializing}}
    {:error, reason} ->
      # OTP supervisor will restart us with increasing delay
      {:stop, reason}
  end
end
```

Backoff is provided by the OTP supervisor's restart intensity settings rather
than custom timers.

## Ollama Reachability Probe

At boot, the Ollama reachability probe uses a 1-second TCP timeout:

```elixir
case :gen_tcp.connect(ollama_host, ollama_port, [], 1_000) do
  {:ok, sock} -> :gen_tcp.close(sock); true
  {:error, _} -> false
end
```

This prevents `Req.TransportError{reason: :econnrefused}` on every LLM call when
Ollama is not running locally.

## Checkpoint Restore on Crash Recovery

When `Agent.Loop` restarts after a crash (`:transient` supervisor restart), it
attempts to restore the previous session state from the checkpoint file:

```elixir
def init(opts) do
  session_id = Keyword.fetch!(opts, :session_id)
  restored = Checkpoint.restore_checkpoint(session_id)

  messages   = Keyword.get(opts, :messages) || Map.get(restored, :messages, [])
  iteration  = Map.get(restored, :iteration, 0)
  turn_count = Map.get(restored, :turn_count, 0)
  plan_mode  = Map.get(restored, :plan_mode, false)
  # ...
end
```

If no checkpoint exists (first start or checkpoint was deleted), `restored` is
`%{}` and all fields default to their initial values. This makes checkpoint
restore a transparent no-op when not needed.

## Tool Execution Retry

Tools do not have built-in retry. A tool failure is returned to the LLM as an
error result message on the same iteration. The LLM decides whether to:

- Retry the tool with corrected arguments
- Try a different tool
- Report the failure to the user

This is intentional: the LLM has better judgment than a fixed retry policy for
determining whether a tool failure is transient (try again) or a logical error
(change approach).

## Sidecar Reconnection

Go and Python sidecars run as managed OS ports. If a sidecar crashes, the BEAM
port is closed and the sidecar GenServer crashes. The supervisor restarts the
GenServer, which re-launches the OS process.

The `Sidecar.Manager` tracks each sidecar's circuit breaker state:

| Consecutive crashes | Action |
|--------------------|--------|
| 0-2 | Immediate restart |
| 3+ | Circuit open: reject calls, log `:error` |
| After 5 minutes | Circuit half-open: allow one probe restart |

This prevents a broken sidecar from consuming all supervisor restart budget
(which would cause the supervisor itself to crash after exceeding intensity).
