# Performance Tuning

Audience: operators who need to optimize OSA for throughput, latency, or cost
efficiency.

Measure before optimizing. The bottleneck is almost always the LLM network
call, not OSA's internal processing.

---

## Token Budget

The token budget controls how many tokens are sent to the LLM per call and
how many can be returned in the response.

```sh
# Maximum tokens in the LLM response (default: 8192)
# Reducing this speeds up responses but may truncate long outputs
OSA_MAX_RESPONSE_TOKENS=4096

# Context window size (default: 128000)
# Must match or be smaller than your model's actual context window
OSA_MAX_CONTEXT_TOKENS=128000
```

In code (reads at runtime):

```elixir
Application.get_env(:optimal_system_agent, :max_response_tokens, 8_192)
Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
```

### Per-provider token limits

Each provider has a different maximum context window. Set
`OSA_MAX_CONTEXT_TOKENS` to match the model you are using:

| Model | Context window |
|-------|---------------|
| claude-opus-4-5 | 200,000 |
| gpt-4o | 128,000 |
| gemini-2.0-flash | 1,000,000 |
| qwen2.5:7b (Ollama) | 32,768 |
| llama3.1:8b (Ollama) | 131,072 |

Setting `OSA_MAX_CONTEXT_TOKENS` higher than the model supports causes the LLM
to return an error. Setting it lower than the model supports wastes capacity
and causes unnecessary compaction.

---

## Context Window Management

The `Agent.Compactor` runs before each LLM call and compresses the
conversation when the token count approaches the limit.

### Thresholds

```
80% utilization  → warning logged
85% utilization  → aggressive compression (merge consecutive messages, summarize)
90% utilization  → cold-zone collapse to key-facts summary (requires LLM call)
95% utilization  → emergency truncation (no LLM, hard drop oldest messages)
```

These thresholds are currently hardcoded in `Agent.Compactor`. They are not
configurable via environment variables.

### Compaction strategy

The compactor divides the message list into three zones:

- **HOT** (last 10 messages): never touched
- **WARM** (messages 11–30): progressive compression pipeline
- **COLD** (messages 31+): collapsed to a single key-facts summary

Progressive steps (stop as soon as utilization drops below target):

1. Strip tool-call argument details (keep tool name and result only)
2. Merge consecutive same-role messages
3. Summarize groups of 5 warm-zone messages (LLM call)
4. Compress cold zone to key-facts (LLM call)
5. Emergency truncation (no LLM, last resort)

### Disable LLM-based compaction

For cost-sensitive deployments where compaction LLM calls are not acceptable,
disable them in config. Only truncation will be used:

```elixir
# config/prod.exs
config :optimal_system_agent, compactor_llm_enabled: false
```

---

## Token Counting

OSA uses a Go binary for accurate BPE token counting:

```
priv/go/tokenizer/osa-tokenizer
```

If the binary is absent or incompatible with the current OS/architecture, the
system falls back to a word-count heuristic:

```
estimated_tokens = words * 1.3 + punctuation * 0.5
```

The heuristic overestimates slightly — compaction triggers conservatively.
This is safe but inefficient: conversations compact sooner than necessary,
incurring extra LLM calls.

To ensure the Go tokenizer is built:

```sh
cd priv/go/tokenizer
go build -o osa-tokenizer .
```

---

## Connection Pooling

### SQLite

The local agent store uses a connection pool via Ecto:

```elixir
# config/config.exs
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  pool_size: 5
```

Default pool size is 5. SQLite serializes writes — increasing the pool size
beyond 5 does not improve write throughput but may help read parallelism for
concurrent session loads.

### PostgreSQL (platform mode)

When `DATABASE_URL` is set, the platform repo uses:

```sh
POOL_SIZE=10  # default when DATABASE_URL is configured
```

Increase for high-concurrency platform deployments:

```sh
POOL_SIZE=25
```

---

## ETS Read Concurrency

Hot-path ETS tables are created with `read_concurrency: true`:

```elixir
:ets.new(:osa_hooks, [:named_table, :bag, :public, read_concurrency: true])
```

This enables concurrent reads from multiple BEAM schedulers. It is already
applied to the tables that see the most read traffic (hooks, tools registry,
cancel flags). No tuning required.

---

## Concurrent Tool Execution

When the LLM returns multiple tool calls in a single response, OSA executes
them in parallel using `Task.async_stream`:

```elixir
# In Agent.Loop.ToolExecutor
Task.async_stream(tool_calls, &execute_tool_call/1, max_concurrency: 5)
```

`max_concurrency` is hardcoded at 5. Independent tools (file reads, web
searches) benefit significantly from parallelism. Dependent tools (write then
read) do not — but the LLM typically serializes those anyway.

---

## Noise Filter

The noise filter eliminates 40–60% of low-signal messages before they reach
the LLM. Thresholds are configurable:

```elixir
# config/prod.exs (or runtime.exs)
config :optimal_system_agent,
  noise_filter_thresholds: %{
    definitely_noise: 0.15,   # below this → filtered with ack (no LLM)
    likely_noise: 0.35,       # below this → filtered with ack (no LLM)
    uncertain: 0.65           # below this → ask for clarification
  }
```

Raising thresholds filters more messages (lower cost, less responsive).
Lowering them passes more messages to the LLM (higher cost, more responsive).

---

## Signal Weight Threshold for Tool Calls

Messages with signal weight below 0.20 receive a plain chat response — no
tool calls are made. This prevents hallucinated tool sequences for
low-information inputs:

```elixir
# In Agent.Loop (read-only, not configurable via env)
@tool_weight_threshold 0.20
```

This threshold is not currently configurable. Modify `agent/loop.ex` to change
it.

---

## Provider Selection for Performance

| Provider | Typical p50 latency | Notes |
|----------|--------------------|----|
| Groq | 0.5–2s | Fastest cloud provider; limited context |
| Anthropic | 1–5s | High quality; streaming reduces perceived latency |
| OpenAI | 1–5s | High quality; streaming reduces perceived latency |
| Ollama (local) | 2–60s | Depends heavily on hardware and model size |
| Cerebras | 0.3–1s | Very fast; limited model selection |

For latency-sensitive deployments, use Groq or Cerebras as the primary
provider with Anthropic or OpenAI as fallback.

---

## Max Iterations

The ReAct loop runs at most `max_iterations` times before forcing a response:

```elixir
# Default: 30
Application.get_env(:optimal_system_agent, :max_iterations, 30)
```

Override via application config:

```elixir
# config/prod.exs
config :optimal_system_agent, max_iterations: 15
```

Reducing iterations limits runaway tool chains but may cause the agent to
give up before completing complex multi-step tasks.

---

## Related

- [Runtime Behavior](./runtime-behavior.md) — supervision and state persistence
- [Monitoring](./monitoring.md) — observe latency and budget in real time
- [Incident Handling](./incident-handling.md) — respond to budget and provider failures
