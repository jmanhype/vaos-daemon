# Context Builder

Assembles the system prompt for each LLM call within a token budget. Operates in two tiers: a cached static base and a per-request dynamic context.

**Module:** `Daemon.Agent.Context`

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     System Message                       │
├──────────────────────────────┬──────────────────────────┤
│  Tier 1: Static Base         │  Tier 2: Dynamic Context  │
│  (cached, persistent_term)   │  (per-request, budgeted)  │
│                              │                           │
│  SYSTEM.md interpolated with │  Runtime block            │
│  {{TOOL_DEFINITIONS}}        │  Environment block        │
│  {{RULES}}                   │  Plan mode block          │
│  {{USER_PROFILE}}            │  Memory block             │
│                              │  Episodic block           │
│  Signal Theory instructions  │  Task state block         │
│                              │  Workflow block           │
│  Never recomputed within     │  Skills block             │
│  a session.                  │  Scratchpad block         │
│                              │  Knowledge block          │
└──────────────────────────────┴──────────────────────────┘
│                  Conversation History                     │
└─────────────────────────────────────────────────────────┘
```

For Anthropic, the system message is split into two `content` blocks. The static base receives `cache_control: %{type: "ephemeral"}`, achieving approximately 90% cache hit rate after the first call. All other providers receive a single concatenated string.

---

## Token Budget

```
dynamic_budget = max_tokens(model) - @response_reserve - conversation_tokens - static_tokens

@response_reserve = 8_192   (always reserved for the LLM's reply)
```

`max_tokens/1` resolves the context window for the active model via `MiosaProviders.Registry.context_window/1`. Falls back to the `:max_context_tokens` config key (default `128_000`) if the model is not set.

The dynamic budget is floored at `1_000` so at least some dynamic context fits even under extreme conversation lengths.

---

## Dynamic Blocks

Blocks are gathered in priority order. Each block is a `{content, priority, label}` tuple. All blocks currently use priority `1` except `skills` and `knowledge`, which use priority `2`. The `fit_blocks/2` function processes them in order and stops adding when the budget is exhausted, truncating the last block that partially fits.

| Order | Block | Label | Priority | Source |
|-------|-------|-------|----------|--------|
| 1 | Tool process instructions | `tool_process` | 1 | Hardcoded prompt: tool selection rules and cwd |
| 2 | Runtime context | `runtime` | 1 | Timestamp, channel, session ID |
| 3 | Environment | `environment` | 1 | Working directory, date, provider/model, git info |
| 4 | Plan mode overlay | `plan_mode` | 1 | Injected only when `state.plan_mode == true` |
| 5 | Long-term memory | `memory` | 1 | `Memory.recall()` filtered by keyword overlap with latest user message |
| 6 | Episodic events | `episodic` | 1 | Last 10 session events from `Memory.Episodic.recent/2` |
| 7 | Task state | `task_state` | 1 | Active tasks from `Tasks.get_tasks/1` with status icons |
| 8 | Workflow context | `workflow` | 1 | `Tasks.workflow_context_block/1` |
| 9 | Active skills | `skills` | 2 | `Tools.Registry.active_skills_context/1` filtered by latest message |
| 10 | Scratchpad instruction | `scratchpad` | 1 | Injected only for non-Anthropic providers |
| 11 | Knowledge graph | `knowledge` | 2 | `MiosaKnowledge.Context.for_agent/2` |

Nil or empty blocks are excluded before fitting.

---

## Memory Block

The memory block uses relevance filtering rather than dumping the full recall. The latest user message is tokenized into words ≥ 3 characters. Memory sections (split on `## ` headers) are included only if they share at least 2 words with the query, or 20% of the query words. If no sections match, the block is omitted entirely.

Taxonomy entries from the learning engine (patterns and solutions) are appended separately via `Memory.Injector.inject_relevant/2`, which scores each entry against the current task and file context.

---

## Environment Block (git info cache)

Git info (branch, modified files, recent commits) is cached in the `:daemon_git_info_cache` ETS table with a 30-second TTL. The cache is keyed on the atom `:git_info`. This prevents repeated `git` subprocess invocations across iterations within the same message turn.

---

## Block Fitting

```elixir
defp fit_blocks(blocks, budget) do
  Enum.reduce(blocks, {[], 0}, fn {content, _priority, _label}, {acc, tokens_used} ->
    block_tokens = estimate_tokens(content)
    available = budget - tokens_used

    cond do
      available <= 0       -> {acc, tokens_used}           # budget exhausted
      block_tokens <= available -> {acc ++ [content], ...} # fits whole
      true                 -> {acc ++ [truncated], ...}    # truncate last block
    end
  end)
end
```

Truncation uses a word-count approximation: `max_words = round(target_tokens / 1.3)`. Truncated blocks end with `\n\n[...truncated...]`.

---

## Token Estimation

`estimate_tokens/1` uses the Go tokenizer (`Daemon.Go.Tokenizer.count_tokens/1`) when available for accurate BPE counts. Falls back to a word + punctuation heuristic:

```
words * 1.3 + punctuation_chars * 0.5
```

For message lists, each message adds 4 tokens of framing overhead (role label, delimiters). Tool call arguments each add `name_tokens + arg_tokens + 4`.

---

## Public API

```elixir
Context.build(state)
# Returns %{messages: [system_msg | conversation_messages]}

Context.token_budget(state)
# Returns detailed breakdown:
# %{
#   max_tokens, response_reserve, conversation_tokens,
#   static_base_tokens, dynamic_context_tokens,
#   system_prompt_budget, system_prompt_actual,
#   total_tokens, utilization_pct, headroom,
#   blocks: [%{label, priority, tokens}]
# }

Context.estimate_tokens(text_or_nil)
Context.estimate_tokens_messages(messages)
```

See also: [loop.md](loop.md), [compactor.md](compactor.md)
