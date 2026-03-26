# BUG-009: LLM Picks Wrong Tools or Invents Non-Existent Ones

> **Severity:** CRITICAL
> **Status:** Open
> **Component:** `lib/daemon/tools/registry.ex`, `lib/daemon/agent/loop.ex`
> **Reported:** 2026-03-14

---

## Summary

On some models (particularly smaller Ollama models and models without native
function-calling support) the LLM fabricates tool names that do not exist in the
registry, or calls real tools with completely wrong argument shapes. The tool
executor returns `{:error, "Unknown tool: <name>"}` and the agent loop retries,
potentially looping until `max_iterations` (default 30) is exhausted.

## Symptom

- Tool call log shows `shell_exeucte` instead of `shell_execute`, or
  `read_file` instead of `file_read`.
- `{:error, "Unknown tool: ..."}` appears repeatedly in structured logs.
- Agent reaches iteration limit without completing the task.
- Sometimes the model calls `memory_save` with a `path` argument that does not
  exist in the tool's JSON schema.

## Root Cause

`list_tools_direct/0` in `registry.ex` line 44 returns tool maps with
`:name`, `:description`, and `:parameters`. The description strings are the only
guidance the LLM has for choosing a tool. Several tool descriptions are terse or
ambiguous:

- `memory_save` vs `vault_remember` — both store information; descriptions do
  not clarify the distinction.
- `file_edit` vs `multi_file_edit` — overlapping use cases with no priority
  guidance.
- MCP tools are namespaced as `mcp_<original_name>` (line 177) but the LLM
  prompt never explains this convention.

Additionally, `validate_arguments/2` at line 120 fails open when
`ex_json_schema` is not compiled (line 123: `unless Code.ensure_loaded?(ExJsonSchema.Schema)`),
so malformed arguments reach the tool implementation unchanged, producing
confusing error messages.

## Impact

- Silent task failure when the LLM hallucinates a non-existent tool name.
- Wasted iterations and tokens on hallucination retry loops.
- Particularly bad for users on small local models (< 8B params).

## Suggested Fix

1. Sharpen tool descriptions to include one-line disambiguation from similar
   tools. Add a `NOTE: prefer X over Y when…` line to commonly confused pairs.

2. Add a spelling-corrector pass in the tool executor — before returning
   `{:error, "Unknown tool"}`, check Jaro-Winkler distance against registered
   names and auto-correct obvious typos:

```elixir
defp maybe_correct_tool_name(name, builtin_tools) do
  registered = Map.keys(builtin_tools)
  case Enum.max_by(registered, &String.jaro_distance(&1, name)) do
    best when String.jaro_distance(best, name) > 0.88 -> best
    _ -> nil
  end
end
```

3. Make `ex_json_schema` a mandatory dependency rather than optional so argument
   validation always runs.

## Workaround

Switch to a model in `@tool_capable_prefixes` (e.g. `qwen2.5:14b`,
`llama3.3:70b`) which has native function-calling support and is far less likely
to hallucinate tool names.
