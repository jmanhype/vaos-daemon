# Memory Store

Primary memory system for OSA. Manages conversation session history and long-term cross-session storage via the `miosa_memory` package.

## Two Storage Planes

| Plane | Module | Scope | Format |
|-------|--------|-------|--------|
| Session | `MiosaMemory.Session` + `SQLiteBridge` | Per-session messages | JSONL + SQLite |
| Long-term | `MiosaMemory.Store.ETS` | Cross-session collections | ETS + optional JSON |

---

## Session Storage (Layer 1)

`MiosaMemory.Session` is a per-session GenServer registered via `MiosaMemory.SessionRegistry`. It holds the full ordered message list in memory and persists it as JSONL on demand or on an auto-persist schedule.

### Session Lifecycle

```
start_session/1
    └─ DynamicSupervisor.start_child(MiosaMemory.SessionSupervisor, ...)
       └─ GenServer.start_link — registered as {:via, Registry, {SessionRegistry, session_id}}

add_message/3
    └─ appends %{role, content, timestamp} to state.messages
    └─ auto-persists every `auto_persist_interval` messages (default: 10)

persist/1
    └─ writes JSONL to ~/.miosa/sessions/<session_id>/messages.jsonl

load/1
    └─ starts session if not running, reads JSONL from disk

stop/1
    └─ GenServer.stop — process exits, session remains on disk
```

### JSONL Format

Each line in `messages.jsonl` is one JSON object:

```json
{"role": "user",      "content": "Fix the timeout bug",         "timestamp": "2026-03-08T10:00:00Z"}
{"role": "assistant", "content": "Looking at the connection...", "timestamp": "2026-03-08T10:00:05Z"}
{"role": "tool",      "content": "...",                         "timestamp": "2026-03-08T10:00:07Z"}
```

Valid roles: `user`, `assistant`, `system`, `tool`.

### Session Summary

`summarize/1` returns a compact string for display: the first system message (if present), an omission count if messages were skipped, and the last 5 messages truncated to 200 characters each.

```
[system] You are OSA, an AI agent...
... (42 messages omitted) ...
[user] Run the tests
[assistant] Running mix test...
```

### Session API

```elixir
MiosaMemory.Session.start_session(session_id)
MiosaMemory.Session.add_message(session_id, :user, "Hello")
MiosaMemory.Session.messages(session_id)         # all messages
MiosaMemory.Session.messages(session_id, 10)     # last 10
MiosaMemory.Session.summarize(session_id)
MiosaMemory.Session.persist(session_id)
MiosaMemory.Session.load(session_id)
MiosaMemory.Session.stop(session_id)
```

All calls other than `start_session/1` and `load/1` are `GenServer.call` to the registered process.

---

## SQLite Secondary Store (Dual-Write)

`OptimalSystemAgent.Agent.Memory.SQLiteBridge` implements a secondary store contract consumed by `MiosaMemory.Store`. It writes every session message to SQLite via Ecto, enabling SQL-level queries across sessions.

Configured via:

```elixir
config :miosa_memory, secondary_store: OptimalSystemAgent.Agent.Memory.SQLiteBridge
```

### SQLiteBridge Contract

| Function | Description |
|----------|-------------|
| `append/2` | Writes one message entry to the `messages` table |
| `load/1` | Reads all messages for a session ordered by `inserted_at`; returns `nil` (triggers JSONL fallback) if table is empty or Repo is unavailable |
| `search_messages/2` | SQLite `LIKE` search across `content` column, returns results with session metadata |
| `session_stats/1` | Aggregated statistics: message count, total tokens, first/last timestamps, per-role counts |

### Fallback Behavior

`load/1` returns `nil` on any Ecto error. The caller (`MiosaMemory.Store`) falls back to JSONL in that case. Errors from `append/2` are logged at `warning` level and return `:ok` — they never crash the session process.

### UTF-8 Normalization

`append/2` normalizes all content through `ensure_utf8/1` before writing. Partial or invalid UTF-8 sequences are truncated to the last valid codepoint using `:unicode.characters_to_binary/3`.

---

## Long-term Store (Layer 2)

`MiosaMemory.Store.ETS` is a `GenServer` that owns two named ETS tables:

| Table | Key | Contents |
|-------|-----|----------|
| `:miosa_memory_store` | `{collection, key}` | `entry` structs |
| `:miosa_memory_collections` | `collection` | existence flag |

Both tables are `:public` with `read_concurrency: true`, so reads bypass the GenServer and hit ETS directly.

### Entry Structure

```elixir
%{
  key: "arch-001",
  value: %{title: "Use ETS", reason: "Fast local access"},
  metadata: %{
    created_at: ~U[2026-03-08 10:00:00Z],
    updated_at: ~U[2026-03-08 10:00:00Z],
    access_count: 3,
    tags: ["architecture", "storage"]
  }
}
```

`access_count` increments and `updated_at` refreshes on every `get/2` call.

### Collections

A collection is a named namespace for entries. The learning engine uses `"patterns"`, `"solutions"`, and `"errors"`. Episodic memory uses `"episodic"`. User-facing memory commands write to named collections like `"decisions"` or `"context"`.

### Storage API (via `MiosaMemory`)

```elixir
# Store
MiosaMemory.store("decisions", "arch-001", %{title: "Use ETS"}, tags: ["architecture"])

# Recall by key
{:ok, entry} = MiosaMemory.recall("decisions", "arch-001")

# Keyword search within a collection
{:ok, matches} = MiosaMemory.search("decisions", "ETS performance")

# Delete
MiosaMemory.forget("decisions", "arch-001")

# List all collections
{:ok, collections} = MiosaMemory.collections()
```

The `search/2` function lowercases the query, splits on whitespace, and matches entries where any term appears in the entry's key, value (converted to string), or tags. Results are sorted by `updated_at` descending.

### Disk Persistence

When `persist: true` is configured, every `put/4` and `delete/3` triggers an async `GenServer.cast` that serializes the affected collection to `<persist_path>/<collection>.json`. At startup, all `.json` files in `persist_path` are loaded back into ETS.

```
~/.miosa/store/
├── decisions.json
├── patterns.json
├── solutions.json
└── episodic.json
```

Each file is a JSON array of entry objects with ISO 8601 timestamps.

### Export / Import

```elixir
# Export a collection to a file
MiosaMemory.export("decisions", "/path/to/export.json")

# Import entries from a file (merges into existing collection)
MiosaMemory.import_collection("decisions", "/path/to/export.json")
```

---

## Context Assembly

`MiosaMemory.Context` builds the message list passed to the LLM. Three strategies:

| Strategy | Behavior |
|----------|----------|
| `:recent` | Last N messages from session (default N=50) |
| `:relevant` | Last N messages + memories injected as system messages (keyword search) |
| `:summary` | Old messages summarized via `Compactor`, recent messages kept verbatim |

```elixir
{:ok, context} = MiosaMemory.Context.build_context(session_id,
  strategy: :relevant,
  max_tokens: 100_000,
  collections: ["decisions", "patterns"],
  query: "database connection pool"
)
```

Token budget is enforced by `trim_to_budget/2` using a ~4 characters/token heuristic.

Memory injections appear as system-role entries prefixed with `[memory:<key>]`.

---

## OSA Agent Alias

`OptimalSystemAgent.Agent.Memory` delegates to `MiosaMemory.Store`. It is the stable OSA-scoped API surface; callers should use it rather than calling `MiosaMemory.Store` directly.

```elixir
# Session operations
OptimalSystemAgent.Agent.Memory.append(session_id, entry)
OptimalSystemAgent.Agent.Memory.load_session(session_id)
OptimalSystemAgent.Agent.Memory.resume_session(session_id)
OptimalSystemAgent.Agent.Memory.list_sessions()
OptimalSystemAgent.Agent.Memory.session_stats(session_id)

# Long-term memory
OptimalSystemAgent.Agent.Memory.remember(content, category)   # store to "general"
OptimalSystemAgent.Agent.Memory.recall()                       # list all
OptimalSystemAgent.Agent.Memory.recall_relevant(message)       # keyword match
OptimalSystemAgent.Agent.Memory.search(query, opts)

# Maintenance
OptimalSystemAgent.Agent.Memory.archive(max_age_days)          # remove old entries
OptimalSystemAgent.Agent.Memory.memory_stats()
```

## See Also

- [overview.md](./overview.md) — 5-layer architecture diagram
- [episodic.md](./episodic.md) — Episodic event recording built on top of this store
- [learning.md](./learning.md) — Learning engine that writes patterns and solutions to this store
- [taxonomy.md](./taxonomy.md) — Classification applied to entries at write time
