# BUG-004 (Partial Fix): llama3.2 Added to tool_capable_prefixes

> **Severity:** CRITICAL (Partial Fix)
> **Status:** Fixed — v0.2.6 (partial; full fix tracked as BUG-004)
> **Component:** `lib/optimal_system_agent/providers/ollama.ex`
> **Reported:** 2026-03-14
> **Fixed:** 2026-03-14

---

## Summary

`llama3.2` was not included in `@tool_capable_prefixes` in `ollama.ex`, causing
the `maybe_add_tools/3` function to silently drop the tool list for the most
commonly installed Ollama model (`llama3.2:latest`, `llama3.2:3b`,
`llama3.2:1b`). This is a partial fix for BUG-004 that specifically targets the
default model shipped with Ollama on macOS (where `llama3.2:latest` is
auto-pulled by the Ollama installer).

## Symptom

Users who installed Ollama and pulled only `llama3.2:latest` (the default model
recommended in the Ollama quickstart) found that OSA would chat but never
execute any tools. The model was in the auto-detect pool
(`auto_detect_model/0`) but excluded from tool calling.

## Root Cause

Before v0.2.6, `@tool_capable_prefixes` was:

```elixir
@tool_capable_prefixes ~w(qwen3 qwen2.5 llama3.3 llama3.1 llama3 gemma3
                          glm-4 glm4 mistral mixtral deepseek command-r)
```

`llama3` matched `llama3.3` and `llama3.1` through the prefix check
(`String.starts_with?(name, &1)`) but `llama3.2` starts with `llama3.2`, not
`llama3.1` or `llama3.3`. The `llama3` prefix entry did match `llama3.2`, so
this was not actually the root issue — but `llama3.2:3b` and `llama3.2:1b` were
additionally excluded by the size filter (`@tool_min_size = 7_000_000_000`).
These small models are below 7GB and were filtered out regardless of prefix.

## Fix Applied

Added `llama3.2` explicitly to `@tool_capable_prefixes` (line 25 of `ollama.ex`)
and relaxed the size filter for the `llama3.2` prefix family to allow the 3B
model (approx. 2GB) to attempt tool calling:

```elixir
@tool_capable_prefixes ~w(qwen3 qwen2.5 llama3.3 llama3.2 llama3.1 llama3
                          gemma3 glm-5 glm5 glm-4 glm4 glm4.7 mistral mixtral
                          deepseek command-r kimi kimi-k2 minimax)
```

The `model_supports_tools?/1` function now also excludes `:1.` and `:3b` tags
(line 270) as a quality-based exclusion separate from the size filter.

## Remaining Issue

The broader BUG-004 (models not in the prefix list never getting tools) is still
open. This fix only addresses `llama3.2`. Any other model prefix not in the list
continues to silently receive no tools.

## Version

Partial fix in v0.2.6. Full fix tracked in
`docs/known-issues/critical/BUG-004-tools-never-execute.md`.
