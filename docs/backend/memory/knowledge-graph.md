# Knowledge Graph Integration

This document describes how `miosa_knowledge` integrates into Daemon (Daemon). It covers supervision placement, context injection, the learning bridge, the tool interface, and the HTTP API. It does not describe the knowledge library itself — see `miosa_knowledge/README.md` for that.

---

## Overview

Daemon maintains four independent knowledge layers:

| Layer | Module | Persistence | Scope |
|---|---|---|---|
| Long-term Memory | `Agent.Memory` | File (`tasks/memory.md`) | Global, append-only |
| Learning Engine | `Agent.Learning` | ETS (`:daemon_learning`) | Session, patterns + solutions |
| Episodic Memory | `Agent.Memory.Episodic` | ETS | Session, event timeline |
| Session Search | session search via tool | In-memory | Session, semantic similarity |

`miosa_knowledge` adds a fifth layer: **structural knowledge** — a queryable triple store that represents relationships between entities as first-class data. Where the other layers store free text or counters, the knowledge graph stores typed, queryable facts.

The four existing layers are not replaced or modified by this integration.

---

## Architecture

### Supervision Tree Placement

The knowledge store and bridge are started under `AgentServices`, after the Learning subsystem:

```
Application
└── Supervisors.AgentServices  (one_for_one)
    ├── Agent.Learning
    ├── Agent.Memory.Episodic
    ├── ... other agent services ...
    ├── MiosaKnowledge.Registry    ← Registry for named stores
    ├── MiosaKnowledge.Store       ← "osa_default" store (ETS backend)
    └── Agent.Memory.KnowledgeBridge  ← syncs Learning → knowledge graph
```

The store is opened with the name `"osa_default"` and referenced throughout the application via `{:via, Registry, {MiosaKnowledge.Registry, "osa_default"}}`. Both the tool and the HTTP routes call `ensure_store_started/0` as a guard — if the store is not in the supervision tree at runtime (e.g. in test environments), it is started on demand.

### Context Injection

At every request, `Agent.Context.build/1` assembles the dynamic system prompt. The knowledge graph is injected as a named block with priority 2 (lower than core operational blocks, included when budget allows):

```elixir
# In Agent.Context.gather_dynamic_blocks/1:
{knowledge_block(state), 2, "knowledge"}
```

`knowledge_block/1` queries the store for all triples scoped to the current session ID and renders them as markdown:

```elixir
defp knowledge_block(state) do
  store = GenServer.whereis({:via, Registry, {MiosaKnowledge.Registry, "osa_default"}})

  if is_nil(store) do
    ""
  else
    agent_id = Map.get(state, :session_id) || "default"
    ctx = MiosaKnowledge.Context.for_agent(store, agent_id: agent_id)
    MiosaKnowledge.Context.to_prompt(ctx)
  end
end
```

If the store is not running, the block returns `""` and is silently omitted. The query uses `session_id` as the subject scope, so each session sees only its own asserted facts unless explicit cross-session subjects are used.

### Learning Bridge

`Agent.Memory.KnowledgeBridge` is a GenServer that periodically syncs the Learning engine's in-memory data into the knowledge graph.

Sync schedule:
- First sync: 5 seconds after startup (to allow the knowledge store to initialize)
- Subsequent syncs: every 60 seconds
- Manual trigger: `KnowledgeBridge.sync_now/0`

On each sync, it reads `Learning.patterns/0` and `Learning.solutions/0` and batch-asserts them as triples:

**Patterns** (frequency counters from the learning engine):
```
{"pattern:<key>", "rdf:type",       "osa:LearnedPattern"}
{"pattern:<key>", "osa:frequency",  "<count>"}
```

**Solutions** (error-type → resolution mappings):
```
{"error:<type>", "rdf:type",      "osa:KnownError"}
{"error:<type>", "osa:solution",  "<resolution text>"}
```

The sync is best-effort: if the knowledge store is not running, or if `Learning` raises, the sync is silently skipped. The bridge never crashes on a knowledge store failure.

### Tool Interface

The knowledge graph is callable by agents as a tool named `"knowledge"`. It implements `MiosaTools.Behaviour` and is registered in the tool registry.

The tool takes a required `"action"` parameter and optional triple components:

| Parameter | Type | Required for |
|---|---|---|
| `action` | string (enum) | all actions |
| `subject` | string | assert, retract, query |
| `predicate` | string | assert, retract, query |
| `object` | string | assert, retract, query |
| `agent_id` | string | context |
| `sparql_query` | string | sparql |

Seven actions are available:

| Action | Required params | Description |
|---|---|---|
| `assert` | subject, predicate, object | Add a fact to the graph |
| `retract` | subject, predicate, object | Remove a fact from the graph |
| `query` | any subset of S/P/O | Pattern query; wildcards on unspecified positions |
| `context` | agent_id | Return a formatted knowledge context block for an agent |
| `count` | none | Return total triple count |
| `sparql` | sparql_query | Execute a SPARQL query string |
| `reason` | none | Run OWL 2 RL materialization |

### HTTP API

Seven routes are registered under `/api/v1/knowledge/`:

| Method | Path | Description |
|---|---|---|
| GET | `/triples` | Query triples with optional filters |
| POST | `/assert` | Assert a triple |
| POST | `/retract` | Retract a triple |
| POST | `/sparql` | Execute a SPARQL query |
| POST | `/reason` | Run OWL 2 RL reasoner |
| GET | `/context/:agent_id` | Get formatted context for an agent |
| GET | `/count` | Return triple count |

---

## Tool Usage

All seven actions shown with exact parameter shapes:

### assert

```json
{
  "action": "assert",
  "subject": "project:osa",
  "predicate": "written-in",
  "object": "Elixir"
}
```

Response: `"Asserted: (project:osa, written-in, Elixir)"`

### retract

```json
{
  "action": "retract",
  "subject": "project:osa",
  "predicate": "written-in",
  "object": "Elixir"
}
```

Response: `"Retracted: (project:osa, written-in, Elixir)"`

### query

Any combination of subject, predicate, object — all optional:

```json
{
  "action": "query",
  "subject": "project:osa"
}
```

Response:
```
Found 2 triples:
  (project:osa) --[written-in]--> (Elixir)
  (project:osa) --[license]--> (Apache-2.0)
```

```json
{
  "action": "query",
  "predicate": "rdf:type",
  "object": "osa:LearnedPattern"
}
```

Returns all patterns synced from the Learning engine.

### context

```json
{
  "action": "context",
  "agent_id": "session-abc123"
}
```

Response (markdown, ready for prompt injection):
```
# Knowledge Context (session-abc123)
Facts: 3

## Properties
  - role: admin

## Relationships
  - knows: user:bob
  - member-of: team:engineering
```

### count

```json
{
  "action": "count"
}
```

Response: `"Knowledge graph contains 42 triples."`

### sparql

```json
{
  "action": "sparql",
  "sparql_query": "SELECT ?key ?freq WHERE { ?key <osa:frequency> ?freq } ORDER BY DESC(?freq) LIMIT 5"
}
```

Response:
```
SPARQL results (5 rows):
  key = pattern:tool_use,  freq = 47
  key = pattern:file_edit, freq = 31
  ...
```

### reason

```json
{
  "action": "reason"
}
```

Response: `"Reasoning complete. 3 rounds of inference applied."`

This runs OWL 2 RL materialization against the entire store. Use after asserting OWL axioms (subClassOf, inverseOf, etc.) to derive implied facts.

---

## HTTP API Reference

All requests and responses are JSON. The base path is `/api/v1/knowledge`.

### GET /triples

Query triples. All parameters are optional; omitting a parameter makes that position a wildcard.

**Request:**
```
GET /api/v1/knowledge/triples?subject=project:osa&predicate=written-in
```

**Response 200:**
```json
{
  "triples": [
    {"subject": "project:osa", "predicate": "written-in", "object": "Elixir"}
  ],
  "count": 1
}
```

### POST /assert

**Request:**
```json
{"subject": "user:alice", "predicate": "knows", "object": "user:bob"}
```

**Response 201:**
```json
{"status": "asserted", "subject": "user:alice", "predicate": "knows", "object": "user:bob"}
```

**Response 400** — missing or empty field:
```json
{"error": "invalid_request", "message": "Required fields: subject, predicate, object (non-empty strings)"}
```

### POST /retract

**Request:**
```json
{"subject": "user:alice", "predicate": "knows", "object": "user:bob"}
```

**Response 200:**
```json
{"status": "retracted", "subject": "user:alice", "predicate": "knows", "object": "user:bob"}
```

### POST /sparql

**Request:**
```json
{
  "query": "SELECT ?s ?o WHERE { ?s <knows> ?o }"
}
```

**Response 200:**
```json
{
  "results": [
    {"s": "user:alice", "o": "user:bob"}
  ],
  "count": 1
}
```

**Response 400** — parse error or unsupported query form:
```json
{"error": "sparql_failed", "message": "Expected SELECT, INSERT, or DELETE, got ..."}
```

### POST /reason

No request body required.

**Response 200:**
```json
{"status": "materialized", "inferred": 7}
```

The `inferred` field is the number of rounds executed, not the number of new triples.

### GET /context/:agent_id

**Request:**
```
GET /api/v1/knowledge/context/session-abc123
```

**Response 200:**
```json
{
  "agent_id": "session-abc123",
  "context": "# Knowledge Context (session-abc123)\nFacts: 2\n\n## Properties\n  - role: admin\n\n## Relationships\n  - knows: user:bob"
}
```

### GET /count

**Response 200:**
```json
{"count": 42}
```

---

## Context Injection

The knowledge block is assembled in `Agent.Context.gather_dynamic_blocks/1` and included in the dynamic (per-request, uncached) portion of the system prompt. It has priority 2, meaning it is included after all priority 1 blocks when the token budget permits.

**When it fires:** On every request where `session_id` is set and the `osa_default` store is running.

**What gets injected:** All triples where the subject equals the current `session_id`. This means only facts explicitly asserted for that session ID appear — not the full graph contents.

**Format:** A markdown block rendered by `MiosaKnowledge.Context.to_prompt/1`:

```
# Knowledge Context (<session_id>)
Facts: <n>

## Properties
  - <predicate>: <object>
  ...

## Relationships
  - <predicate>: <object>, <object2>
  ...
```

Properties are triples whose object does not contain `:`. Relationships are triples whose object contains `:` (treated as entity references). This is a heuristic: `"role" → "admin"` becomes a property; `"knows" → "user:bob"` becomes a relationship.

**No facts:** If the store has no triples for the session, the block renders as:
```
# Knowledge Context (<session_id>)
No facts in knowledge graph.
```

This empty block is still included when the budget allows (the empty-check happens at the `gather_dynamic_blocks` level, not before rendering).

To inject facts into an agent's own context, assert triples with the session ID as subject:

```json
{
  "action": "assert",
  "subject": "<session_id>",
  "predicate": "current-task",
  "object": "implementing feature X"
}
```

---

## Learning Bridge

### How patterns become triples

The Learning engine tracks task patterns as frequency counters (how often a given task type has been seen) and solutions as error-type-to-resolution mappings.

Every 60 seconds, `KnowledgeBridge` calls:
```elixir
Learning.patterns()   # => %{"tool_use" => 47, "file_edit" => 31, ...}
Learning.solutions()  # => %{"ModuleNotFoundError" => "run mix deps.get", ...}
```

And asserts:
```
pattern:tool_use     rdf:type       osa:LearnedPattern
pattern:tool_use     osa:frequency  "47"
pattern:file_edit    rdf:type       osa:LearnedPattern
pattern:file_edit    osa:frequency  "31"
error:ModuleNotFoundError  rdf:type       osa:KnownError
error:ModuleNotFoundError  osa:solution   "run mix deps.get"
```

### Querying synced data

```json
{"action": "query", "object": "osa:LearnedPattern"}
```

Returns all subjects typed as `osa:LearnedPattern`.

```json
{
  "action": "sparql",
  "sparql_query": "SELECT ?err ?sol WHERE { ?err <osa:solution> ?sol }"
}
```

Returns all known errors and their solutions.

### Manual sync

```elixir
Daemon.Agent.Memory.KnowledgeBridge.sync_now()
```

Useful in tests or after bulk learning updates.

### Sync is additive, not overwriting

`assert_many` on the ETS backend is idempotent — asserting the same triple again is a no-op. Frequency changes in Learning will update the `osa:frequency` triple only if the value changed. No explicit deletion of stale triples occurs on sync; retract manually if needed.

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         LEARNING ENGINE                             │
│  Agent.Learning — ETS, patterns/solutions from task execution       │
└────────────────────────┬────────────────────────────────────────────┘
                         │  every 60s (KnowledgeBridge.sync_now/0)
                         │  Learning.patterns() + Learning.solutions()
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  KNOWLEDGE BRIDGE                                   │
│  Agent.Memory.KnowledgeBridge                                       │
│  Converts patterns/solutions → triples                              │
│  MiosaKnowledge.assert_many(store, triples)                         │
└────────────────────────┬────────────────────────────────────────────┘
                         │ batch assert
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   KNOWLEDGE STORE  (osa_default)                    │
│  MiosaKnowledge.Store GenServer                                     │
│  ETS backend (3-way SPO/POS/OSP indexing)                           │
└──────┬────────────────────────────────┬──────────────────────────────┘
       │                                │
       │ MiosaKnowledge.query/sparql    │ MiosaKnowledge.assert/retract
       │                                │
┌──────▼──────────┐           ┌─────────▼────────────────────────────┐
│  AGENT CONTEXT  │           │  AGENT TOOL / HTTP API               │
│  knowledge_block│           │  Tools.Builtins.Knowledge (7 actions)│
│  in Context.ex  │           │  Channels.HTTP.API.KnowledgeRoutes   │
│  → system prompt│           │  (7 routes at /api/v1/knowledge/*)   │
└──────┬──────────┘           └──────────────────────────────────────┘
       │
       ▼
┌─────────────────┐
│  AGENT PROMPT   │
│  # Knowledge    │
│  Context (id)   │
│  Facts: N       │
│  ...            │
└─────────────────┘
```

---

## What It Does Not Replace

The four existing knowledge layers are unchanged:

**`Agent.Memory`** — The append-only `tasks/memory.md` file. Long-term, cross-session, human-readable. Knowledge graph does not write here.

**`Agent.Learning`** — The ETS-based pattern and solution tracker updated by the hooks system on every tool use. Learning feeds the knowledge graph (one direction only). The knowledge graph does not write back to Learning.

**`Agent.Memory.Episodic`** — The session event timeline. Tracks what happened (tool calls, results, errors) in order. The knowledge graph tracks what is true (entity relationships), not what happened.

**Session Search** — Semantic similarity search over session history. Query by text; returns relevant past exchanges. The knowledge graph is queried by pattern or SPARQL, not by text similarity.

These layers complement the knowledge graph; they are not alternatives to it. An agent loop can and does use all five simultaneously.
