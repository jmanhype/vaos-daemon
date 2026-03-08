# Cortex

The Cortex is the synthesis layer of the OSA memory stack. It reads from session history, long-term memory, and episodic events to produce bulletins, track active topics, and generate session summaries. It runs as a GenServer (`MiosaMemory.Cortex`) under AgentServices.

## Responsibilities

- Maintain a live list of active topics across conversations
- Generate targeted bulletins when topics recur
- Produce condensed session summaries for context injection
- Expose synthesis statistics for observability

## API

`OptimalSystemAgent.Agent.Cortex` delegates to `MiosaMemory.Cortex`:

```elixir
alias OptimalSystemAgent.Agent.Cortex

# Get the latest bulletin (synthesized insight text)
bulletin = Cortex.bulletin()

# Force a synthesis refresh
Cortex.refresh()

# List currently active topics with recency and reference count
topics = Cortex.active_topics()

# Get a summary of a specific session
summary = Cortex.session_summary(session_id)

# Observe internal synthesis stats
stats = Cortex.synthesis_stats()
```

## Bulletins

A bulletin is a short synthesized text produced by the Cortex from recent patterns, active topics, and session content. It is injected into the agent's context as a system message before the LLM call, giving the agent awareness of cross-session themes without requiring it to recall them explicitly.

```
[cortex bulletin]
Active topic: "SQLite connection pool sizing" (referenced 8 times across 3 sessions)
Related solution: parameterized query pattern applied in session-abc
Recent pattern: user frequently asks for explanation before implementation
```

The Cortex generates a new bulletin on each `refresh/0` call. `refresh/0` is called by the agent loop at the start of each turn.

## Active Topics

Active topics are extracted from session messages and cross-referenced against episodic memory. The Cortex tracks each topic with:

- Name or key phrase
- Reference count (how many times it has appeared)
- Last seen timestamp
- Linked episodes or decisions (if any)

Topics are ranked by a recency-weighted frequency score. Topics that have not been referenced within a decay window drop off the active list.

```elixir
[
  %{topic: "connection pool sizing", count: 8, last_seen: ~U[2026-03-08 09:45:00Z]},
  %{topic: "Ecto query optimization",count: 5, last_seen: ~U[2026-03-07 14:20:00Z]},
  %{topic: "OTP supervision trees",  count: 3, last_seen: ~U[2026-03-06 11:00:00Z]}
]
```

## Session Summaries

`session_summary/1` returns a condensed representation of a completed or ongoing session. It uses `MiosaMemory.Session.summarize/1` as its base, then enriches it with topic links from the Cortex's topic tracker.

Summaries are used when the agent resumes a session or when building context for a new session in the same project. They allow the agent to orient itself quickly without loading the full message history.

## CortexProvider Bridge

`OptimalSystemAgent.Agent.CortexProvider` is a one-function bridge module that wires `MiosaMemory.Cortex`'s LLM synthesis calls to OSA's provider registry:

```elixir
defmodule OptimalSystemAgent.Agent.CortexProvider do
  def chat(messages, opts) do
    MiosaProviders.Registry.chat(messages, opts)
  end
end
```

`MiosaMemory.Cortex` is provider-agnostic — it accepts any module that implements `chat/2`. This bridge is injected at startup so Cortex synthesis uses whatever provider OSA is configured with (Anthropic, Ollama, etc.), selected through the standard provider registry fallback chain.

## Context Injection Flow

```mermaid
sequenceDiagram
    participant Loop as Agent Loop
    participant Cortex as MiosaMemory.Cortex
    participant Store as MiosaMemory.Store.ETS
    participant Session as MiosaMemory.Session
    participant LLM as LLM Provider

    Loop->>Cortex: refresh()
    Cortex->>Session: messages(session_id, 20)
    Cortex->>Store: search("patterns", active_topics)
    Cortex->>Cortex: synthesize bulletin
    Cortex-->>Loop: :ok

    Loop->>Cortex: bulletin()
    Cortex-->>Loop: bulletin_text

    Loop->>LLM: [system: bulletin_text, ...conversation]
    LLM-->>Loop: response
```

## Synthesis Statistics

```elixir
%{
  bulletins_generated: 47,
  topics_tracked:       12,
  last_refresh:        ~U[2026-03-08 10:01:00Z],
  avg_refresh_ms:       23
}
```

## Compactor Relationship

The Cortex works alongside `MiosaMemory.Compactor`. The Compactor reduces raw message history when context approaches the token limit; the Cortex synthesizes _meaning_ from that history and injects it back in structured form. They are complementary:

| Component | Input | Output | Token effect |
|-----------|-------|--------|-------------|
| Compactor | Long message list | Shorter list + summary messages | Reduces |
| Cortex | Patterns + sessions | Bulletin (system message) | Adds (small, fixed) |

The bulletin is kept short (a few hundred tokens) so it does not counteract the Compactor's savings.

## Configuration

No dedicated configuration block. The Cortex inherits:

- LLM provider from `CortexProvider` → `MiosaProviders.Registry`
- Session access from `MiosaMemory.Session` (uses `session_path` config)
- Store access from `MiosaMemory.Store.ETS`

## See Also

- [overview.md](./overview.md) — Layer 5 position in the memory stack
- [memory-store.md](./memory-store.md) — Store that Cortex reads from
- [learning.md](./learning.md) — Patterns that feed into Cortex topic tracking
- [episodic.md](./episodic.md) — Episodes linked to active topics
