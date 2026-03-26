# Storage Architecture

Daemon's storage design is driven by two constraints: it must run fully offline on a
developer's laptop with zero external dependencies, and it must scale to fleet-mode
multi-tenant deployments without architectural changes. The result is a layered
architecture where each layer has a clear role and can be used independently.

See `storage-abstractions.md` for the detailed API and usage patterns for each layer.
This document describes the architecture — why each layer exists and how they interact.

---

## The Four Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  BEAM process memory                                            │
│  ┌───────────────────┐  ┌──────────────────────────────────┐   │
│  │  :persistent_term │  │  GenServer state (Agent.Loop)    │   │
│  │  (zero-copy reads)│  │  session_id, messages[], tools[] │   │
│  └───────────────────┘  └──────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  In-process shared memory                                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  ETS tables                                              │  │
│  │  :daemon_cancel_flags  :daemon_hooks  :daemon_rate_limits         │  │
│  │  :daemon_memory_index  :daemon_episodic_memory  :daemon_pending_* │  │
│  └───────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  Filesystem (durable, unstructured)                             │
│  ┌────────────────┐ ┌──────────────┐ ┌──────────────────────┐  │
│  │ JSONL sessions │ │ MEMORY.md    │ │ Vault (.md files)    │  │
│  │ ~/.daemon/sessions│ │ ~/.daemon/      │ │ ~/.daemon/vault/        │  │
│  └────────────────┘ └──────────────┘ └──────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  SQLite (durable, queryable)                                    │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Daemon.Store.Repo (~/.daemon/osa.db)            │ │
│  │  messages  conversations  task_queue  budget_ledger        │ │
│  │  budget_config  treasury  treasury_transactions            │ │
│  └────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│  PostgreSQL (optional, multi-tenant platform only)              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Daemon.Platform.Repo (DATABASE_URL)          │ │
│  │  platform_users  tenants  os_instances  cross_os_grants   │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Layer Responsibilities

### Layer 1: BEAM Process Memory

**Who uses it:** GenServer state in `Agent.Loop`, `Orchestrator`, `SwarmMode`, `Providers.Registry`.

**Contents:** Active session message arrays, running task metadata, current swarm state, provider registry.

**Rationale:** The agent loop builds up a `messages` list over a conversation turn. This list is passed to the LLM on every iteration. It must be directly addressable — no serialization overhead, no async read. GenServer state is the only appropriate place for active conversation context.

**Lifecycle:** Lost on process crash. The `DynamicSupervisor` restarts crashed loops but the in-flight conversation turn cannot be recovered. Completed turns are persisted to JSONL and SQLite before the loop waits for the next message.

### Layer 2: ETS (Hot Shared State)

**Who uses it:** Rate limiter, hook registry, memory index, cancel flags, pending question tracking.

**Contents:** Anything that must be read by multiple processes with microsecond latency.

**Rationale:** The rate limiter (`RateLimiter`) serves every HTTP request and must not block on a GenServer mailbox. The hook system (`Hooks`) runs in the caller's process context and needs lock-free reads. The cancel flag table (`:daemon_cancel_flags`) is checked at every agent loop iteration — a GenServer round-trip here would add 10–50µs per iteration, accumulated over 30 iterations per turn.

**ETS table catalog:**

| Table | Owner | Access | Contents |
|---|---|---|---|
| `:daemon_cancel_flags` | Application | public set | `{session_id, true}` cancellation markers |
| `:daemon_hooks` | `Agent.Hooks` | public bag, read_concurrency | Hook registrations `{event_type, ref, fn}` |
| `:daemon_hooks_metrics` | `Agent.Hooks` | public set, write_concurrency | Hook timing counters |
| `:daemon_rate_limits` | `RateLimiter` | public set, write_concurrency | `{ip, token_count, last_refill_seconds}` |
| `:daemon_memory_index` | `MiosaMemory.Store` | public set | Keyword → entry_id inverted index |
| `:daemon_memory_entries` | `MiosaMemory.Store` | public set | Entry ID → memory entry struct |
| `:daemon_episodic_memory` | `Memory.Episodic` | public bag | Per-session event records |
| `:daemon_integrity_nonces` | `HTTP.Integrity` | public set | `{nonce, timestamp_seconds}` replay prevention |
| `:daemon_survey_answers` | `SessionRoutes` | public set | `{{session_id, survey_id}, answers}` |
| `:daemon_pending_questions` | Loop | public set | `{ref, %{session_id, question, options}}` |

### Layer 3: Filesystem (Durable Unstructured)

**Who uses it:** `MiosaMemory.Store` (sessions, MEMORY.md), `Vault.Store` (vault entries), `Tools.Registry` (SKILL.md files).

**Contents:** Human-readable data that may be edited outside Daemon.

**Rationale:** Conversation history as JSONL allows incremental append without locking. MEMORY.md is markdown so operators can read and edit it directly. Vault entries are markdown with YAML frontmatter so they are both machine-parseable and human-readable. SKILL.md files can be written by the agent or by a developer — the same file format serves both cases.

**Dual-write for messages:** Every message is written to both JSONL (via `MiosaMemory.Store`) and SQLite (via `Memory.SQLiteBridge`). JSONL is the primary store; SQLite provides queryable secondary access. If SQLite write fails, a warning is logged but the JSONL write proceeds — JSONL is authoritative for conversation history.

**Memory index rebuild:** On startup, `MiosaMemory.Store` reads `MEMORY.md` and builds the ETS keyword index. The index is rebuilt after each `remember/2` or `archive/1` call. If the process restarts, the index is rebuilt from the markdown file — the file is the source of truth.

### Layer 4: SQLite (Durable Queryable)

**Who uses it:** `Memory.SQLiteBridge` (messages), `Tasks.Queue` (task_queue), `Budget` (budget_ledger), `Treasury` (treasury).

**Contents:** Structured data that needs SQL queries, aggregation, or indexing.

**Rationale:** JSONL cannot be queried efficiently. Budget aggregation (total cost by provider, by session, by day) requires SQL. The task queue uses `leased_until` timestamps and `status` to implement at-least-once delivery semantics — these require atomic updates that JSONL cannot provide.

**WAL mode:** SQLite is configured in Write-Ahead Logging mode (`journal_mode: :wal`). WAL allows concurrent readers during a write — critical because session load (`Memory.load_session`) can happen while the agent loop is writing new messages to the same session.

**Pool size:** 5 connections (`pool_size: 5`). SQLite with WAL supports concurrent reads from multiple connections. Writes serialize internally. 5 connections is sufficient for the expected local concurrency.

### Layer 5: PostgreSQL (Platform Only)

**Who uses it:** `Platform.Repo` and all platform schema modules.

**Contents:** Multi-tenant identity, tenancy, and OS instance data.

**Rationale:** Multi-tenant data requires foreign key integrity, row-level security, and horizontal scaling that SQLite cannot provide. PostgreSQL is activated only when `DATABASE_URL` is set. All core agent functionality uses SQLite — PostgreSQL adds the platform layer on top.

---

## Data Flow: A Message Through the Layers

```
User message arrives (HTTP or channel)
        │
        ▼
NoiseFilter.check/2  ──── filtered? ──── return ACK (no persistence)
        │ pass
        ▼
Loop GenServer state updated (Layer 1)
messages = messages ++ [%{role: "user", content: "..."}]
        │
        ▼
MiosaMemory.Store.append/2 (dual write)
        ├── JSONL file append → ~/.daemon/sessions/{id}.jsonl  (Layer 3)
        └── Memory.SQLiteBridge.append/2 → messages table (Layer 4)
        │
        ▼
LLM called (provider API, external)
        │
        ▼
Response added to Loop GenServer state (Layer 1)
        │
        ▼
MiosaMemory.Store.append/2 (dual write, assistant response)
        ├── JSONL append (Layer 3)
        └── SQLite insert (Layer 4)
        │
        ▼
Events emitted to Bus → PubSub → SSE clients
```

---

## Vault Architecture

The Vault is a separate structured memory system layered on top of the filesystem:

```
Daemon.Vault (facade)
        │
        ├── Vault.Store        → filesystem read/write (Layer 3)
        │   ~/.daemon/vault/{category}/{slug}.md
        │
        ├── Vault.FactExtractor → extracts factual claims from content
        │
        ├── Vault.FactStore    → persists extracted facts (in-memory map)
        │
        ├── Vault.Observer     → buffers observations per session
        │
        ├── Vault.ContextProfile → builds prompt-injection context strings
        │
        ├── Vault.SessionLifecycle → wake/sleep/checkpoint lifecycle
        │   checkpoints → ~/.daemon/vault/.vault/checkpoints/{session_id}.md
        │
        └── Vault.Inject       → keyword-matched auto-injection into prompts
```

Each vault memory is a self-contained markdown file. The slug is a URL-safe version of the title. Files in `.vault/` are internal state not shown to users.

---

## Storage Decision Guide

| Situation | Use |
|---|---|
| Active conversation messages | GenServer state (`Agent.Loop`) |
| Data read on every HTTP request (rate limits) | ETS |
| Data read on every loop iteration (cancel flags, tool list) | ETS or `:persistent_term` |
| Rarely-changing config loaded at boot | `:persistent_term` |
| Conversation history (append + full scan) | JSONL + SQLite dual-write |
| Structured queries (budget, task status) | SQLite via Ecto |
| Human-readable memories (editable outside Daemon) | Filesystem markdown |
| Multi-tenant identity and access control | PostgreSQL (platform only) |
