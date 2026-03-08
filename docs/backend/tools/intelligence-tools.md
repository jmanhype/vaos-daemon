# Intelligence Tools

Intelligence tools give agents access to memory, learned patterns, semantic search, and the knowledge graph. They enable agents to recall past decisions, surface relevant context, and reason over structured knowledge.

---

## `memory_recall`

Search and retrieve information from long-term memory.

**Module:** `OptimalSystemAgent.Tools.Builtins.MemoryRecall`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Keywords, topic, or question to look up |

### Behavior

Calls `Memory.recall_relevant/2` with a 4000-token budget. The recall mechanism uses keyword matching combined with recency and importance scoring to surface the most relevant memory entries.

Returns the formatted memory text, or `"No relevant memories found for: <query>"` when nothing matches.

### When to use

- User asks what the agent remembers about a topic
- Agent needs to recall past decisions before making a new one
- Recovering preferences or established patterns

---

## `memory_save`

Save important information to long-term memory.

**Module:** `OptimalSystemAgent.Tools.Builtins.MemorySave`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `content` | string | yes | Information to remember |
| `category` | string | no | Category label (default: `"general"`) |

### Categories

Common categories used across OSA:
- `preference` — user preferences and settings
- `fact` — factual information about the project or domain
- `decision` — architectural or design decisions
- `pattern` — recurring patterns to apply
- `context` — session or project context

Calls `Memory.remember/2` which appends to `MEMORY.md` under the appropriate section.

---

## `semantic_search`

Search across long-term memory and learned patterns using keyword-based semantic matching.

**Module:** `OptimalSystemAgent.Tools.Builtins.SemanticSearch`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Keywords, topic, or question |
| `scope` | string | no | `memory`, `learning`, or `all` (default: `all`) |

### Scopes

| Scope | Searches |
|-------|---------|
| `memory` | MEMORY.md entries via `Memory.recall_relevant/2` (2000-token budget) |
| `learning` | Learned patterns and known solutions via `Learning.patterns/0` and `Learning.solutions/0` |
| `all` | Both sources combined |

### Learning search

The learning search extracts keywords from the query (words > 2 characters), then filters the pattern and solution maps for keys containing those keywords. Returns up to 5 matching patterns and 5 matching solutions.

Pattern output format:
```
### Learned Patterns
- elixir_genserver_pattern: observed 7x
- otp_supervision_tree: observed 3x

### Known Solutions
- **CompileError: undefined function**: Add the module to your application supervision tree
```

---

## `session_search`

Full-text search across past conversation sessions using SQLite FTS5.

**Module:** `OptimalSystemAgent.Tools.Builtins.SessionSearch`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Keywords or phrases to find in past sessions |
| `limit` | integer | no | Maximum results to return (default: 10) |

### Behavior

Uses SQLite FTS5 BM25 ranking to find the most relevant past sessions. Results include:
- Session title
- Session ID
- Relevance score
- A snippet showing the matching context with highlighted terms (`»match«`)

Queries are sanitized for FTS5 syntax — special characters are escaped and short terms (< 2 chars) are removed. Each term is quoted to use exact phrase matching.

### FTS5 table schema

```sql
CREATE VIRTUAL TABLE sessions_fts USING fts5(
  session_id,
  title,
  content
);
```

### Indexing sessions

Sessions are indexed via `SessionSearch.index_session/2` when saved:

```elixir
SessionSearch.index_session(session_id, %{
  title: "Build authentication system",
  content: "full conversation text..."
})
```

---

## `mcts_index`

MCTS-powered codebase indexer that uses Monte Carlo Tree Search to intelligently explore a directory and rank files by relevance to a goal.

**Module:** `OptimalSystemAgent.Tools.Builtins.MCTSIndex`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `goal` | string | yes | What you're looking for in natural language |
| `root_dir` | string | no | Starting directory (default: current working directory) |
| `max_iterations` | integer | no | MCTS exploration budget (default: 50, max: 200) |
| `max_results` | integer | no | Maximum files to return ranked by relevance (default: 20, max: 50) |

### When to use over `file_glob` + `file_read`

- Codebase has hundreds of files
- You need files related to a specific concept, not a filename pattern
- You want ranked results with relevance scores
- You have a bounded exploration budget

### Output

```
Explored 847 nodes across 203 files in 50 iterations.

## Relevant Files (ranked by MCTS score)

1. `lib/auth/token.ex` (relevance: 0.92)
   → defmodule Auth.Token | jwt validation | session expiry

2. `lib/auth/plug.ex` (relevance: 0.88)
   → defmodule Auth.Plug | authenticate_conn | token extraction

3. `lib/users/session.ex` (relevance: 0.71)
   → defmodule Users.Session | create_session | invalidate
```

Delegates to `OptimalSystemAgent.MCTS.Indexer.run/3`.

---

## `knowledge`

Query or modify the semantic knowledge graph backed by MiosaKnowledge.

**Module:** `OptimalSystemAgent.Tools.Builtins.Knowledge`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `query`, `assert`, `retract`, `context`, `count`, `sparql`, `reason` |
| `subject` | string | no | Subject of the triple |
| `predicate` | string | no | Predicate/relationship |
| `object` | string | no | Object/value |
| `agent_id` | string | no | Agent ID for `context` action |
| `sparql_query` | string | no | SPARQL query string |

### Actions

| Action | Description |
|--------|-------------|
| `assert` | Add a triple `(subject, predicate, object)` to the graph |
| `retract` | Remove a triple from the graph |
| `query` | Find triples matching a pattern (any field can be omitted to wildcard) |
| `context` | Generate a prompt-ready context block for a given agent ID |
| `count` | Count total triples in the graph |
| `sparql` | Execute a SPARQL query (SELECT/INSERT/DELETE DATA) |
| `reason` | Run the OWL 2 RL forward-chaining reasoner to materialize inferences |

### Triple store

The knowledge tool operates on the `"osa_default"` named store, registered via `MiosaKnowledge.Registry`. The store is lazily started on first use via `ensure_store_started/0`.

### SPARQL support

The native SPARQL engine supports:
- `SELECT` with `WHERE`, `FILTER`, `OPTIONAL`, `ORDER BY`, `DISTINCT`
- `INSERT DATA` and `DELETE DATA`
- Prefix declarations

```json
{
  "action": "sparql",
  "sparql_query": "SELECT ?file ?author WHERE { ?file <has_author> ?author }"
}
```

### Context injection

The `context` action uses `MiosaKnowledge.Context.for_agent/2` to build a prompt-ready summary of facts relevant to the given agent ID. This is used during sub-agent spawning to inject domain knowledge.

### Query pattern

Any field can be omitted to wildcard-match. Omitting all fields returns all triples.

```json
{"action": "query", "subject": "user:123", "predicate": "has_role"}
```

Returns:
```
Found 2 triples:
  (user:123) --[has_role]--> (admin)
  (user:123) --[has_role]--> (moderator)
```

---

## See Also

- [Tools Overview](./overview.md)
- [Memory Architecture](../memory/overview.md)
- [Knowledge Graph](../memory/knowledge-graph.md)
