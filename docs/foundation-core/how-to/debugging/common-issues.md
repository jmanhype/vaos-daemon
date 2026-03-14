# Known Issues and Workarounds

Catalog of confirmed bugs with current workarounds. Severity levels: CRITICAL (blocks
normal use), HIGH (significantly impairs a feature), MEDIUM (impairs a secondary feature
or has a known workaround).

---

## CRITICAL Issues

### Bug 4: Tools Never Execute — Raw XML Instead of Tool Calls

**Symptom:** The LLM responds with raw XML like
`<function name="file_read" parameters={...}></function>` in the message content
instead of the system executing the tool.

**Root cause:** Some models (particularly smaller Ollama models) do not use the native
`tool_calls` field in their response. They embed tool calls as XML text in the content.
The XML parser in `OpenAICompat` handles `<function>` and `<function_call>` formats, but
certain model outputs use non-standard variants.

**Workaround:**
1. Switch to a tool-capable model. OSA only sends tools to models matching
   `@tool_capable_prefixes` in `Providers.Ollama`. Supported prefixes include:
   `qwen3`, `qwen2.5`, `llama3.3`, `llama3.2`, `llama3.1`, `gemma3`, `mixtral`,
   `deepseek`, `command-r`, `kimi`.
2. Use a cloud provider (Anthropic, OpenAI, Groq) which consistently uses the native
   `tool_calls` field.
3. Minimum model size for tool use in Ollama is 7GB on disk (~14B parameters).

**Check current model:**
```elixir
Application.get_env(:optimal_system_agent, :ollama_model)
```

---

### Bug 17: System Prompt Leaks on Direct Request (SECURITY)

**Symptom:** If a user constructs a message that asks the agent to reveal its system
prompt or instructions, the LLM may comply and return the full system prompt content.

**Root cause:** There is no post-response hook that scans outgoing messages for system
prompt content before delivery to the channel.

**Workaround:** Add a `post_response` hook that scans outbound messages:

```elixir
OptimalSystemAgent.Agent.Hooks.register(:post_response, "system_prompt_guard", fn payload ->
  system_keywords = ["You are OSA", "Soul:", "## Identity"]
  content = Map.get(payload, :content, "")

  if Enum.any?(system_keywords, &String.contains?(content, &1)) do
    # Redact the response
    {:ok, %{payload | content: "I cannot share my internal instructions."}}
  else
    {:ok, payload}
  end
end, priority: 1)
```

---

### Bug 9: LLM Picks Wrong Tools or Hallucinates Actions

**Symptom:** The LLM calls a tool that does not match the user's request, or invents
arguments that do not exist in the tool schema.

**Root cause:** Tool descriptions are too similar or too vague. LLMs choose tools by
comparing the user message against tool descriptions. When descriptions overlap heavily,
the model picks arbitrarily.

**Workaround:**
1. Make tool descriptions more distinct. The description is the only signal the LLM uses.
2. Reduce the tool list. Use `Tools.Registry.filter_applicable_tools/1` with context:
   ```elixir
   OptimalSystemAgent.Tools.Registry.filter_applicable_tools(%{
     language: "python",
     history: ["file_read", "file_grep"]
   })
   ```
3. Use a higher-capability model (Claude 3.5 Sonnet or GPT-4o perform significantly
   better at tool selection than smaller models).

---

## HIGH Issues

### Bug 5: Tool Name Mismatch on Iteration 2

**Symptom:** On the second tool call in a conversation, the provider returns an error like
`"tool_call_id refers to an unknown tool"` or the tool name appears with parameters appended
(e.g., `"file_read({\"path\": ...}"` instead of `"file_read"`).

**Root cause:** Some providers (notably Groq) require the `name` field in tool result
messages to exactly match the original tool call name. The normalize_tool_name function
strips extra characters, but some edge cases remain.

**Workaround:** Use Anthropic or OpenAI as the provider for multi-step tool chains. The
Groq-specific `tool_call_id` issue (Bug 3) is marked FIXED but the name normalization
(Bug 5) may still appear with unusual model outputs.

---

### Bug 6: Noise Filter Not Working

**Symptom:** Short, trivial messages like "ok", "thanks", "yes" trigger a full LLM call
rather than being filtered out. This wastes tokens and budget.

**Root cause:** The `Channels.NoiseFilter` module exists but may not be enabled for all
channels. The CLI channel calls it, but some configurations bypass it.

**Workaround:** Call the filter explicitly before routing to the loop:

```elixir
alias OptimalSystemAgent.Channels.NoiseFilter
case NoiseFilter.classify(user_message) do
  :noise -> send_quick_ack(channel, session_id)
  :signal -> Loop.process_message(session_id, user_message)
end
```

---

### Bug 11: POST /api/v1/orchestrator/complex Returns 404

**Symptom:** Calling the complex orchestration endpoint returns 404 Not Found.

**Root cause:** The route is listed in the `HTTP` module's `@moduledoc` but was not
registered in the Plug router. The actual route pattern does not match.

**Workaround:** Use `POST /api/v1/orchestrate` (without `/complex`) for standard
orchestration. Multi-agent orchestration via the HTTP API is not available in the current
build.

---

### Bug 12: GET /api/v1/swarm/status/:id Returns 404

**Symptom:** Polling for swarm status after `POST /api/v1/swarm/launch` returns 404.

**Root cause:** The status endpoint was not implemented when swarm launch was added.

**Workaround:** Subscribe to the SSE stream at `GET /api/v1/stream/:session_id` to observe
swarm events in real time instead of polling.

---

## MEDIUM Issues

### Bug 7: Ollama Always in Fallback Chain Even When Not Installed

**Symptom:** Log spam of `:econnrefused` or `connection refused` errors on every LLM
call when Ollama is not installed.

**Root cause:** Previously, Ollama was included in the fallback chain unconditionally.
A boot-time probe was added to `Providers.Registry.init/1` to detect this, but the
detection can fail if Ollama is installed but not started.

**Current behavior:** The boot-time probe runs `GET /api/version` on `http://localhost:11434`.
If it fails, `:osa_ollama_excluded` is set in the process dictionary and Ollama is skipped.

**Workaround:** Explicitly configure the fallback chain without Ollama:

```elixir
# In config/runtime.exs:
config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq]
```

---

### Bug 8: /analytics Command Has No Handler

**Symptom:** Typing `/analytics` in the CLI or sending it via HTTP produces no output
or an error about an unregistered command.

**Workaround:** None currently. The command is listed in documentation but not implemented.
Use `GET /health` for basic system metrics, or inspect `Agent.Hooks.metrics/0` directly.

---

### Bug 10: Negative uptime_seconds in /health

**Symptom:** The `uptime_seconds` field in the `GET /health` response shows a negative
number shortly after startup.

**Root cause:** The start time is stored in seconds via `System.system_time(:second)` in
`Application.start/2`. If the system clock is adjusted or the value is read before the ETS
table is populated, the subtraction produces a negative result.

**Workaround:** The value corrects itself within a second of startup. If you see it
persistently negative, check that `Application.put_env(:optimal_system_agent, :start_time, ...)`
runs successfully at boot.

---

### Bug 15: Invalid Swarm Patterns Silently Fall Back to Pipeline

**Symptom:** Passing an invalid swarm pattern name (e.g., `"typo_pattern"`) does not
return an error. The swarm runs as a pipeline instead.

**Workaround:** Validate the pattern name before calling `swarm/launch`. Valid patterns
are defined in `~/.claude/swarms/patterns.json`. Check the response payload for a
`pattern_used` field to confirm which pattern was actually applied.

---

### Bug 16: Unicode Mangled in DB Storage

**Symptom:** Japanese text, emoji, and other non-ASCII characters stored via memory tools
are retrieved as `????` or corrupted bytes.

**Root cause:** The SQLite/Mnesia encoding configuration does not enforce UTF-8 for all
binary columns.

**Workaround:** Avoid storing non-ASCII text in memory tools until this is resolved. For
Mnesia, ensure the Erlang node is started with `ELIXIR_ERL_OPTIONS="+pc unicode"`.

---

### Bug 18: Missing Slash Command Handlers

**Symptom:** The commands `/budget`, `/thinking`, `/export`, `/machines`, and `/providers`
are recognized (no "unknown command" error) but produce no output.

**Root cause:** The commands are registered in the `Commands` module but their handler
functions are not implemented.

**Workaround:**
- `/budget` — call `MiosaBudget.Budget.summary/0` directly in IEx.
- `/machines` — call `OptimalSystemAgent.Machines.list/0` directly.
- `/providers` — call `OptimalSystemAgent.Providers.Registry.list_providers/0` directly.

---

## User-Reported Issues (Current Session)

### No API Key Detection Feedback

**Symptom:** When an API key is missing, the agent fails silently or returns a generic
error. The user does not know which key is needed.

**Workaround:** Check provider configuration status explicitly:
```elixir
OptimalSystemAgent.Providers.Registry.provider_configured?(:anthropic)
# => false means the key is missing
```
Set the key: `export ANTHROPIC_API_KEY=sk-ant-...`

### Retry/Star Button Not Working in Desktop App

**Symptom:** The retry and star action buttons in the Command Center do not trigger any action.

**Workaround:** Use the CLI (`mix osa.chat`) or the HTTP API directly until the desktop
app action handlers are repaired.

### Ollama Not Showing as Selectable Option

**Symptom:** The provider selector in the desktop app does not list Ollama even when it
is running.

**Root cause:** The boot-time probe in `Providers.Registry` excluded Ollama because the
probe ran before the Ollama service was ready.

**Workaround:** Restart OSA after Ollama is fully started, or force-configure Ollama:
```
OSA_DEFAULT_PROVIDER=ollama mix osa.chat
```
