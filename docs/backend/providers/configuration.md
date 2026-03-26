# Provider Configuration

This document covers how to configure each LLM provider: where API keys go, which environment variables are read, and what application config options are available.

---

## Quick Start

Set API keys in `~/.daemon/.env`. Daemon loads this file at startup.

```bash
# ~/.daemon/.env

# Pick one (or more for fallback)
ANTHROPIC_API_KEY="sk-ant-api03-..."
OPENAI_API_KEY="sk-..."
GROQ_API_KEY="gsk_..."
OPENROUTER_API_KEY="sk-or-..."

# Optional: force a specific provider
DAEMON_DEFAULT_PROVIDER="anthropic"
```

Restart Daemon after editing `.env`.

---

## Auto-Detection Order

If `DAEMON_DEFAULT_PROVIDER` is not set, the registry picks the first provider whose key is present:

```
ANTHROPIC_API_KEY → anthropic
OPENAI_API_KEY    → openai
GROQ_API_KEY      → groq
OPENROUTER_API_KEY→ openrouter
(none)            → ollama (no key required)
```

---

## Per-Provider Configuration

### Anthropic (Claude)

```bash
ANTHROPIC_API_KEY="sk-ant-api03-..."
```

```elixir
# config/config.exs
config :daemon, :anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model:   "claude-sonnet-4-6",           # default model
  url:     "https://api.anthropic.com"
```

Available models:

| Model | Tier | Context |
|-------|------|---------|
| `claude-opus-4-6` | elite | 200K |
| `claude-sonnet-4-6` | specialist | 200K |
| `claude-haiku-4-5` | utility | 200K |

Runtime switch: `/model anthropic claude-opus-4-6`

---

### OpenAI

```bash
OPENAI_API_KEY="sk-..."

# Optional — for Azure OpenAI
OPENAI_BASE_URL="https://<resource>.openai.azure.com"
OPENAI_API_VERSION="2024-02-01"
```

```elixir
config :daemon, :openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  model:   "gpt-4o",
  url:     System.get_env("OPENAI_BASE_URL", "https://api.openai.com")
```

Available models (Daemon-tested): `gpt-4o`, `gpt-4o-mini`, `o1`, `o1-mini`

---

### Google (Gemini)

```bash
GOOGLE_API_KEY="AIza..."
```

```elixir
config :daemon, :google,
  api_key: System.get_env("GOOGLE_API_KEY"),
  model:   "gemini-2.5-pro"
```

---

### Groq (LPU Inference)

```bash
GROQ_API_KEY="gsk_..."
```

```elixir
config :daemon, :groq,
  api_key: System.get_env("GROQ_API_KEY"),
  model:   "llama-3.3-70b-versatile"
```

---

### Fireworks

```bash
FIREWORKS_API_KEY="..."
```

```elixir
config :daemon, :fireworks,
  api_key: System.get_env("FIREWORKS_API_KEY"),
  model:   "accounts/fireworks/models/llama-v3p3-70b-instruct"
```

---

### Together AI

```bash
TOGETHER_API_KEY="..."
```

```elixir
config :daemon, :together,
  api_key: System.get_env("TOGETHER_API_KEY"),
  model:   "meta-llama/Llama-3.3-70B-Instruct-Turbo"
```

---

### DeepSeek

```bash
DEEPSEEK_API_KEY="..."
```

```elixir
config :daemon, :deepseek,
  api_key: System.get_env("DEEPSEEK_API_KEY"),
  model:   "deepseek-chat"
```

---

### OpenRouter

OpenRouter provides access to 100+ models through a single API key.

```bash
OPENROUTER_API_KEY="sk-or-..."
```

```elixir
config :daemon, :openrouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model:   "meta-llama/llama-3.3-70b-instruct"
```

To use a specific model through OpenRouter: `/model openrouter anthropic/claude-opus-4-6`

---

### Perplexity

```bash
PERPLEXITY_API_KEY="pplx-..."
```

```elixir
config :daemon, :perplexity,
  api_key: System.get_env("PERPLEXITY_API_KEY"),
  model:   "llama-3.1-sonar-large-128k-online"
```

Perplexity models include live web search. Best used for queries requiring up-to-date information.

---

### Ollama (Local)

No API key required. Ollama must be running on the machine.

```bash
# Optional overrides
OLLAMA_URL="http://localhost:11434"   # default
OLLAMA_MODEL="llama3.2:latest"       # default: auto-detected
```

```elixir
config :daemon, :ollama,
  url:   System.get_env("OLLAMA_URL", "http://localhost:11434"),
  model: System.get_env("OLLAMA_MODEL")   # nil = auto-detect
```

**Auto-detection:** On startup, Daemon queries `ollama list` and picks the largest tool-capable model. Tool-capable = size ≥ 7 GB AND name matches a known prefix (`llama3`, `qwen2`, `mistral`, `codellama`, `deepseek`, `phi`).

To download a model: `ollama pull llama3.3:70b`

---

### Mistral

```bash
MISTRAL_API_KEY="..."
```

```elixir
config :daemon, :mistral,
  api_key: System.get_env("MISTRAL_API_KEY"),
  model:   "mistral-large-latest"
```

---

### Cohere

```bash
COHERE_API_KEY="..."
```

```elixir
config :daemon, :cohere,
  api_key: System.get_env("COHERE_API_KEY"),
  model:   "command-r-plus"
```

---

### Replicate

```bash
REPLICATE_API_KEY="r8_..."
```

```elixir
config :daemon, :replicate,
  api_key: System.get_env("REPLICATE_API_KEY"),
  model:   "meta/llama-3-70b-instruct"
```

---

### Chinese Regional Providers

All five providers share the same OpenAI-compatible API interface. Configuration follows the same pattern:

```bash
QWEN_API_KEY="..."        # Alibaba Qwen
ZHIPU_API_KEY="..."       # ChatGLM
MOONSHOT_API_KEY="..."    # Kimi
VOLC_API_KEY="..."        # Doubao (VolcEngine)
BAICHUAN_API_KEY="..."    # Baichuan
```

```elixir
config :daemon, :qwen,
  api_key: System.get_env("QWEN_API_KEY"),
  url:     "https://dashscope.aliyuncs.com/compatible-mode/v1",
  model:   "qwen-max"

config :daemon, :zhipu,
  api_key: System.get_env("ZHIPU_API_KEY"),
  url:     "https://open.bigmodel.cn/api/paas/v4",
  model:   "glm-4"

config :daemon, :moonshot,
  api_key: System.get_env("MOONSHOT_API_KEY"),
  url:     "https://api.moonshot.cn/v1",
  model:   "moonshot-v1-128k"

config :daemon, :volcengine,
  api_key: System.get_env("VOLC_API_KEY"),
  url:     "https://ark.cn-beijing.volces.com/api/v3",
  model:   "ep-..."   # Endpoint ID from VolcEngine console

config :daemon, :baichuan,
  api_key: System.get_env("BAICHUAN_API_KEY"),
  url:     "https://api.baichuan-ai.com/v1",
  model:   "Baichuan4"
```

See [chinese.md](chinese.md) for VolcEngine endpoint ID setup, which requires creating a deployment in the console before use.

---

## Global Options

These options apply across all providers:

```bash
# Force a specific provider (overrides auto-detection)
DAEMON_DEFAULT_PROVIDER="anthropic"

# HTTP request timeout in milliseconds (default: 120_000)
DAEMON_PROVIDER_TIMEOUT_MS="120000"
```

```elixir
# config/config.exs — global provider settings
config :daemon,
  default_provider:   System.get_env("DAEMON_DEFAULT_PROVIDER"),
  provider_timeout:   String.to_integer(System.get_env("DAEMON_PROVIDER_TIMEOUT_MS", "120000"))
```

---

## Runtime Model Switching

Changes take effect immediately — no restart:

```
/model                             # Show active provider + model
/model anthropic                   # Switch provider, keep default model
/model anthropic claude-opus-4-6   # Switch provider + specific model
/models                            # List all configured providers
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Provider not found` | Key not in environment | Check `~/.daemon/.env`, restart Daemon |
| `401 Unauthorized` | Invalid or expired key | Regenerate key from provider console |
| `Circuit open` | Provider had repeated failures | Wait 30s for automatic probe, or restart |
| `No tool-capable Ollama model` | All local models too small | `ollama pull llama3.3:70b` |
| `Model not found` | Model name typo or not available | Run `/models` to see available models |
| Slow responses with Ollama | Model too large for hardware | Use a quantized variant (Q4_K_M) |

---

## See Also

- [Provider Overview](overview.md) — architecture, tier system, circuit breaker
- [Individual provider guides](README.md) — per-provider notes and model lists
- [Getting Started — Configuration](../../getting-started/configuration.md) — initial setup walkthrough
