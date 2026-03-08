# Scratchpad

Provider-agnostic thinking support. Gives non-Anthropic LLMs a private reasoning space equivalent to Anthropic's native extended thinking.

**Module:** `OptimalSystemAgent.Agent.Scratchpad`

---

## Two Paths

| Provider | Mechanism |
|----------|-----------|
| Anthropic | Native extended thinking via API parameter. No scratchpad injection needed. |
| All others | `<think>...</think>` injection: instruction added to system prompt, blocks extracted from responses. |

The gate is `Scratchpad.inject?/1`:

```elixir
def inject?(provider) do
  enabled = Application.get_env(:optimal_system_agent, :scratchpad_enabled, true)
  enabled and provider != :anthropic
end
```

Disabled globally by setting `:scratchpad_enabled` to `false`.

---

## Injection (non-Anthropic)

When `inject?/1` is true, the context builder adds the scratchpad block to the dynamic context via `scratchpad_block/1`. The instruction tells the model to reason inside `<think>...</think>` tags before every response or action:

```
## Private Reasoning

Before responding or taking actions, reason step-by-step inside <think>...</think> tags. Use this space to:
- Analyze the request and break it into sub-problems
- Consider edge cases, risks, and alternative approaches
- Plan your tool calls before executing them
- Reflect on previous results before deciding next steps

Content inside <think> tags is captured for learning but NOT shown to the user.
Your visible response should contain only the final answer or action — never the reasoning process.
```

---

## Extraction

After the LLM responds (for non-Anthropic providers), the loop calls `Scratchpad.process_response/2` on the response content. This happens in two places:

1. **Final response** (no tool calls): after content is received, before returning.
2. **Tool-call response**: the assistant content is stripped of thinking blocks before being appended to the message history.

`extract/1` uses the pattern `~r/<think>(.*?)<\/think>/s` (dotall, capturing inner content):

```elixir
{clean_text, thinking_parts} = Scratchpad.extract(text)
# clean_text     — response with all <think> blocks removed, excess newlines collapsed
# thinking_parts — list of trimmed thinking strings
```

Extracted thinking is joined with `"\n\n---\n\n"` separators when multiple blocks are present.

---

## Events Emitted

`process_response/2` emits two events when thinking is captured:

| Event | When |
|-------|------|
| `:system_event / :thinking_delta` | Immediately on extraction — for TUI display |
| `:system_event / :thinking_captured` | Same event — for the learning engine |

Both events carry `session_id` and `text` (the combined thinking content).

---

## Anthropic Native Thinking

For Anthropic, `LLMClient.thinking_config/1` returns a `thinking` options map that is passed directly to the API. Thinking blocks in the response are preserved in the assistant message as `thinking_blocks` for continuity across iterations (Anthropic requires thinking blocks to be echoed back). The loop does not call `Scratchpad.extract/1` for Anthropic — the native thinking response is handled at the protocol level.

---

## Public API

```elixir
Scratchpad.inject?(provider)
# Returns boolean — true when <think> injection should be used.

Scratchpad.instruction()
# Returns the system prompt instruction string to inject.

Scratchpad.extract(text)
# Returns {clean_text, [thinking_part]}

Scratchpad.process_response(text, session_id)
# Extracts thinking, emits events, returns clean text.
```

See also: [loop.md](loop.md), [context.md](context.md)
