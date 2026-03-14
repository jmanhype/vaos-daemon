# Troubleshooting LLM Providers

Provider-specific debugging for connection failures, authentication errors, rate limiting,
and model availability problems.

## Audience

Operators and developers diagnosing LLM provider connectivity issues.

---

## General Diagnosis

Before investigating a specific provider, check the overall provider state:

```elixir
# In IEx — check which providers have configured keys:
Enum.each(OptimalSystemAgent.Providers.Registry.list_providers(), fn provider ->
  configured = OptimalSystemAgent.Providers.Registry.provider_configured?(provider)
  IO.puts("#{provider}: #{if configured, do: "configured", else: "NOT CONFIGURED"}")
end)

# Test a provider directly with a minimal message:
OptimalSystemAgent.Providers.Registry.chat(
  [%{role: "user", content: "Say 'ok'"}],
  provider: :groq,
  max_tokens: 5
)
# => {:ok, %{content: "ok", tool_calls: [], usage: %{...}}}
# => {:error, "HTTP 401: ..."}
```

---

## Ollama

### Ollama Not Connecting

**Symptom:** `{:error, "Connection failed: %Req.TransportError{reason: :econnrefused}"}` or
Ollama does not appear in the provider list.

**Diagnosis:**

```bash
# Check if Ollama is running:
curl http://localhost:11434/api/version

# Check logs:
journalctl -u ollama -f        # systemd
ollama serve                   # foreground mode
```

```elixir
# From IEx:
OptimalSystemAgent.Providers.Registry.provider_configured?(:ollama)
# => false means the TCP probe to :11434 failed

# Check the configured URL:
Application.get_env(:optimal_system_agent, :ollama_url)
# => "http://localhost:11434" (default)
```

**Fixes:**
1. Start Ollama: `ollama serve`
2. If Ollama runs on a non-default port: `export OLLAMA_URL=http://localhost:11435`
3. If OSA started before Ollama: restart OSA so the boot-time probe succeeds.

### Ollama Model Not Found

**Symptom:** `{:error, "HTTP 404: ..."}` or `model 'xyz' not found`.

```bash
# List installed models:
ollama list

# Pull a model:
ollama pull llama3.2:latest
ollama pull qwen2.5:14b
```

OSA auto-selects the best available model at boot. Check which model it selected:

```elixir
Application.get_env(:optimal_system_agent, :ollama_model)
# => "llama3.2:latest"
```

Override the auto-detected model:

```bash
export OSA_OLLAMA_MODEL=qwen2.5:14b
# or
export OSA_DEFAULT_MODEL=qwen2.5:14b
```

### Ollama Not Using Tools (Bug 4 — Partial Fix)

**Symptom:** Ollama model responds with raw XML or plain text instead of executing tools.

**Root cause:** Only models matching `@tool_capable_prefixes` receive tool definitions.
The minimum model size for tool use is 7GB on disk (~14B parameters).

**Supported tool-capable prefixes:** `qwen3`, `qwen2.5`, `llama3.3`, `llama3.2`,
`llama3.1`, `llama3`, `gemma3`, `glm-5`, `glm5`, `glm-4`, `glm4`, `mistral`,
`mixtral`, `deepseek`, `command-r`, `kimi`, `minimax`.

```elixir
# Check if your model will receive tools:
model = Application.get_env(:optimal_system_agent, :ollama_model)
prefixes = ~w(qwen3 qwen2.5 llama3.3 llama3.2 llama3.1 llama3 gemma3 glm mixtral
              mistral deepseek command-r kimi minimax)
Enum.any?(prefixes, &String.starts_with?(model, &1))
```

**Fix:** Pull a supported model with sufficient size:

```bash
ollama pull qwen2.5:14b    # 9GB — recommended for tool use
ollama pull llama3.2:latest # smaller, but marked capable
```

### Ollama Context Window

OSA caches Ollama model context sizes in the `:osa_context_cache` ETS table to avoid
repeated API calls. If the cache returns a wrong value:

```elixir
# Clear the cache for a specific model:
:ets.delete(:osa_context_cache, "my_model:latest")

# Inspect the cache:
:ets.tab2list(:osa_context_cache)
```

---

## Anthropic

### API Key Issues

```bash
export ANTHROPIC_API_KEY=sk-ant-api03-...
```

```elixir
# Verify in IEx:
Application.get_env(:optimal_system_agent, :anthropic_api_key)
# => "sk-ant-api03-..." (should not be nil)
```

**Common errors:**
- `"HTTP 401: invalid x-api-key"` — Key is wrong or not set.
- `"HTTP 403: permission_error"` — Key does not have access to the requested model.
- `"HTTP 400: max_tokens: Field required"` — Anthropic requires `max_tokens` to be set
  explicitly. OSA should set this by default; check that `opts` include `:max_tokens`.

### Rate Limiting (HTTP 429)

Anthropic returns `Retry-After` in 429 responses. OSA handles this automatically with
up to 3 retries using the `with_retry/1` wrapper in `Providers.Registry`:

```
[warning] Rate limited (attempt 1/3). Retrying in 30s...
```

If rate limiting is persistent, switch to the fallback chain:

```elixir
config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq]
```

### Model Not Found

Valid Anthropic models as of March 2026:

```
claude-opus-4-6       (1M context)
claude-sonnet-4-6     (1M context)
claude-haiku-4-5      (200K context)
claude-3-5-sonnet-20241022
claude-3-5-haiku-20241022
claude-3-opus-20240229
```

Set the model:

```bash
export ANTHROPIC_MODEL=claude-sonnet-4-6
```

---

## OpenAI

### API Key Issues

```bash
export OPENAI_API_KEY=sk-proj-...
```

### Reasoning Models (o3, o4-mini)

OpenAI's o-series models require special handling. OSA detects them via `reasoning_model?/1`
and sets `reasoning_effort: "medium"` automatically. These models:
- Do not support `temperature` (ignored).
- Have longer response times (OSA sets `receive_timeout: 300_000` for them).
- Do not support streaming in the same way.

```bash
export OPENAI_MODEL=o4-mini
```

---

## Groq

### Tool Name Mismatch (Bug 5)

**Symptom:** On the second tool call, Groq returns an error about unrecognized tool names.

**Root cause:** Groq requires the `name` field in tool result messages to match the original
function name exactly. The `format_messages/1` function in `OpenAICompat` preserves the
`:name` key when formatting tool result messages to address this.

**Workaround:** If you encounter this bug, check that your tool result messages include
the `:name` field:

```elixir
%{role: "tool", content: result, tool_call_id: id, name: original_tool_name}
```

### Groq Rate Limits

Groq has aggressive rate limits on free tiers (6,000 tokens per minute). The fallback
chain handles this, but configure cloud budget accordingly:

```elixir
config :optimal_system_agent, :fallback_chain, [:groq, :deepseek, :ollama]
```

---

## DeepSeek

```bash
export DEEPSEEK_API_KEY=sk-...
```

DeepSeek uses `deepseek-chat` (standard) and `deepseek-reasoner` (chain-of-thought).
The reasoner model returns `reasoning_content` in deltas — OSA captures this as
`:thinking_delta` in the streaming callback.

---

## Google (Gemini)

```bash
export GOOGLE_API_KEY=AIzaSy...
```

Google uses a native API (not OpenAI-compatible). The `Providers.Google` module handles
the `generateContent` endpoint format. Models:

```
gemini-2.5-pro     (1M context)
gemini-2.5-flash   (1M context)
gemini-2.0-flash   (1M context)
```

---

## OpenRouter

OpenRouter is a meta-provider that routes to hundreds of models. It uses the OpenAI
wire format.

```bash
export OPENROUTER_API_KEY=sk-or-...
```

OpenRouter requires `HTTP-Referer` and `X-Title` headers, which OSA includes via
`extra_headers` in the `@provider_configs` map.

Common model strings for OpenRouter:

```
meta-llama/llama-3.3-70b-instruct
anthropic/claude-sonnet-4-6
google/gemini-2.5-pro
```

Set the model:

```bash
export OPENROUTER_MODEL=anthropic/claude-sonnet-4-6
```

---

## Chinese Providers (Qwen, Moonshot, Zhipu, Volcengine, Baichuan)

All Chinese providers are OpenAI-compatible. Set the corresponding environment variable:

| Provider | Env Variable | Default Model |
|----------|-------------|---------------|
| Qwen (Alibaba Cloud) | `QWEN_API_KEY` | `qwen-max` |
| Moonshot | `MOONSHOT_API_KEY` | `moonshot-v1-128k` |
| Zhipu (GLM) | `ZHIPU_API_KEY` | `glm-4-plus` |
| Volcengine | `VOLCENGINE_API_KEY` | `doubao-pro-128k` |
| Baichuan | `BAICHUAN_API_KEY` | `Baichuan4` |

---

## Diagnosing Provider Health

OSA uses `MiosaLLM.HealthChecker` as a circuit breaker. When a provider fails repeatedly,
the circuit opens and it is skipped in the fallback chain.

```elixir
# Check if a provider is currently marked as available:
MiosaLLM.HealthChecker.is_available?(:anthropic)
# => true or false

# Record a success manually (resets failure count):
MiosaLLM.HealthChecker.record_success(:anthropic)

# Record a failure:
MiosaLLM.HealthChecker.record_failure(:anthropic, "timeout")
```

If a provider is stuck in the failed state after the underlying issue is resolved:

```elixir
MiosaLLM.HealthChecker.record_success(:anthropic)
```
