# Episodic Memory

Records structured episodes — discrete learning events with type, description, context, and outcome — into the long-term store. Built on top of `MiosaMemory.Store` using the `"episodic"` collection.

## What an Episode Is

An episode represents one knowledge acquisition event:

```elixir
%{
  type:        :pattern | :solution | :decision,
  description: "Users consistently ask about connection pool sizing",
  context:     "Database configuration discussions",
  outcome:     "Created a connection pool sizing guide",
  tags:        ["database", "config", "pool"],
  created_at:  ~U[2026-03-08 10:00:00Z]
}
```

## Episode Types

| Type | Meaning | Typical source |
|------|---------|----------------|
| `:pattern` | A recurring behavior or structure observed across interactions | Learning engine `observe/1` |
| `:solution` | A proven resolution to a known class of problem | Learning engine `error/3` |
| `:decision` | An architectural or design choice with rationale | Manual `/mem-save decision` |

## Recording Episodes

```elixir
MiosaMemory.Episodic.record_episode(:pattern, %{
  description: "JSON parse failures cluster around multi-line LLM responses",
  context:     "Tool result processing in Loop",
  outcome:     "Added strip_markdown_fences/1 pre-parse normalization",
  tags:        ["json", "llm", "parsing"]
})
```

Internally, `record_episode/2` generates a time-stamped key (`pattern_<microseconds>`) and calls `MiosaMemory.store("episodic", key, episode, tags: [type_string | user_tags])`. The type string is always prepended to tags to enable efficient type-scoped search.

## Recall

### By Similarity

```elixir
{:ok, episodes} = MiosaMemory.Episodic.recall_similar("connection timeout database")
```

Delegates to `MiosaMemory.search("episodic", query)`. The ETS store lowercases all search terms and matches against key, serialized value, and tags. Returns episodes sorted by `updated_at` descending.

### By Type

```elixir
{:ok, patterns}  = MiosaMemory.Episodic.patterns()
{:ok, solutions} = MiosaMemory.Episodic.solutions()
{:ok, decisions} = MiosaMemory.Episodic.decisions()
{:ok, all}       = MiosaMemory.Episodic.all()
```

Type-scoped recalls search for the type string in the `"episodic"` collection, then filter the results to confirm the `type` field matches. This double-check handles any edge cases where tag search returns false positives from adjacent collections.

## Temporal Decay

`Daemon.Agent.Memory.Episodic.temporal_decay/2` computes a relevance weight for an episode given its age:

```elixir
# Returns a float in [0.0, 1.0]
weight = Episodic.temporal_decay(episode.created_at, _half_life_hours = 168)
```

The formula is an exponential decay: `2^(-(elapsed_hours / half_life_hours))`. An episode created one half-life ago has weight 0.5. This weight is used by callers that rank recall results by recency.

Default half-life is 168 hours (7 days). Adjust per use-case:

| Use case | Half-life |
|----------|-----------|
| Tool error solutions | 720h (30 days) — errors recur slowly |
| Active topic patterns | 24h — high churn |
| Architecture decisions | `∞` (don't decay) — manually archived |

## Context Injection

The Daemon agent loop injects episodic memory into context through `MiosaMemory.Context.inject/2`:

```elixir
# Loop builds context before LLM call
context = MiosaMemory.Context.inject(base_messages,
  collections: ["episodic", "decisions", "patterns"],
  query: current_user_message,
  max_injections: 5
)
```

Matching episodes appear as system-role messages prefixed `[memory:<key>]`, placed before the conversation history. The agent loop limits injections to avoid consuming too much of the token budget.

## Daemon Alias

`Daemon.Agent.Memory.Episodic` delegates all functions to `MiosaMemory.Episodic`:

```elixir
alias Daemon.Agent.Memory.Episodic

Episodic.record(event_type, data, session_id)   # wraps record_episode/2
Episodic.recall(query, opts)                    # wraps recall_similar/1
Episodic.recent(session_id, limit \\ 20)        # last N events in session
Episodic.stats()                                # count by type
Episodic.clear_session(session_id)              # remove session-scoped events
Episodic.temporal_decay(timestamp, half_life)   # compute decay weight
```

Note: `recent/2` and `clear_session/1` are Daemon extensions layered on top of the base `MiosaMemory.Episodic` API; they filter by `session_id` in the episode's metadata.

## Persistence

Episodes are stored in the `"episodic"` collection of `MiosaMemory.Store.ETS`. When disk persistence is enabled, they appear in `~/.miosa/store/episodic.json` and survive process restarts.

## See Also

- [memory-store.md](./memory-store.md) — Underlying storage and search implementation
- [learning.md](./learning.md) — Learning engine that produces most pattern and solution episodes
- [taxonomy.md](./taxonomy.md) — Category and scope classification applied at write time
