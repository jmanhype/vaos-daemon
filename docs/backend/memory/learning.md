# Learning Engine

The learning engine records patterns, solutions, and error corrections from agent interactions and makes them available for future context injection. It runs as a GenServer (`MiosaMemory.Learning`) under the AgentServices supervisor.

## Responsibilities

- Capture observed interaction patterns with frequency counts
- Record proven solutions keyed by error type
- Accept explicit user corrections and flag anti-patterns
- Expose metrics on what has been learned
- Consolidate and deduplicate knowledge on demand
- Sync learned knowledge into the knowledge graph via `KnowledgeBridge`

## API

The Daemon alias `Daemon.Agent.Learning` delegates to `MiosaMemory.Learning`:

```elixir
alias Daemon.Agent.Learning

# Record an interaction for pattern extraction
Learning.observe(%{
  type: :tool_success,
  tool: "file_edit",
  input: %{path: "lib/foo.ex"},
  output: :ok,
  session_id: session_id
})

# Record a user correction
Learning.correction(
  _what_was_wrong: "Used string concatenation for SQL query",
  _what_is_right:  "Always use parameterized queries"
)

# Record a tool error with context
Learning.error("shell_execute", "Permission denied: /etc/hosts", %{
  command: "echo foo > /etc/hosts",
  session_id: session_id
})

# Read what has been learned
patterns  = Learning.patterns()   # %{"pattern_key" => count, ...}
solutions = Learning.solutions()  # %{"error_type" => "resolution text", ...}
metrics   = Learning.metrics()    # %{observations: N, corrections: N, errors: N}

# Consolidate: merge duplicates, prune low-frequency entries
Learning.consolidate()
```

## What Gets Stored

### Patterns

A pattern is a recurring behavior fingerprint. `observe/1` extracts a key from the interaction (e.g., `"tool_success:file_edit"`) and increments a frequency counter. When a pattern key reaches a configurable threshold it becomes a knowledge graph node via `KnowledgeBridge`.

```elixir
# patterns/0 returns a map of pattern_key → frequency
%{
  "tool_success:file_edit"      => 12,
  "tool_success:shell_execute"  => 8,
  "strategy:plan_then_execute"  => 5
}
```

### Solutions

A solution maps an error type to a proven resolution. `error/3` extracts the error type from the message (e.g., `"PermissionDenied"`) and stores the resolution text.

```elixir
# solutions/0 returns a map of error_type → resolution text
%{
  "PermissionDenied" => "Check file permissions; use sudo only when explicitly permitted",
  "JSONDecodeError"  => "Strip markdown fences before parsing LLM output"
}
```

### Corrections

`correction/2` stores the before/after pair as an anti-pattern entry. These are weighted more heavily during consolidation because they represent explicit human feedback.

## Consolidation

`Learning.consolidate/0` performs a maintenance pass:

1. Prunes pattern entries with frequency below a minimum threshold (prevents noise accumulation)
2. Deduplicates solutions with identical error types (keeps most recent)
3. Persists the cleaned state to `~/.daemon/learning/` (patterns.json, solutions.json)

Consolidation is triggered:
- Explicitly by calling `Learning.consolidate/0`
- By the agent loop after every `auto_insights_interval` turns (default: 10)
- At session end

## Knowledge Graph Sync (KnowledgeBridge)

`Daemon.Agent.Memory.KnowledgeBridge` runs as a GenServer that wakes every 60 seconds and publishes the current patterns and solutions as RDF triples into the `"osa_default"` knowledge store:

```
Pattern triples:
  {"pattern:<key>", "rdf:type",      "osa:LearnedPattern"}
  {"pattern:<key>", "osa:frequency", "<count>"}

Solution triples:
  {"error:<type>", "rdf:type",    "osa:KnownError"}
  {"error:<type>", "osa:solution", "<text>"}
```

The sync is best-effort. If the knowledge store is not yet running (e.g., during startup or test teardown), the sync call is silently skipped. All errors are rescued so `KnowledgeBridge` never crashes on a knowledge store failure.

To trigger an immediate sync outside the schedule:

```elixir
Daemon.Agent.Memory.KnowledgeBridge.sync_now()
```

## Taxonomy and Injector Integration

The learning engine writes entries through `MiosaMemory.Taxonomy` (classification) and relies on `MiosaMemory.Injector` to filter and format them for prompt injection. These modules are planned additions to the `miosa_memory` package; the Daemon alias modules (`Agent.Memory.Taxonomy`, `Agent.Memory.Injector`) are forward declarations for that interface.

When implemented, the flow is:

```
Learning.observe(interaction)
    └─ Taxonomy.categorize(content)    → assigns :category, :scope
    └─ Store.put(collection, key, entry)

Context build time:
    └─ Injector.inject_relevant(entries, context)
       └─ Taxonomy.filter_by(entries, %{scope: :workspace, category: :pattern})
       └─ Injector.format_for_prompt(filtered_entries)
```

See [taxonomy.md](./taxonomy.md) for category and scope definitions.

## Swarm Intelligence Extension

`Daemon.Agent.Learning.Intelligence` provides a multi-agent swarm mode built on top of the learning infrastructure. It is separate from the core learning engine and intended for complex exploratory tasks, not routine learning.

Two swarm types:

| Type | Function | Agents |
|------|----------|--------|
| Exploration | `Intelligence.explore/2` | N explorers + synthesizer + critic |
| Specialist | `Intelligence.specialize/2` | Domain specialists + coordinator + synthesizer |

Swarms share state via a per-swarm `SharedMemory` Agent process. Explorers add findings, synthesizers generate hypotheses, critics vote. Convergence is declared when the average vote on the top hypothesis exceeds a threshold (default: 0.8).

Swarm results are returned as a map and emitted as events on `Events.Bus`. They are not automatically written back to the learning engine — the caller decides whether to persist findings.

```elixir
{:ok, result} = Intelligence.explore("Debug the auth timeout issue",
  num_explorers: 3,
  max_rounds: 10,
  convergence_threshold: 0.8
)

{:ok, result} = Intelligence.specialize("Optimize Ecto queries",
  domains: ["sql", "indexing", "caching"]
)
```

## Metrics

```elixir
%{
  observations: 142,    # total calls to observe/1
  corrections:  7,      # total calls to correction/2
  errors:       23,     # total calls to error/3
  patterns:     18,     # distinct pattern keys stored
  solutions:    11      # distinct error types with solutions
}
```

## See Also

- [episodic.md](./episodic.md) — Episode storage used by the learning engine
- [taxonomy.md](./taxonomy.md) — Classification applied to learned entries
- [cortex.md](./cortex.md) — Synthesis layer that reads from learned patterns
- [overview.md](./overview.md) — How the learning engine fits in the 5-layer stack
