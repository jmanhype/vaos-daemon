# Graceful Degradation

OSA is designed to remain useful when components fail. This document describes the
fallback behaviors at each layer: provider selection, local provider availability,
and total provider failure.

---

## Provider Fallback Chains

### Configuration

A fallback chain is set in `config/runtime.exs`:

```elixir
config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq, :ollama]
```

The chain is ordered by preference. The registry tries each provider in sequence,
advancing to the next on failure.

### How the Chain Executes

When `Providers.Registry.chat/2` is called with a specific provider and that provider
fails, the following sequence runs:

1. The request is sent to the configured provider.
2. On success, `HealthChecker.record_success/1` is called and the result is returned.
3. On `{:error, {:rate_limited, retry_after}}`, the provider is marked rate-limited
   in `HealthChecker` and the chain is consulted for the next available provider.
4. On any other `{:error, reason}`, `HealthChecker.record_failure/1` is called and
   the remaining chain is tried.
5. Providers marked `:open` (circuit open) or rate-limited are skipped via
   `HealthChecker.is_available?/1` before each attempt.

Rate-limited providers retry up to 3 times with the Retry-After delay (capped at 60s)
before moving to the next provider in the chain. Exponential backoff applies when no
Retry-After header is present: 1s, 2s, 4s.

### Tier-to-Provider Mapping

The 3-tier model system (Elite → Specialist → Utility) maps to specific models per
provider. When the configured provider is unavailable and a fallback is used, the
same tier is requested from the fallback provider:

| Tier | Anthropic | OpenAI | Groq |
|---|---|---|---|
| Elite | claude-opus-4-6 | gpt-4o | llama-3.3-70b-versatile |
| Specialist | claude-sonnet-4-6 | gpt-4o-mini | llama-3.1-70b-versatile |
| Utility | claude-haiku-4-5 | gpt-3.5-turbo | llama-3.1-8b-instant |

Ollama tier mapping is dynamic: at boot, `Agent.Tier.detect_ollama_tiers/0` queries
`GET /api/tags`, sorts installed models by size, and maps largest → elite,
middle → specialist, smallest → utility.

---

## What Happens When Ollama Is Down

Ollama has special handling because it is the default provider and runs locally.

### Boot-time probe

During `Providers.Registry.init/1`, `Providers.Ollama.reachable?/0` is called. If
Ollama is unreachable (connection refused, timeout), it is excluded from the fallback
chain via `Process.put(:osa_ollama_excluded, true)`. No `:econnrefused` log flood
occurs on subsequent LLM calls.

The boot exclusion is stored in the Registry process dictionary. It applies for the
lifetime of the Registry GenServer.

### Runtime detection

If Ollama starts failing after boot, `HealthChecker` opens its circuit after 3
consecutive failures. The circuit enters `:half_open` after 30 seconds and closes
again on the first successful probe.

### Fallback path

When Ollama is excluded or its circuit is open:

1. The configured fallback chain (e.g., `[:anthropic, :openai, :groq]`) is filtered
   by `HealthChecker.is_available?/1`.
2. The first available cloud provider is used.
3. If no cloud providers are configured (no API keys), the system returns an error.

### What still works without Ollama

- All sessions already using a cloud provider continue unaffected.
- Signal classification falls back to deterministic pattern matching (no LLM needed).
- Memory operations, tool execution, and hook pipeline are all provider-independent.
- The CLI, HTTP API, and all channel adapters remain functional.

---

## What Happens When All Providers Fail

When `Providers.Registry.chat_with_fallback/3` exhausts all providers in the chain:

1. It returns `{:error, "No providers in chain"}` or the last individual error.
2. `Agent.Loop` receives the error from `LLMClient.llm_chat/3`.
3. The loop emits an `:agent_response` event with an error message and returns the
   error to the channel: `"I'm having trouble connecting to the AI provider. Please check your provider configuration or try again."`
4. The session remains alive. The next user message triggers a fresh provider attempt.

No session is terminated due to a provider failure. The agent waits for the next input.

### Circuit breaker states during total failure

When all providers are in `:open` state simultaneously, `HealthChecker.is_available?/1`
returns `false` for all of them. The fallback chain produces an empty list after filtering.
The error path above applies.

After 30 seconds (the half-open timeout), the first provider that entered `:open` state
transitions to `:half_open`. The next LLM call to that provider is a probe. On success,
the circuit closes and the system recovers automatically.

---

## Offline Mode Capabilities

When no LLM providers are reachable, the following continues to work:

### Always available (no LLM required)

| Feature | Mechanism |
|---|---|
| Signal classification | Deterministic pattern matching in `MiosaSignal.MessageClassifier` — `classify_fast/2` and `classify_deterministic/2` never call LLMs |
| Noise filtering | `Channels.NoiseFilter` is pure pattern matching |
| Memory read | `Agent.Memory` reads from JSONL and SQLite without any LLM calls |
| Vault fact lookup | `Vault.FactStore` is pure ETS/file storage |
| Tool execution (non-LLM tools) | Shell, file, git, and web tools run independently |
| Slash commands that do not invoke the loop | `/status`, `/help`, `/agents`, `/channels`, etc. |
| HTTP API read endpoints | Provider list, session list, tool list, memory stats |
| Scheduled jobs that do not require LLM | Cron tasks with non-LLM actions |

### Degraded without LLM

| Feature | Degraded behavior |
|---|---|
| Chat responses | Error message; session stays alive |
| Orchestrated sub-agents | Sub-agent calls fail; orchestrator returns partial results |
| Signal async enrichment | Skipped; deterministic classification is used |
| Proactive monitoring | Silence/drift detection still works; coach responses require LLM |

### Not available without LLM

- Agent reasoning loop (ReAct, Chain-of-Thought, MCTS)
- Skill execution requiring LLM judgment
- Memory summarization and compaction
- Swarm task decomposition and synthesis

---

## Signal Classification Degradation

Signal Theory classification has its own two-level fallback:

1. **LLM path (primary):** `Signal.Classifier.classify/2` calls the configured provider
   via `MiosaProviders.Registry`. Returns a signal with `confidence: :high`.
2. **Deterministic path (fallback):** When LLM is disabled or unavailable,
   `MiosaSignal.MessageClassifier.classify_deterministic/2` uses pattern matching.
   Returns a signal with `confidence: :low`.

The deterministic path covers mode, genre, type, and weight using regex patterns and
keyword heuristics. It is always available and adds zero latency overhead.

Async enrichment (`classify_async/3`) is fire-and-forget via `Task.Supervisor`. If it
fails, no exception propagates — the loop continues with the synchronous deterministic
result.

---

## Sidecar Degradation

### Go tokenizer down

- Token counting falls back to the Elixir approximation (`byte_size(text) / 4`).
- No session is disrupted. Accuracy of token estimates decreases.
- The circuit breaker in `Sidecar.Manager` tracks consecutive failures and logs warnings.

### Python sidecar down

- Semantic search (embedding-based) becomes unavailable.
- Keyword search via SQLite FTS remains available.
- The `semantic_search` tool returns an error; the agent continues with other tools.

### MCP servers

MCP servers are started asynchronously after boot via `Task.start/1`. If an MCP server
fails to start, its tools are not registered in `Tools.Registry`. Existing built-in tools
are unaffected. The failed server is not retried automatically; restart requires a system
restart or manual MCP server reinitiation.
