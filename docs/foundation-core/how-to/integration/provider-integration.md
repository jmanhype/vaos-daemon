# Provider Integration Reference

How to configure and use each of the 18 LLM providers supported by Daemon. Covers required
environment variables, model names, and capability differences.

## Audience

Operators setting up Daemon for the first time or adding new providers to a running instance.

---

## Provider Overview

Daemon supports 18 providers across three implementation categories:

| Category | Providers |
|----------|-----------|
| Local | `ollama` |
| OpenAI-compatible (shared wire format) | `openai`, `groq`, `together`, `fireworks`, `deepseek`, `perplexity`, `mistral`, `openrouter`, `qwen`, `moonshot`, `zhipu`, `volcengine`, `baichuan` |
| Native API (custom protocol) | `anthropic`, `google`, `cohere`, `replicate` |

All providers expose the same public interface: `Providers.Registry.chat/2` and
`Providers.Registry.chat_stream/3`.

---

## Configuring the Default Provider

```bash
# Environment variable (runtime):
export DAEMON_DEFAULT_PROVIDER=anthropic

# Or in config/runtime.exs (compile-time):
config :daemon, :default_provider, :anthropic
```

To configure a fallback chain (tried in order when the primary fails):

```elixir
config :daemon, :fallback_chain, [:anthropic, :openai, :groq, :ollama]
```

---

## Ollama (Local)

No API key required. Requires Ollama running locally.

```bash
# Install Ollama:
curl -fsSL https://ollama.ai/install.sh | sh

# Start Ollama:
ollama serve

# Pull a recommended model (tool-capable):
ollama pull qwen2.5:14b      # Best local tool use
ollama pull llama3.2:latest  # Smaller, faster
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_URL` | `http://localhost:11434` | Base URL for Ollama API |
| `DAEMON_OLLAMA_MODEL` or `DAEMON_DEFAULT_MODEL` | Auto-detected | Force a specific model |

**Auto-detection:** Daemon probes Ollama at boot and selects the best available model.
Selection criteria: prefers larger models from tool-capable prefixes
(`qwen2.5`, `llama3.3`, `llama3.2`, `gemma3`, `mixtral`, `deepseek`, etc.).
Models smaller than 7GB are deprioritized for tool use.

**Capabilities:**
- Streaming: yes
- Tool calling: yes, for supported models ≥7GB
- Context windows: auto-detected from `/api/show` and cached in ETS

---

## Anthropic (Claude)

```bash
export ANTHROPIC_API_KEY=sk-ant-api03-...
export ANTHROPIC_MODEL=claude-sonnet-4-6   # optional
```

**Available models:**

| Model | Context | Best for |
|-------|---------|---------|
| `claude-opus-4-6` | 1M tokens | Complex reasoning, long documents |
| `claude-sonnet-4-6` | 1M tokens | Balanced — recommended default |
| `claude-haiku-4-5` | 200K tokens | Fast, low cost |
| `claude-3-5-sonnet-20241022` | 200K tokens | Previous generation |
| `claude-3-5-haiku-20241022` | 200K tokens | Previous generation, fast |
| `claude-3-opus-20240229` | 200K tokens | Previous generation |

**Capabilities:**
- Streaming: yes (native SSE)
- Tool calling: yes (native function calling)
- Vision: yes (image input in messages)

**Notes:** Anthropic requires `max_tokens` to be set explicitly. Daemon handles this
automatically. The `Providers.Anthropic` module uses Anthropic's native API format,
not OpenAI-compatible.

---

## OpenAI

```bash
export OPENAI_API_KEY=sk-proj-...
export OPENAI_MODEL=gpt-4o   # optional
```

**Available models:**

| Model | Context | Notes |
|-------|---------|-------|
| `gpt-4o` | 128K | Standard default |
| `gpt-4o-mini` | 128K | Lower cost |
| `gpt-4.1` | 1M | Latest GPT-4 |
| `gpt-4.1-mini` | 1M | Latest mini |
| `gpt-4.1-nano` | 1M | Smallest and fastest |
| `o3` | 200K | Chain-of-thought reasoning |
| `o3-mini` | 200K | Fast reasoning |
| `o4-mini` | 200K | Latest reasoning |

**Reasoning models (o3, o4-mini):** Daemon detects these automatically and sets
`reasoning_effort: "medium"`. Temperature is ignored. Response time is longer.

---

## Groq

```bash
export GROQ_API_KEY=gsk_...
export GROQ_MODEL=llama-3.3-70b-versatile   # optional
```

**Available models:**

| Model | Context | Notes |
|-------|---------|-------|
| `llama-3.3-70b-versatile` | 128K | Default, good tool use |
| `llama-3.1-8b-instant` | 131K | Very fast, lower quality |
| `mixtral-8x7b-32768` | 32K | MoE model |

**Notes:** Groq has aggressive rate limits on free tiers. Known issue: tool name mismatch
on second iteration (Bug 5). Recommended for speed, not for multi-step tool chains.

---

## DeepSeek

```bash
export DEEPSEEK_API_KEY=sk-...
export DEEPSEEK_MODEL=deepseek-chat   # optional
```

**Available models:**

| Model | Context | Notes |
|-------|---------|-------|
| `deepseek-chat` | 128K | Standard chat, good for code |
| `deepseek-reasoner` | 128K | Chain-of-thought (slow but thorough) |

**Notes:** `deepseek-reasoner` is detected as a reasoning model by `reasoning_model?/1`.
Streaming returns `reasoning_content` deltas that Daemon captures as `:thinking_delta`.

---

## Together AI

```bash
export TOGETHER_API_KEY=...
export TOGETHER_MODEL=meta-llama/Llama-3.3-70B-Instruct-Turbo   # optional
```

Together hosts many open models via the OpenAI-compatible endpoint at
`https://api.together.xyz/v1`.

---

## Fireworks AI

```bash
export FIREWORKS_API_KEY=fw-...
export FIREWORKS_MODEL=accounts/fireworks/models/llama-v3p3-70b-instruct
```

---

## Perplexity

```bash
export PERPLEXITY_API_KEY=pplx-...
export PERPLEXITY_MODEL=sonar-pro   # optional
```

Perplexity models include web search augmentation. The `sonar-pro` model is the default.

---

## Mistral

```bash
export MISTRAL_API_KEY=...
export MISTRAL_MODEL=mistral-large-latest   # optional
```

**Available models:**

| Model | Context |
|-------|---------|
| `mistral-large-latest` | 128K |
| `mistral-small-latest` | 128K |

---

## OpenRouter

```bash
export OPENROUTER_API_KEY=sk-or-...
export OPENROUTER_MODEL=meta-llama/llama-3.3-70b-instruct   # optional
```

OpenRouter routes to hundreds of models. Daemon adds the required `HTTP-Referer` and
`X-Title` headers automatically. Any model string from `openrouter.ai/models` works.

Popular choices:

```
anthropic/claude-sonnet-4-6
google/gemini-2.5-pro
meta-llama/llama-3.3-70b-instruct
mistralai/mistral-large
```

---

## Google (Gemini)

```bash
export GOOGLE_API_KEY=AIzaSy...
export GOOGLE_MODEL=gemini-2.5-flash   # optional
```

**Available models:**

| Model | Context |
|-------|---------|
| `gemini-2.5-pro` | 1M |
| `gemini-2.5-flash` | 1M |
| `gemini-2.0-flash` | 1M |

**Notes:** Uses Google's native `generateContent` API, not OpenAI-compatible.
The `Providers.Google` module handles the format difference.

---

## Cohere

```bash
export COHERE_API_KEY=...
export COHERE_MODEL=command-r-plus   # optional
```

**Available models:**

| Model | Context |
|-------|---------|
| `command-r-plus` | 128K |
| `command-r` | 128K |

---

## Replicate

```bash
export REPLICATE_API_KEY=r8_...
```

Replicate uses a custom API (predictions endpoint). The `Providers.Replicate` module
handles the polling model for async responses.

---

## Chinese Providers

All use the OpenAI-compatible wire format with localized base URLs.

### Qwen (Alibaba Cloud DashScope)

```bash
export QWEN_API_KEY=sk-...
export QWEN_MODEL=qwen-max   # optional
```

Base URL: `https://dashscope.aliyuncs.com/compatible-mode/v1`

### Moonshot (Kimi)

```bash
export MOONSHOT_API_KEY=sk-...
export MOONSHOT_MODEL=moonshot-v1-128k   # optional
```

Base URL: `https://api.moonshot.cn/v1`

### Zhipu AI (GLM)

```bash
export ZHIPU_API_KEY=...
export ZHIPU_MODEL=glm-4-plus   # optional
```

Base URL: `https://open.bigmodel.cn/api/paas/v4`

### Volcengine (Doubao)

```bash
export VOLCENGINE_API_KEY=...
export VOLCENGINE_MODEL=doubao-pro-128k   # optional
```

Base URL: `https://ark.cn-beijing.volces.com/api/v3`

### Baichuan

```bash
export BAICHUAN_API_KEY=...
export BAICHUAN_MODEL=Baichuan4   # optional
```

Base URL: `https://api.baichuan-ai.com/v1`

---

## Runtime Provider Inspection

```elixir
# List all providers and their configuration status:
Daemon.Providers.Registry.list_providers()
|> Enum.map(fn p ->
  {:ok, info} = Daemon.Providers.Registry.provider_info(p)
  {p, info.configured?, info.default_model}
end)

# Override the provider for a specific session (hot-swap without restart):
:ets.insert(:daemon_session_provider_overrides, {session_id, :groq, "llama-3.3-70b-versatile"})
```
