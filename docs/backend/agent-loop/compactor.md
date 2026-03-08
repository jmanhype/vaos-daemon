# Context Compactor

Intelligent sliding-window context compaction with importance-weighted retention. Runs as a GenServer that records metrics; the actual compaction logic is pure functions safe to call from any process.

**Module:** `OptimalSystemAgent.Agent.Compactor`

---

## When Compaction Runs

`Compactor.maybe_compact/1` is called in two places:

1. At the start of every `process_message` call (before the loop).
2. On context overflow error during the loop (up to 3 overflow retries).

The function is safe — it never raises. On any error it returns the original message list unchanged.

---

## Three Zones

Messages are divided into zones based on position from the end of the non-system message list:

| Zone | Positions (from end) | Treatment |
|------|----------------------|-----------|
| HOT | Last 20 messages | Never touched — always verbatim |
| WARM | Messages 21–50 | Progressive compression pipeline |
| COLD | Messages 51+ | Collapsed to a single key-facts summary |

System messages are separated before zoning and prepended back after compaction.

---

## Activation Thresholds

| Threshold config key | Default | Severity | Pipeline target |
|---------------------|---------|----------|-----------------|
| `:compaction_warn` | `0.85` | `:background` | 70% of max tokens |
| `:compaction_aggressive` | `0.85` | `:aggressive` | 60% of max tokens |
| `:compaction_emergency` | `0.95` | `:emergency` | 50% of max tokens |

Note: warn and aggressive share the same default, so in practice the first trigger hits both. The targets reduce the conversation to 70%, 60%, or 50% of the context window depending on severity.

---

## Progressive Compression Pipeline

Steps run sequentially. After each step the token count is checked — the pipeline stops as soon as usage drops below the target. Steps that are no longer needed are skipped.

**Step 1 — Strip tool-call argument details**

Replaces the `arguments` field on every tool call in the WARM zone with `"[args stripped]"`. Keeps the call name and result so the LLM knows what was done without the verbose input payloads.

**Step 2 — Merge consecutive same-role messages**

Merges adjacent `user`–`user` or `assistant`–`assistant` messages by concatenating their content with a newline. Does not merge messages that have `tool_calls` or `tool_call_id` fields. On merge, takes the higher importance score.

**Step 3 — Summarize warm-zone message groups (LLM call)**

Groups warm-zone messages by importance score (lowest first) into chunks of 5. Each group with more than 200 tokens is sent to the LLM for summarization using the `compactor_summary` prompt template (fallback hardcoded). The summary replaces the group as a single `system` role message with `[Warm Summary]` prefix and importance `1.5`. Groups that fail LLM summarization are kept verbatim.

**Step 4 — Compress cold zone to key facts (LLM call)**

Sends all cold-zone messages to the LLM using the `compactor_key_facts` prompt template (fallback hardcoded). The LLM extracts decisions made, user preferences, key data/results, and commitments. The result replaces the entire cold zone as a single `system` message with `[Context Summary]` prefix and importance `2.0`. On LLM failure, falls through to step 5.

**Step 5 — Emergency truncate**

No LLM call. Keeps only the HOT zone (last 20 messages). Prepends a topic notice to the system messages: `[Context truncated due to length. Earlier conversation was about: <user message excerpts>]`. This is a last resort — the topic notice is extracted from the first 100 characters of each dropped user message.

---

## Importance Scoring

Each non-system message is annotated with an importance score before the pipeline runs. Higher scores resist compression:

| Factor | Bonus/Penalty |
|--------|--------------|
| Base score | `1.0` |
| Has tool calls | `+0.5` |
| Role is `"tool"` (tool result) | `+0.3` |
| Content length / 500 (capped) | `+0..0.3` |
| Content matches acknowledgment pattern | `-0.5` |

Acknowledgment patterns: `ok`, `okay`, `sure`, `thanks`, `thank you`, `got it`, `yes`, `no`, `yep`, `nope`, `k`, `kk`, `alright`, `cool`, `nice`, `great`, `perfect`, `noted`, `ack`, `roger`, `👍`, `👌`.

The minimum importance score is `0.1`.

The warm-zone step sorts messages by importance ascending before grouping, so the least important messages are summarized first.

---

## Token Estimation

Uses the Go tokenizer (`OptimalSystemAgent.Go.Tokenizer.count_tokens/1`) for accurate BPE counts when available. Falls back to:

```
words * 1.3 + punctuation_chars * 0.5
```

For message lists, each message adds 4 tokens of framing overhead. Tool call arguments are counted separately as `name_tokens + arg_tokens + 4` per call.

---

## LLM Calls

Both summary LLM calls use `MiosaProviders.Registry.chat/2` (the default configured provider):

| Call | Temperature | Max tokens |
|------|-------------|------------|
| `call_summary_llm/1` (warm zone) | `0.2` | `400` |
| `call_key_facts_llm/1` (cold zone) | `0.1` | `512` |

In test environments, `:compactor_llm_enabled` can be set to `false` to disable LLM calls and return stub summaries instead.

---

## Metrics

The GenServer records compaction metrics via `handle_cast({:record_compaction, tokens_saved, step})`:

```elixir
Compactor.stats()
# Returns:
# %{
#   compaction_count: integer,
#   tokens_saved: integer,
#   last_compacted_at: DateTime.t() | nil,
#   pipeline_steps_used: %{step_name => count}
# }
```

---

## Public API

```elixir
Compactor.maybe_compact(messages)
# Returns possibly-compacted message list. Never raises.

Compactor.utilization(messages)
# Returns float (0.0–100.0) — percentage of max_tokens used.

Compactor.estimate_tokens(messages_or_string)
# Returns non_neg_integer token count estimate.

Compactor.stats()
# Returns compaction metrics map.
```

See also: [loop.md](loop.md), [context.md](context.md)
