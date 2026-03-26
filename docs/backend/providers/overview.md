# Provider System Overview

Daemon routes all LLM calls through `MiosaProviders` — a standalone package that abstracts 18 providers behind a single interface. The agent loop, recipe engine, and orchestrator never call a provider directly; they call `MiosaProviders.Registry.chat/2` and the registry selects, validates, and calls the right provider.

---

## Architecture

```
Agent Loop / Orchestrator / Recipe Engine
          ↓
MiosaProviders.Registry.chat(messages, opts)
          ↓
    Provider Selection (auto-detect or explicit)
          ↓
┌─────────────────────────────────────────────────┐
│                 miosa_llm layer                 │
│  Circuit Breaker → Rate Limiter → Health Check  │
└─────────────────────────────────────────────────┘
          ↓
    Provider HTTP Client (provider-specific)
          ↓
    LLM API (Anthropic / OpenAI / Ollama / ...)
```

`miosa_llm` provides three infrastructure primitives used by every provider:
- **Circuit breaker** — opens after repeated failures, preventing cascading errors
- **Rate limiter** — enforces per-provider token and request limits
- **Health checker** — polls provider endpoints to detect degraded status before routing

---

## The 18 Providers

### Frontier

| Provider | Package Atom | Default Model | Priority |
|----------|-------------|---------------|----------|
| Anthropic (Claude) | `:anthropic` | `claude-sonnet-4-6` | 1st (if key present) |
| OpenAI | `:openai` | `gpt-4o` | 2nd |
| Google (Gemini) | `:google` | `gemini-2.5-pro` | — |

### Fast Inference

| Provider | Package Atom | Default Model |
|----------|-------------|---------------|
| Groq (LPU) | `:groq` | `llama-3.3-70b-versatile` |
| Fireworks | `:fireworks` | `llama-v3p3-70b` |
| Together AI | `:together` | `Llama-3.3-70B` |
| DeepSeek | `:deepseek` | `deepseek-chat` |

### Aggregators

| Provider | Package Atom | Note |
|----------|-------------|------|
| OpenRouter | `:openrouter` | Routes to 100+ models |
| Perplexity | `:perplexity` | Web-augmented search |

### Local

| Provider | Package Atom | Note |
|----------|-------------|------|
| Ollama | `:ollama` | Final fallback, no API key |

### Specialty

| Provider | Package Atom |
|----------|-------------|
| Mistral | `:mistral` |
| Cohere | `:cohere` |
| Replicate | `:replicate` |

### Chinese Regional

| Provider | Package Atom | Env Var |
|----------|-------------|---------|
| Qwen (Alibaba) | `:qwen` | `QWEN_API_KEY` |
| Zhipu (ChatGLM) | `:zhipu` | `ZHIPU_API_KEY` |
| Moonshot (Kimi) | `:moonshot` | `MOONSHOT_API_KEY` |
| VolcEngine (Doubao) | `:volcengine` | `VOLC_API_KEY` |
| Baichuan | `:baichuan` | `BAICHUAN_API_KEY` |

---

## Tier System

The tier system maps capability levels to model classes. Daemon uses tiers internally to select the right model for the task — the orchestrator uses `:elite` for planning, specialists use `:specialist`, and utility tasks like classification use `:utility`.

| Tier | Purpose | Claude equivalent |
|------|---------|-------------------|
| `:elite` | Complex orchestration, architecture, long-horizon reasoning | Opus |
| `:specialist` | Implementation, analysis, coding | Sonnet (default) |
| `:utility` | Classification, filtering, simple extraction | Haiku |

Providers map their models to tiers internally. When you call `Registry.chat/2` with `tier: :specialist`, the registry resolves to the appropriate model for the active provider.

---

## Auto-Detection Priority

On startup, the registry inspects environment variables and selects the provider in this order:

```
1. DAEMON_DEFAULT_PROVIDER=<name>   Explicit override — used as-is
2. ANTHROPIC_API_KEY present     → :anthropic
3. OPENAI_API_KEY present        → :openai
4. GROQ_API_KEY present          → :groq
5. OPENROUTER_API_KEY present    → :openrouter
6. (fallback)                    → :ollama
```

---

## Registry API

```elixir
# Standard chat call (used by agent loop, recipes, orchestrator)
{:ok, response} = MiosaProviders.Registry.chat(messages, opts)

# Response shape
%{
  content:    "The refactored auth module uses...",
  tool_calls: [],                          # list of tool call structs if any
  usage:      %{input: 847, output: 312},  # token counts
  model:      "claude-sonnet-4-6",
  provider:   :anthropic
}

# Opts
[
  tools:       [%{name: "file_read", ...}],   # tool definitions to include
  temperature: 0.3,
  max_tokens:  4000,
  tier:        :specialist,                   # :elite | :specialist | :utility
  provider:    :anthropic                     # explicit override
]
```

---

## Runtime Switching

```
/model                             # Show active provider and model
/model anthropic                   # Switch to Anthropic default model
/model anthropic claude-opus-4-6   # Switch to specific model
/models                            # List all configured providers and models
```

Switching takes effect for the next request. The registry updates in-memory state only — no restart required.

---

## Ollama Tool Gating

Ollama is the only provider with a tool gating rule. Daemon withholds tool definitions from Ollama models unless the model meets both criteria:

1. Model size is 7 GB or larger
2. Model name matches a known tool-capable prefix (`llama3`, `qwen2`, `mistral`, etc.)

Models that fail either check receive no tools. This prevents small models from hallucinating tool calls that would fail or produce garbage results. A model below the threshold operates in chat-only mode.

---

## Circuit Breaker Behavior

Each provider has an independent circuit breaker managed by `miosa_llm`. States:

| State | Behavior |
|-------|----------|
| Closed | Normal operation |
| Open | All requests fail immediately; health check runs in background |
| Half-open | One probe request allowed; success closes the circuit, failure reopens |

A provider's circuit opens after 5 consecutive errors. It re-probes after 30 seconds.

---

## See Also

- [Provider Configuration](configuration.md) — API key setup and per-provider options
- [Individual Provider Guides](README.md) — provider-specific notes
- [Budget](../../features/proactive-mode.md) — `MiosaBudget` enforces spend limits per provider call
