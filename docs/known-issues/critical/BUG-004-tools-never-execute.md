# BUG-004: Tools Never Execute on Models Not in tool_capable_prefixes

> **Severity:** CRITICAL
> **Status:** Partial Fix
> **Component:** `lib/optimal_system_agent/providers/ollama.ex`
> **Reported:** 2026-03-14

---

## Summary

When a user runs an Ollama model whose name does not start with one of the
prefixes in `@tool_capable_prefixes`, the provider silently strips the tool list
before sending the request. The LLM never sees the tools, so it cannot call them.
Instead it narrates intent ("Let me check that file…") and the agent loop
interprets the text as a final answer, never executing any tool.

## Symptom

The agent responds to every task with a prose description of what it _would_ do,
but no tool executions appear in the TUI or logs. Tools tab shows tools
registered; the model is running fine. Only affects Ollama with models outside
the known-good prefix list (e.g. custom fine-tunes, `falcon`, `phi3`, older
`orca` builds, or any model pulled with an unusual tag).

## Root Cause

`maybe_add_tools/3` in `ollama.ex` line 315 gates tool injection on
`model_supports_tools?/1` (line 266). That function checks
`@tool_capable_prefixes` at line 25:

```elixir
@tool_capable_prefixes ~w(qwen3 qwen2.5 llama3.3 llama3.2 llama3.1 llama3
                          gemma3 glm-5 glm5 glm-4 glm4 glm4.7 mistral mixtral
                          deepseek command-r kimi kimi-k2 minimax)
```

Any model name whose lowercase form does not start with one of these strings
evaluates `model_supports_tools?/1` as `false`, and tools are dropped silently
at line 327:

```elixir
Logger.debug("[Ollama] Skipping tools for #{model} (too small / not tool-capable)")
body
```

The log is at `:debug` level so it is invisible in normal operation.

## Impact

- All agentic workflows silently degrade to chat-only on unrecognised models.
- No error is surfaced to the user. The agent appears to work but never acts.
- Users who pull custom or community models cannot use tools without modifying
  source code.

## Suggested Fix

Raise the log level to `:warning` so degradation is visible. Provide a config
escape hatch for opt-in on unknown models:

```elixir
defp maybe_add_tools(body, model, opts) do
  case Keyword.get(opts, :tools) do
    tools when tools in [nil, []] -> body
    tools ->
      force = Application.get_env(:optimal_system_agent, :ollama_force_tools, false)
      if force or model_supports_tools?(model) do
        Map.put(body, :tools, format_tools(tools))
      else
        Logger.warning("[Ollama] Tools skipped for #{model} — not in tool_capable_prefixes. " <>
                       "Set OLLAMA_FORCE_TOOLS=true to override.")
        body
      end
  end
end
```

Also expose `OLLAMA_FORCE_TOOLS=true` in `.env.example`.

## Workaround

Add the model name prefix to `@tool_capable_prefixes` in
`lib/optimal_system_agent/providers/ollama.ex` line 25 and recompile. For
models already in the list the partial fix (v0.2.6 adding `llama3.2`) applies.
