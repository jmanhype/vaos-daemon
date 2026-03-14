# Understanding ETS and persistent_term

OSA stores several categories of data in memory structures that are built into
the BEAM runtime itself: ETS tables and `persistent_term`. Neither requires a
database, a network call, or serialization. Reads happen in microseconds.

This guide explains what these structures are, why OSA uses them, and exactly
which data lives in each one.

---

## What is ETS?

ETS stands for Erlang Term Storage. It is a key-value store built into the BEAM
virtual machine. You can think of it as a concurrent in-memory hash map that
multiple processes can read and write simultaneously.

Key properties:

- **In-process storage**: Data lives in the VM's memory, not a database.
- **Named tables**: You reference a table by an atom name, like `:osa_cancel_flags`.
- **Concurrent reads**: Multiple processes can read the same table simultaneously
  with no locking required (for `read_concurrency: true` tables).
- **Configurable write semantics**: `:set` (one value per key), `:bag` (multiple
  values per key), `:ordered_set` (sorted keys).
- **Public/protected/private**: Controls which processes can access the table.

ETS tables persist for the lifetime of the process that created them, or until
explicitly deleted. They do not survive a node restart.

---

## Why Not Just Use a Database?

A natural question: OSA has SQLite (`Store.Repo`) for persistent storage. Why
not use that for everything?

The answer is latency. A SQLite query, even on a local file, involves:

1. File I/O or OS page cache lookup
2. SQL parsing and planning
3. B-tree traversal
4. Result serialization

That is typically 0.1–10 milliseconds per query. For data that changes thousands
of times per second — like cancel flags that every active agent loop checks on
each iteration — that latency adds up fast.

ETS lookups take microseconds. No network, no disk, no serialization. The data
is just a memory address lookup in the VM's tables.

---

## ETS vs GenServer State

Another option for shared state is a GenServer. A GenServer holds its state in
the process heap and allows other processes to read it via `GenServer.call`.

The problem is that GenServer calls are serialized. If 100 concurrent agent
sessions all need to read the same GenServer's state, they queue up. The GenServer
becomes a bottleneck.

ETS solves this with concurrent reads. With `read_concurrency: true`, any number
of processes can read the same ETS table simultaneously, with no queuing.

The pattern OSA uses throughout:

- **Reads**: go directly to ETS (concurrent, microsecond latency)
- **Writes**: go through a GenServer (serialized, ensures consistency)

The GenServer is the single writer that updates ETS; everyone else reads ETS
directly.

---

## ETS Tables in OSA

OSA creates all its ETS tables during application startup, before the supervision
tree begins, to guarantee they exist before any process needs them.

### `:osa_cancel_flags`

```elixir
:ets.new(:osa_cancel_flags, [:named_table, :public, :set])
```

Tracks which agent sessions have been cancelled. When a user sends a cancellation
request, the HTTP handler writes `{session_id, true}` to this table. The agent
loop checks this table on every iteration — if the flag is set, the loop stops
cleanly.

This must be a public ETS table (not a GenServer) because the loop and the HTTP
handler run in different processes. It must be read on every iteration, so
microsecond latency matters.

### `:osa_files_read`

```elixir
:ets.new(:osa_files_read, [:named_table, :public, :set])
```

Tracks which files have been read by which session. The pre-tool-use hook checks
this before allowing a file write: if a session tries to write a file it has
not read first, the hook nudges the agent to read before writing. This prevents
blind overwrites.

### `:osa_survey_answers`

```elixir
:ets.new(:osa_survey_answers, [:set, :public, :named_table])
```

When the agent's `ask_user_question` tool sends a question to the user, the
agent loop polls this table waiting for an answer. The HTTP endpoint writes the
answer here when the user responds. The loop reads it and continues.

### `:osa_context_cache`

```elixir
:ets.new(:osa_context_cache, [:set, :public, :named_table])
```

Caches the context window size for each Ollama model. Every time a new session
starts with Ollama, OSA would normally call Ollama's `/api/show` endpoint to ask
"how many tokens can this model handle?" That is a network round-trip. Since the
context size never changes without re-pulling the model, OSA caches the result
here and skips the network call on subsequent sessions.

### `:osa_survey_responses`

```elixir
:ets.new(:osa_survey_responses, [:bag, :public, :named_table])
```

Stores survey and waitlist form responses when the platform database is not
enabled. Uses `:bag` (multiple values per key) because multiple responses can
exist. Rows are `{unique_integer, body_map, datetime}`.

### `:osa_session_provider_overrides`

```elixir
:ets.new(:osa_session_provider_overrides, [:named_table, :public, :set])
```

Stores per-session provider and model overrides set via the hot-swap API. When
an operator calls `PUT /sessions/:id/provider` to switch a running session from
Anthropic to Groq mid-conversation, the new provider is stored here. The agent
loop reads this table to resolve which provider to use for each LLM call.

### `:osa_pending_questions`

```elixir
:ets.new(:osa_pending_questions, [:named_table, :public, :set])
```

Tracks questions where the agent is currently blocked waiting for a human answer.
The `GET /sessions/:id/pending_questions` endpoint reads this table to show the
frontend which questions are outstanding.

### `:osa_event_handlers` (created by Events.Bus)

Created by the event bus during its `init`. Stores registered event handlers as
`{event_type, ref, handler_fn}` tuples. When an event fires, goldrush calls
`dispatch_event/1`, which looks up handlers from this table and calls each one.

---

## What is `persistent_term`?

`persistent_term` is a different kind of storage introduced in Erlang/OTP 21. It
stores global, immutable terms that are shared across all processes without
copying.

With ETS, reading a value copies it from the ETS table into the calling process's
heap. With `persistent_term`, the value is stored once in a shared memory region
and processes can read it with no copying at all. This makes it even faster than
ETS for large immutable values that are read very frequently.

The tradeoff: `persistent_term` is designed for values that rarely change. Writing
to `persistent_term` triggers a global garbage collection pass on all processes
in the VM. You would never use it for data that changes frequently — that is what
ETS is for.

The rule: use `persistent_term` for data that is written once at boot and read
constantly thereafter.

---

## `persistent_term` in OSA

### System prompts and prompt templates

```elixir
# From PromptLoader.load/0 — called at application startup
:persistent_term.put({OptimalSystemAgent.PromptLoader, :SYSTEM}, content)
:persistent_term.put({OptimalSystemAgent.PromptLoader, :SOUL}, content)
```

OSA loads prompt templates from `~/.osa/prompts/` and `priv/prompts/` at boot
and stores them in `persistent_term`. Every agent session reads the system prompt
for every LLM call. With thousands of calls per day, avoiding even a microsecond
of copying adds up. Prompts are immutable at runtime (they can be reloaded with
`PromptLoader.load/0`, but that is an operator action, not a hot path).

### Tool registry

```elixir
# From Tools.Registry — stores built-in tool list without the GenServer lock
:persistent_term.put({OptimalSystemAgent.Tools.Registry, :builtin_tools}, tools_map)
:persistent_term.put({OptimalSystemAgent.Tools.Registry, :mcp_tools}, mcp_map)
```

The tool registry has a `list_tools_direct/0` function that reads from
`persistent_term` instead of calling the GenServer. This matters inside
orchestration callbacks: if the orchestrator calls the GenServer that manages
tools, and that GenServer also calls the orchestrator, you get a deadlock.
`persistent_term` breaks the cycle — it is a lock-free read with no GenServer
involved.

### Classifier LLM prompt

```elixir
# From Signal.Classifier
:persistent_term.get({OptimalSystemAgent.PromptLoader, :classifier}, @fallback)
```

The signal classifier prompt is read for every incoming message to classify it.
Storing it in `persistent_term` means zero allocation on this hot path.

---

## The Pattern: ETS for Hot Reads, GenServer for Writes

To summarize how OSA uses these three storage options together:

| Data type | Storage | Why |
|---|---|---|
| Session cancel flags | ETS | Written rarely, read on every loop iteration |
| Provider overrides | ETS | Written rarely (per operator action), read on every LLM call |
| File read tracking | ETS | Written per tool call, read before each write |
| System prompts | persistent_term | Written once at boot, read on every LLM call |
| Tool list | persistent_term | Written at boot + registration, read in hot paths |
| Agent conversation history | GenServer state | Written and read in sequence by one process |
| Long-term memories | SQLite (Store.Repo) | Persist across restarts, searched semantically |
| Knowledge graph | Mnesia | Distributed, queryable, survives restarts |

The guiding principle: the closer data is to the execution hot path, the faster
the storage needs to be. ETS and `persistent_term` exist at one extreme. A
PostgreSQL database exists at the other. OSA puts each piece of data in the right
place.

---

## Next Steps

Read [goldrush-events.md](./goldrush-events.md) to see how OSA routes events,
tool calls, and provider requests through compiled BEAM bytecode modules — a
technique that takes speed even further than ETS lookups.
