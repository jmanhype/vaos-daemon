# BUG-005: Tool Params Appended to Name on Iteration 2+

> **Severity:** HIGH
> **Status:** Open
> **Component:** `lib/daemon/providers/ollama.ex`
> **Reported:** 2026-03-14

---

## Summary

On the second and subsequent iterations of the ReAct loop, some Ollama models
return a `tool_calls` entry whose `function.name` field contains both the tool
name and JSON arguments concatenated, e.g. `dir_list {"path": "."}`. The
`normalize_tool_name/1` helper strips the suffix, but only when it detects a
whitespace or bracket boundary. Models that use `(` as a separator produce names
like `dir_list({"path":"."})` which are still stripped correctly, but models
that emit `dir_list:path=.` or other delimiters are not handled.

## Symptom

On iteration 2 of a multi-step task, a tool call appears in the TUI with an
unrecognised name such as `shell_execute {\"command\":\"ls\"}`. The registry
returns `{:error, "Unknown tool: shell_execute {\"command\":\"ls\"}"}`, the
agent receives an error result, and the loop either retries or aborts.

## Root Cause

`normalize_tool_name/1` in `ollama.ex` line 456:

```elixir
defp normalize_tool_name(name) when is_binary(name) do
  name |> String.split(~r/[\s({]/) |> List.first() |> String.trim()
end
```

The regex `[\s({]` only splits on whitespace, `(`, and `{`. Delimiters `:`,
`=`, `;`, and `|` are not handled. Additionally, the `format_messages/1`
function at line 274 reconstructs assistant messages from the iteration-1 tool
calls map, re-serializing them as:

```elixir
"function" => %{"name" => tc.name, "arguments" => tc.arguments}
```

If `tc.name` was not normalised on the previous iteration (e.g. the tool call
came through the streaming path at line 437 where a separate `normalize_tool_name`
call exists but is also limited to the same regex), the corrupted name is
re-injected into the conversation history.

## Impact

- Multi-step agentic workflows fail on iteration 2+ when the model concatenates
  arguments into the tool name field.
- Harder to diagnose because iteration 1 often succeeds.
- Specific to Ollama; cloud providers (Anthropic, OpenAI) enforce structured
  function-calling formats.

## Suggested Fix

Broaden the split regex to cover all common delimiters:

```elixir
defp normalize_tool_name(name) when is_binary(name) do
  name
  |> String.split(~r/[\s({:=;|]/)
  |> List.first()
  |> String.trim()
end
```

Also apply `normalize_tool_name/1` to tool names when deserialising from
conversation history in `format_messages/1` (line 281):

```elixir
"function" => %{"name" => normalize_tool_name(tc.name), "arguments" => tc.arguments}
```

## Workaround

None without code change. Affects only Ollama provider on multi-iteration tasks.
