# Infrastructure: Sidecar

The sidecar subsystem integrates external language processes (Go, Python, Rust) with OSA through a capability-based dispatch layer. It provides lifecycle management, health monitoring, circuit breaking, telemetry, and a shared JSON-RPC wire protocol.

---

## Architecture

```
Sidecar.Manager (GenServer)
  |-- health poll every 30s
  |
  +-> Sidecar.Registry (ETS: :osa_sidecar_registry)
  |     {module, pid, health, capabilities, updated_at}
  |
  +-> Sidecar.CircuitBreaker (ETS: :osa_circuit_breakers)
  |     {module, state, failure_count, timestamp}
  |
  +-> Sidecar.Telemetry
        :telemetry events for observability
```

External processes communicate over stdio using newline-delimited JSON-RPC, defined by `Sidecar.Protocol`.

---

## Sidecar.Behaviour

Every sidecar process must implement three callbacks:

```elixir
@callback call(method :: String.t(), params :: map(), timeout :: pos_integer()) ::
            {:ok, term()} | {:error, term()}

@callback health_check() :: :ready | :starting | :degraded | :unavailable

@callback capabilities() :: [atom()]
```

| Health state | Meaning |
|---|---|
| `:ready` | Fully operational |
| `:starting` | Process initializing, not yet ready |
| `:degraded` | Responding but with reduced quality |
| `:unavailable` | Not responding |

`capabilities/0` returns a list of atoms representing what the sidecar provides, e.g., `[:tokenization, :embeddings]`. The Manager uses these to route calls to the correct backend.

---

## Sidecar.Manager

`Sidecar.Manager` is the unified entry point for all sidecar calls.

### Dispatch

```elixir
# Route by capability to the best available sidecar
Sidecar.Manager.dispatch(:tokenization, "count_tokens", %{"text" => "hello"})
# => {:ok, %{"count" => 3}}

Sidecar.Manager.dispatch(:embeddings, "embed", %{"text" => "hello"}, 30_000)
# => {:ok, %{"vector" => [...]}}

# Status of all registered sidecars
Sidecar.Manager.status()
# => [%{name: MySidecar, pid: #PID<...>, health: :ready, capabilities: [...], updated_at: ...}]
```

### Dispatch path

```
dispatch(capability, method, params, timeout)
  |-> Registry.find_by_capability(capability)
  |     -> priority: :ready > :degraded > :starting
  |-> CircuitBreaker.allow?(module)
  |     -> {:error, :circuit_open} if open
  |-> Telemetry.call_start(...)
  |-> sidecar_module.call(method, params, timeout)
  |     -> success: CircuitBreaker.record_success + Telemetry.call_stop
  |     -> failure: CircuitBreaker.record_failure + Telemetry.call_exception
  |-> {:ok, result} | {:error, reason}
```

When multiple sidecars offer the same capability, the Manager selects by health priority: `:ready` first, then `:degraded`, then `:starting`. Unavailable sidecars are never selected.

### Health polling

On startup and every 30 seconds, the Manager calls `health_check/0` on every registered sidecar:

```elixir
# health_check raises → :unavailable
Registry.update_health(name, health)
Telemetry.health(name, health)
```

Health failures are isolated per sidecar; one unavailable sidecar does not affect others.

---

## Sidecar.Registry

ETS-backed registry (table `:osa_sidecar_registry`). Rows: `{name, pid, health, capabilities, updated_at}`.

```elixir
# Register a sidecar with its capability list
Sidecar.Registry.register(MySidecar, [:tokenization])

# Update health after health_check
Sidecar.Registry.update_health(MySidecar, :ready)

# Capability-based lookup (returns [{module, pid, health}])
Sidecar.Registry.find_by_capability(:tokenization)

# All registered sidecars
Sidecar.Registry.all()

# Remove when process terminates
Sidecar.Registry.unregister(MySidecar)
```

The registry is `:public` with `read_concurrency: true` for lock-free reads from the Manager and from `dispatch/4` callers.

---

## Sidecar.CircuitBreaker

Per-sidecar circuit breaker for fault isolation. State stored in ETS (`:osa_circuit_breakers`), keyed by module atom.

### State machine

```
:closed --[5 consecutive failures]--> :open
:open   --[30s elapsed]-------------> :half_open (one probe allowed)
:half_open --[probe succeeds]-------> :closed
:half_open --[probe fails]----------> :open
```

| Parameter | Value |
|-----------|-------|
| Failure threshold | 5 consecutive failures |
| Recovery timeout | 30 000 ms |

```elixir
CircuitBreaker.allow?(MySidecar)         # => true | false
CircuitBreaker.record_success(MySidecar) # => :ok (resets counter, closes)
CircuitBreaker.record_failure(MySidecar) # => :ok (increments; may open)
CircuitBreaker.state(MySidecar)          # => {:closed | :open | :half_open, failure_count}
CircuitBreaker.reset(MySidecar)          # => :ok (manual recovery)
```

During `:half_open`, only the probe call is allowed through. Subsequent calls return `false` from `allow?/1` until the probe resolves.

---

## Sidecar.Protocol

`Sidecar.Protocol` defines the wire format used by Go/Python/Rust sidecars over stdio.

### Message format

Each message is a single JSON line terminated by `\n`.

```
Request:   {"id":"a3f4","method":"count_tokens","params":{"text":"hello"}}\n
Response:  {"id":"a3f4","result":{"count":3}}\n
Error:     {"id":"a3f4","error":{"code":-1,"message":"failed"}}\n
```

### API

```elixir
# Encode a request — returns {correlation_id, newline_terminated_binary}
{id, line} = Sidecar.Protocol.encode_request("count_tokens", %{"text" => "hello"})
# id = "a3f4"
# line = ~s({"id":"a3f4","method":"count_tokens","params":{"text":"hello"}}\n)

# Decode a response line
{:ok, id, result}           = Sidecar.Protocol.decode_response(line)
{:error, id, error_map}     = Sidecar.Protocol.decode_response(error_line)
{:error, :invalid, reason}  = Sidecar.Protocol.decode_response(malformed)

# Generate a correlation ID (8 hex chars, cryptographically random)
Sidecar.Protocol.generate_id()
# => "a3f4b2c1"
```

The `id` field correlates requests with responses. IDs are 8-character hex strings generated from 4 random bytes (`Base.encode16(:crypto.strong_rand_bytes(4))`).

---

## Sidecar.Telemetry

All sidecar calls emit standard `:telemetry` events.

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:osa, :sidecar, :call, :start]` | `system_time` | `sidecar`, `method`, `params_size` |
| `[:osa, :sidecar, :call, :stop]` | `duration` (monotonic) | `sidecar`, `method`, `result` (`:ok`/`:error`) |
| `[:osa, :sidecar, :call, :exception]` | `duration` | `sidecar`, `method`, `reason` |
| `[:osa, :sidecar, :health]` | `system_time` | `sidecar`, `status` |
| `[:osa, :sidecar, :circuit_breaker]` | `system_time` | `sidecar`, `from`, `to` |

`params_size` is the byte size of the JSON-encoded params map. Duration is in native time units (convert with `System.convert_time_unit/3`).

Attach handlers via `:telemetry.attach/4`:

```elixir
:telemetry.attach(
  "my-handler",
  [:osa, :sidecar, :call, :stop],
  fn _event, %{duration: d}, %{sidecar: s, method: m}, _config ->
    Logger.info("#{s}.#{m} completed in #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end,
  nil
)
```

---

## Implementing a Sidecar

```elixir
defmodule MyApp.Sidecars.Tokenizer do
  @behaviour OptimalSystemAgent.Sidecar.Behaviour

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def capabilities, do: [:tokenization]

  @impl true
  def health_check do
    # Check if subprocess is alive
    :ready
  end

  @impl true
  def call(method, params, timeout) do
    GenServer.call(__MODULE__, {:rpc, method, params}, timeout)
  end

  def init(:ok) do
    # Register with the sidecar registry
    OptimalSystemAgent.Sidecar.Registry.register(__MODULE__, capabilities())
    # ... start subprocess, open Port, etc.
    {:ok, %{}}
  end
end
```

---

## See Also

- [mcp.md](mcp.md) — MCP protocol for stdio JSON-RPC tool servers
- [sandbox.md](sandbox.md) — Isolated code execution environments
- [../events/telemetry.md](../events/telemetry.md) — OSA-wide telemetry catalog
