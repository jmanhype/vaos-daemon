# Scaling Guide

Audience: operators running OSA at higher loads or tuning for resource-constrained environments.

## BEAM VM Fundamentals

OSA runs on the BEAM (Erlang Virtual Machine). Key properties that affect scaling:

- **Schedulers:** The BEAM creates one OS thread per CPU core by default. The default of `+S <cores>` is appropriate for most workloads.
- **Process model:** Each agent session spawns several lightweight BEAM processes (GenServers). The BEAM can comfortably handle hundreds of thousands of processes; OSA's per-session overhead is low.
- **Memory:** BEAM memory is managed per-process with per-process heaps. Garbage collection is incremental and never stops all schedulers simultaneously.

## Process Count

Each active session creates processes including the channel session GenServer, the agent loop process, and several GenServer-backed subsystems (hooks pipeline, memory, etc.). In practice, a few dozen processes per active session is typical.

Monitor:

```elixir
:erlang.system_info(:process_count)
```

The default process limit is 262,144. For workloads with thousands of concurrent sessions, raise this limit in the VM args file (`rel/vm.args.eex` if present, or via `ELIXIR_ERL_OPTIONS`):

```bash
export ELIXIR_ERL_OPTIONS="+P 1000000"
```

For typical single-user or small-team deployments, the default is more than sufficient.

## Scheduler Tuning

For CPU-bound workloads (local Ollama with large models), the default scheduler count matches CPU cores. For I/O-bound workloads (cloud LLM APIs), dirty I/O schedulers may help:

```bash
# Increase dirty I/O schedulers for heavy HTTP concurrency
export ELIXIR_ERL_OPTIONS="+SDio 16"
```

OSA's main bottleneck is LLM API latency, not CPU. Scheduler tuning has minimal impact unless you are running many concurrent sessions with local models.

## SQLite Connection Pool

The `Store.Repo` (SQLite3) is configured with `pool_size: 5` in `config/config.exs`. SQLite serializes writes — a large pool size does not increase write throughput. The default of 5 is appropriate for single-user and small multi-session workloads.

For read-heavy workloads, SQLite's WAL mode (already enabled) allows concurrent readers. The pool size only limits simultaneous Ecto checkout operations, not SQLite-level concurrency.

Do not increase `pool_size` above 10 for SQLite. If you need higher write throughput, consider switching to PostgreSQL via `DATABASE_URL` (platform mode).

## PostgreSQL Pool (Platform Mode)

When `DATABASE_URL` is set, `Platform.Repo` uses PostgreSQL with a configurable pool size:

```bash
POOL_SIZE=20    # default is 10
```

Size the pool to approximately 1–2 × your peak concurrent session count. PostgreSQL defaults allow up to 100 connections (`max_connections`); ensure your pool does not exceed `max_connections - 5` (reserve slots for admin connections).

For high concurrency, set `POOL_SIZE` in conjunction with PostgreSQL's `max_connections` and `pg_bouncer` if needed.

## ETS Table Limits

OSA creates 7 named ETS tables at startup. Named tables are global to the node and do not scale horizontally. They are bounded by the data OSA writes to them — entries are cleared when sessions end.

Monitor total ETS memory:

```elixir
:erlang.memory(:ets)
```

If ETS memory grows unboundedly, the most likely cause is session cleanup not running (e.g., a channel adapter crash before the session end hook fires). Investigate with:

```elixir
:ets.info(:osa_cancel_flags, :size)
:ets.info(:osa_files_read, :size)
:ets.info(:osa_pending_questions, :size)
```

## Provider Rate Limit Management

Cloud LLM providers enforce rate limits on requests per minute (RPM) and tokens per minute (TPM). OSA does not implement automatic provider-level rate limiting or backoff beyond what the HTTP client (`req`) provides.

### Strategies

**Provider rotation:** Set `OSA_FALLBACK_CHAIN` to list multiple providers. OSA will automatically fail over to the next provider when a call fails (including 429 rate limit responses).

```bash
OSA_FALLBACK_CHAIN=anthropic,openai,groq
```

**Per-call budget limit:** Set `OSA_PER_CALL_LIMIT_USD` to a low value to prevent runaway calls during retries.

**Session isolation:** Each agent session is independent. Sessions do not share a rate limit pool at the OSA level — rate limits are enforced by the provider per API key.

**Multiple API keys:** If running many concurrent sessions against one provider, distribute load across multiple API keys (one per session pool) using session-level provider overrides via the hot-swap API:

```bash
POST /api/v1/models/switch
{"provider": "openai", "model": "gpt-4o", "api_key": "sk-..."}
```

### Ollama Throughput

Ollama serializes inference requests on a single GPU. Concurrent sessions sharing one Ollama instance will queue. To increase throughput:

- Run multiple Ollama instances on different ports and rotate via `OLLAMA_URL`.
- Use smaller quantized models (e.g., `qwen2.5:3b` instead of `qwen2.5:7b`) for faster per-request latency.

## Memory Tuning

The main sources of heap growth in OSA:

| Source | Mitigation |
|--------|-----------|
| Large tool outputs | `max_tool_output_bytes` is 50 KB by default. Reduce to 20 KB for memory-constrained environments. |
| Long context windows | Compaction thresholds (`compaction_warn: 0.80`, `compaction_aggressive: 0.85`, `compaction_emergency: 0.95`) control when history is compressed. Lower these if memory is constrained. |
| Vault observation buffer | `vault_observation_flush_interval: 60_000` (1 minute) controls how long observations buffer in memory before flushing to disk. |
| Session JSONL files | Sessions accumulate on disk. Set up periodic pruning of old files in `~/.osa/sessions/`. |

## Binary Memory

BEAM binaries larger than 64 bytes live on a shared binary heap. Large tool outputs (file reads, command output) are passed as binaries and can cause binary memory spikes. Monitor:

```elixir
:erlang.memory(:binary)
```

If binary memory grows steadily, check for sessions holding references to large tool output binaries. Context compaction (which runs at the thresholds above) helps by dropping old messages that hold binary references.

## Horizontal Scaling

OSA is designed as a single-node agent. The BEAM supports clustering (`Node.connect/1`) but OSA does not implement distributed state. Horizontal scaling approaches:

- **Sidecar per user:** Run one OSA instance per user or team. Each instance has its own `~/.osa/` data directory and SQLite database.
- **Fleet mode:** The optional fleet subsystem (`OSA_FLEET_ENABLED=true`) registers remote agent instances and dispatches tasks across them. See the fleet documentation for details.
- **Load balancer + shared PostgreSQL:** Multiple OSA instances can share a PostgreSQL platform database when `DATABASE_URL` is configured, allowing session routing across instances.

## Container Resource Limits

For Docker deployments, start with these limits and tune based on observed usage:

```yaml
# docker-compose.yml
services:
  osa:
    mem_limit: 512m       # 256m minimum, 1g recommended for heavy use
    cpus: "1.0"           # 0.5 minimum, 2.0 for heavy concurrent use
```

For sandbox execution (`OSA_SANDBOX_ENABLED=true`), each sandboxed command spawns a Docker container with its own limits (`sandbox_max_memory: "256m"`, `sandbox_max_cpu: "0.5"`). Account for these in host resource planning.
