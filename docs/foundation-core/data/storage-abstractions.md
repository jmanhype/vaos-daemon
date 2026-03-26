# Storage Abstractions

Audience: contributors working on the agent loop, memory system, or any
component that reads or writes persistent or cached data.

Daemon uses four distinct storage abstractions, each chosen for different
access patterns. Understanding which layer to use for a given piece of data
is critical to both correctness and performance.

---

## Overview

| Layer | Technology | Access Pattern | Durability | Typical Contents |
|---|---|---|---|---|
| Hot cache | ETS | Lock-free reads, concurrent writes | In-memory (lost on crash) | Cancel flags, context cache, hooks, metrics |
| Zero-copy config | `:persistent_term` | Lock-free reads, infrequent writes | In-memory (lost on crash) | Soul prompt, static config, provider configs |
| Durable local storage | SQLite (Ecto) | Transactional reads/writes | Durable (survives restart) | Messages, budget ledger, task queue |
| Append-only logs | JSONL files | Sequential appends, full scans | Durable (file system) | Sessions, learning, episodic memory |
| Filesystem | Files | OS file I/O | Durable | Skills, vault, commands, sessions |

---

## ETS (Hot Data)

ETS (Erlang Term Storage) tables are in-memory hash tables accessible from
any process. Daemon uses ETS for data that must be read at high frequency with
minimal latency.

### Tables and Their Contents

| Table | Type | Contents |
|---|---|---|
| `:daemon_cancel_flags` | `set` | `{session_id, true}` entries for in-progress loop cancellation. Written by `Agent.Loop.cancel/1`, read at each loop iteration. |
| `:daemon_hooks` | `bag, read_concurrency: true` | Hook entries `{event_type, ref, handler_fn}`. Written by `Hooks.register/4`, read by `Hooks.run/2` in caller's process. |
| `:daemon_hooks_metrics` | `set, write_concurrency: true` | Atomic counters for hook timing. Written after each hook execution. |
| `:daemon_event_handlers` | `bag, public` | Event bus handler entries `{event_type, ref, handler_fn}`. Written by `Events.Bus.register_handler/2`. |
| Context cache | Application-specific | Compiled context maps per session (built context avoids recomputation). |
| Provider overrides | Application-specific | Per-session provider or model overrides set during a session. |
| Survey answers | Application-specific | Buffered answers to `ask_user` prompts before returning to the loop. |

### Usage Pattern

```elixir
# Writing to ETS (e.g. cancel flag)
:ets.insert(:daemon_cancel_flags, {session_id, true})

# Reading from ETS (lock-free, concurrent)
case :ets.lookup(:daemon_cancel_flags, session_id) do
  [{^session_id, true}] -> :cancel
  []                    -> :continue
end

# Deleting from ETS
:ets.delete(:daemon_cancel_flags, session_id)
```

### ETS Table Creation

Tables are created by the owning GenServer during `init/1`. The owning
process must be started before any reader tries to access the table.

```elixir
# In Hooks.init/1:
:ets.new(:daemon_hooks, [:named_table, :bag, :public, read_concurrency: true])
```

Named public tables (`:public`) are accessible from any process. The owning
process is responsible for cleanup but other processes can read and write
without message passing.

---

## :persistent_term (Zero-Copy Config)

`:persistent_term` stores immutable or rarely-changing data that is read
on every agent turn. Unlike ETS, reads are zero-copy — the term is returned
by reference, not copied to the reader's heap.

### Contents

| Key | Content |
|---|---|
| `{Tools.Registry, :builtin_tools}` | Map of `name → module` for all registered tool modules |
| `{Tools.Registry, :skills}` | Map of `name → skill_map` for loaded SKILL.md skills |
| `{Tools.Registry, :tools}` | Compiled tool list (for LLM schema) |
| `{Tools.Registry, :mcp_tools}` | Map of `prefixed_name → mcp_info` for MCP server tools |
| Soul prompt | The agent's soul/system prompt string, loaded at boot |
| Static context base | Baseline context string injected into every session |
| Provider configs | API base URLs, default models per provider |
| `:daemon_dev_secret` | Ephemeral JWT secret (when `DAEMON_SHARED_SECRET` is unset) |

### Usage Pattern

```elixir
# Write (only during startup or explicit reload — avoid at runtime)
:persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools_map)

# Read (zero-copy, any process, no locking)
builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

# Read with default (safe if key may not exist)
config = :persistent_term.get({__MODULE__, :config}, %{})
```

### When Not to Use :persistent_term

- Do not store mutable data. `:persistent_term` updates trigger a full
  garbage collection of all processes that have a copy of the old term.
  This is catastrophic for high-frequency updates.
- Do not store per-session data. Session state belongs in ETS or the
  GenServer state of `Agent.Loop`.
- Do not store large terms that change frequently. The GC cost is proportional
  to the number of processes with references to the old term.

---

## SQLite (Durable Local Storage)

SQLite via `ecto_sqlite3` provides ACID-compliant durable storage for data
that must survive process restarts.

**Repo:** `Daemon.Store.Repo`
**Database:** `~/.daemon/osa.db`

### Access Pattern

All database access goes through Ecto — never raw SQL strings in application
code. Use `Repo.all/1`, `Repo.get/2`, `Repo.insert/1`, `Repo.update/1`.

```elixir
alias Daemon.Store.{Repo, Message}
import Ecto.Query

# Insert a message
{:ok, message} = Repo.insert(Message.changeset(%{
  session_id: "ses_abc",
  role:       "user",
  content:    "Hello"
}))

# Query messages for a session
messages =
  from(m in Message,
    where: m.session_id == ^session_id,
    order_by: [asc: m.inserted_at]
  )
  |> Repo.all()

# Full-text search via FTS5
results =
  Repo.all(from m in "sessions_fts",
    where: fragment("sessions_fts MATCH ?", ^query),
    select: %{session_id: m.session_id, content: m.content}
  )
```

### Configuration

```elixir
config :daemon, Daemon.Store.Repo,
  database:     "~/.daemon/osa.db",
  pool_size:    5,
  journal_mode: :wal,      # WAL mode for concurrent reads
  cache_size:   -64_000,   # 64MB page cache
  foreign_keys: true,
  custom_pragmas: [encoding: "'UTF-8'"]
```

WAL mode allows concurrent readers during a write, which is important for
sessions that are reading history while the agent loop is writing new messages.

### UTF-8 Enforcement

The Repo `init/2` callback always applies `PRAGMA encoding = 'UTF-8'`
regardless of config overrides. Message content is additionally validated
and sanitized at the changeset level in `Store.Message`.

---

## JSONL (Append-Only Logs)

JSONL files provide durable append-only storage for streaming data where
the full history may need to be scanned but the common operation is append.

### Session Files

```
~/.daemon/sessions/<session_id>.jsonl
```

Each line is one conversation turn (message entry). The agent memory system
reads these files on session resume and maintains an in-memory ETS index
for keyword-based recall.

```elixir
# Append a turn to session history (in MiosaMemory.Store)
entry_line = Jason.encode!(entry) <> "\n"
File.write!(session_path, entry_line, [:append])
```

### Memory File

```
~/.daemon/memory.jsonl
```

Long-term cross-session memories. One entry per `remember/2` call.

```elixir
# Read all memories
entries =
  "~/.daemon/memory.jsonl"
  |> Path.expand()
  |> File.stream!()
  |> Enum.flat_map(fn line ->
    case Jason.decode(String.trim(line)) do
      {:ok, entry} -> [entry]
      _            -> []
    end
  end)
```

### Learning Files

```
~/.daemon/learning/
├── interactions.jsonl   # Observed patterns from successful interactions
├── corrections.jsonl    # User-provided corrections
└── errors.jsonl         # Tool errors for pattern analysis
```

---

## Filesystem (Structured Directories)

Daemon uses the filesystem for human-authored content and large binary assets.

### Directory Layout

```
~/.daemon/
├── skills/                    # Custom SKILL.md files
│   └── <skill-name>/
│       └── SKILL.md
│
├── commands/                  # Custom slash commands
│   └── <command>.md
│
├── vault/                     # Knowledge vault entries
│   └── <entry>.md
│
├── sessions/                  # JSONL conversation logs (see above)
│
├── workspace/                 # Default working directory for shell_execute
│
├── mcp.json                   # MCP server configuration
├── .env                       # Environment variables (gitignored)
└── osa.db                     # SQLite database
```

### File Access Conventions

- Always use `Path.expand/1` to resolve `~` in paths.
- Always call `File.mkdir_p/1` before writing to ensure the directory exists.
- Skills loaded from `priv/skills/` (built-in) take lower priority than
  skills in `~/.daemon/skills/` (user). The Tools.Registry merges both with
  user skills overriding built-ins of the same name.

```elixir
skills_dir = Path.expand("~/.daemon/skills")
File.mkdir_p!(skills_dir)

skill_path = Path.join([skills_dir, skill_name, "SKILL.md"])
File.write!(skill_path, content)
```

---

## Choosing the Right Layer

Use this decision tree when adding a new piece of data:

```
Does it need to survive process restart?
├── YES → Does it need to be queried by field value?
│         ├── YES → SQLite (Ecto)
│         └── NO  → Is it append-only streaming data?
│                   ├── YES → JSONL file
│                   └── NO  → Filesystem (markdown/config file)
│
└── NO  → Is it read on every agent turn (hot path)?
          ├── YES → Is it static or changes very rarely?
          │         ├── YES → :persistent_term
          │         └── NO  → ETS
          └── NO  → ETS (or GenServer state if owned by one process)
```
