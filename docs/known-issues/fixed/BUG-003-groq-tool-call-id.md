# BUG-003: Missing tool_call_id in Groq Tool Result Formatting

> **Severity:** HIGH
> **Status:** Fixed — v0.2.5
> **Component:** `lib/daemon/providers/openai_compat.ex`
> **Reported:** 2026-03-14
> **Fixed:** 2026-03-14

---

## Summary

When the agent loop executed a tool and formatted the result back into the
conversation history for Groq, the `tool_call_id` field was missing from the
tool result message. Groq's API requires every `role: "tool"` message to carry
a `tool_call_id` that matches the original `id` from the assistant's tool call.
Without it, the API returned HTTP 400 on the second LLM call in any multi-step
agentic task, aborting the loop.

## Symptom

First tool call worked. Second LLM call (iteration 2) with tool result in
history failed:

```
Groq returned 400: {"error": {"message": "Messages with role 'tool' must have a tool_call_id"}}
```

All multi-step tool-using sessions with Groq provider crashed on iteration 2.

## Root Cause

The `format_messages/1` function in `openai_compat.ex` handled tool result
messages but the branch that matched `%{role: "tool"}` messages did not extract
`tool_call_id`:

```elixir
# Before fix — tool result branch was:
%{role: "tool", content: content} ->
  %{"role" => "tool", "content" => to_string(content)}
  # tool_call_id was not included
```

The `Loop.ToolExecutor` at `tool_executor.ex` line 164 correctly set
`tool_call_id: tool_call.id` on the tool result map, but the `format_messages`
function in the compat provider discarded it via the catch-all `%{role, content}`
pattern.

## Fix Applied

Added a specific clause for tool result messages in `openai_compat.ex` line 332
that preserves `tool_call_id`:

```elixir
%{role: "tool", content: content, tool_call_id: id} = msg ->
  base = %{"role" => "tool", "content" => to_string(content), "tool_call_id" => to_string(id)}
  # Also include :name if present (some providers require it)
  ...
```

This clause was added before the generic `%{role, content}` catch-all, ensuring
Groq and all other OpenAI-compatible providers receive the required `tool_call_id`.

## Verification

Multi-step tool-using sessions with Groq now complete successfully through all
iterations. Tested with `web_search` → `file_write` two-tool chains.

## Version

Fixed in v0.2.5.
