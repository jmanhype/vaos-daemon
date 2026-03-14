# Application Lifecycle

This document describes the startup and shutdown sequence for the OSA OTP application.

---

## Startup Sequence

### Phase 0 — Pre-supervisor initialization

`OptimalSystemAgent.Application.start/2` runs before any supervisor is started. This phase
establishes all ETS tables that must exist before any child process attempts to use them.

**ETS tables created:**

| Table | Type | Purpose |
|---|---|---|
| `:osa_cancel_flags` | `set, public` | Per-session loop cancel flags. `Agent.Loop.cancel/1` and the run loop read/write concurrently. |
| `:osa_files_read` | `set, public` | Per-session file read tracking. The `read_before_write` hook checks this before file edits. |
| `:osa_survey_answers` | `set, public` | Survey answers from the HTTP endpoint. `Agent.Loop.ask_user_question/4` polls this. |
| `:osa_context_cache` | `set, public` | Ollama model context window size cache. Avoids repeated `/api/show` HTTP calls. |
| `:osa_survey_responses` | `bag, public` | Survey/waitlist responses when Platform DB is disabled. |
| `:osa_session_provider_overrides` | `set, public` | Per-session provider/model hot-swap overrides. |
| `:osa_pending_questions` | `set, public` | Tracks pending `ask_user` questions for `GET /sessions/:id/pending_questions`. |

**Soul and prompt loading:**

```elixir
OptimalSystemAgent.Soul.load()
OptimalSystemAgent.PromptLoader.load()
```

`Soul.load/0` reads `SYSTEM.md` (and any configured personality overlays), interpolates
`{{TOOL_DEFINITIONS}}`, `{{RULES}}`, and `{{USER_PROFILE}}` placeholders, and stores the result
in `:persistent_term` as the static base for `Agent.Context`. This runs synchronously before the
supervisor tree starts so no agent can begin a session before its identity is initialized.

`PromptLoader.load/0` reads prompt template files from `priv/prompts/` into `:persistent_term`.

---

### Phase 1 — Platform.Repo (conditional)

```
[OptimalSystemAgent.Platform.Repo]   # only if platform_enabled == true
```

When `DATABASE_URL` is set and `platform_enabled` is configured, the Ecto PostgreSQL repository
starts first. This ensures platform-level data (user profiles, organization settings) is available
to any subsequent child that queries it during `init/1`.

If `platform_enabled` is false (the default for single-user deployments), this phase is skipped
entirely.

---

### Phase 2 — TaskSupervisor

```
{Task.Supervisor, name: OptimalSystemAgent.TaskSupervisor}
```

A general-purpose `Task.Supervisor` for fire-and-forget async work: HTTP message dispatch,
background learning writes, and webhook delivery. This is separate from `Events.TaskSupervisor`
(which lives inside the Infrastructure subsystem and is dedicated to event handler dispatch).

---

### Phase 3 — Infrastructure Subsystem

```
OptimalSystemAgent.Supervisors.Infrastructure   # rest_for_one
```

Children start in strict order (see [component-model.md](./component-model.md) for details):

1. **SessionRegistry** — process registry for agent sessions
2. **Events.TaskSupervisor** — task pool for event handler dispatch (max 100 children)
3. **Phoenix.PubSub** — in-process pub/sub backbone
4. **Events.Bus** — compiles `:osa_event_router` goldrush module, creates `:osa_event_handlers` ETS
5. **Events.DLQ** — creates `:osa_dlq` ETS table, schedules retry tick
6. **Bridge.PubSub** — bridges Bus → PubSub topics
7. **Store.Repo** — Ecto SQLite3 repository (runs Ecto migrations if needed)
8. **EventStream** — SSE circular buffer for Command Center
9. **Telemetry.Metrics** — subscribes to `system_event` on Events.Bus
10. **MiosaLLM.HealthChecker** — initializes provider circuit breakers
11. **MiosaProviders.Registry** — compiles `:osa_provider_router`, registers configured providers
12. **Tools.Registry** — loads 40 built-in tools, scans `priv/skills/` and `~/.osa/skills/`, compiles `:osa_tool_dispatcher`, stores in `:persistent_term`
13. **Tools.Cache** — creates tool result cache ETS
14. **Machines** — discovers OS templates from config
15. **Commands** — loads built-in slash commands and user commands from `~/.osa/commands/`
16. **OS.Registry** — initializes OS template connection tracking
17. **MCP.Registry** — process registry for MCP server name lookup
18. **MCP.Supervisor** — DynamicSupervisor for per-server MCP GenServers (no children yet)

---

### Phase 4 — Sessions Subsystem

```
OptimalSystemAgent.Supervisors.Sessions   # one_for_one
```

1. **Channels.Supervisor** — DynamicSupervisor for channel adapters (no adapters started yet)
2. **EventStreamRegistry** — Registry for per-session event stream GenServer PIDs
3. **SessionSupervisor** — DynamicSupervisor for `Agent.Loop` processes (no sessions yet)

---

### Phase 5 — AgentServices Subsystem

```
OptimalSystemAgent.Supervisors.AgentServices   # one_for_one
```

All 15 agent service GenServers start in order:

1. `Agent.Memory` — creates memory store, loads persisted memories from SQLite
2. `Agent.HeartbeatState` — initializes session liveness ETS
3. `Agent.Tasks` — creates task queue state
4. `MiosaBudget.Budget` — loads historical spend from SQLite, initializes counters
5. `Agent.Orchestrator` — initializes orchestration state
6. `Agent.Progress` — creates progress tracking state
7. `Agent.Hooks` — creates `:osa_hooks` and `:osa_hooks_metrics` ETS tables, registers 10 built-in hooks
8. `Agent.Learning` — loads accumulated patterns and solutions from storage
9. `MiosaKnowledge.Store` — starts Mnesia (production) or ETS (test) knowledge backend
10. `Agent.Memory.KnowledgeBridge` — subscribes to memory write events
11. `Vault.Supervisor` — starts vault store and its persistence workers
12. `Agent.Scheduler` — loads scheduled tasks from SQLite, starts timer
13. `Agent.Compactor` — initializes compaction state
14. `Agent.Cortex` — initializes multi-provider synthesis state
15. `Agent.ProactiveMode` — loads proactive trigger configuration
16. `Webhooks.Dispatcher` — loads configured webhook endpoints

---

### Phase 6 — Extensions Subsystem

```
OptimalSystemAgent.Supervisors.Extensions   # one_for_one
```

Conditional children start based on environment configuration:

1. **[Treasury]** — if `OSA_TREASURY_ENABLED=true`
2. **Intelligence.Supervisor** — always (children start dormant)
3. **Orchestrator.Mailbox** — always (ETS table creation)
4. **Orchestrator.SwarmMode** — always
5. **SwarmMode.AgentPool** — always (DynamicSupervisor, max 50)
6. **[Fleet.Supervisor]** — if `OSA_FLEET_ENABLED=true`
7. **Sidecar.Manager** — always (creates circuit breaker ETS)
8. **[Go.Tokenizer]** — if `go_tokenizer_enabled` in app config
9. **[Python.Supervisor]** — if `python_sidecar_enabled`
10. **[Go.Git]** — if `go_git_enabled`
11. **[Go.Sysmon]** — if `go_sysmon_enabled`
12. **[WhatsAppWeb]** — if `whatsapp_web_enabled`
13. **[Sandbox.Supervisor]** — if `sandbox_enabled`
14. **[Wallet + Wallet.Mock]** — if `wallet_enabled`
15. **[System.Updater]** — if `update_enabled`
16. **[Platform.AMQP]** — if `AMQP_URL` is set

---

### Phase 7 — Deferred Channel Startup

```
OptimalSystemAgent.Channels.Starter   # GenServer
```

`Channels.Starter` starts immediately as a GenServer but does its real work in `handle_continue`.
This deferred pattern ensures all agent processes (Memory, Hooks, Learning, etc.) are running
before any channel adapter accepts an inbound message.

On `handle_continue`, `Channels.Starter` reads the channel configuration and calls
`DynamicSupervisor.start_child(Channels.Supervisor, ...)` for each configured adapter. Adapters
that lack required configuration (no API token, no webhook URL) skip silently and log a warning.

---

### Phase 8 — HTTP Server

```
{Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: 8089}
```

Bandit (the HTTP server) starts last. By the time it accepts its first request, the entire agent
stack is initialized and ready. The port defaults to 8089, configurable via `OSA_HTTP_PORT`.

`Channels.HTTP` is a Plug router that handles:
- `POST /sessions` — create a new agent session
- `POST /sessions/:id/messages` — send a message to a session
- `GET /sessions/:id/stream` — SSE stream of agent events
- `GET /sessions/:id/pending_questions` — poll for blocked `ask_user` calls
- `POST /sessions/:id/answers` — submit an answer to a pending question
- `GET /health` — health check
- `GET /metrics` — Telemetry.Metrics export

---

### Phase 9 — Post-Startup Async Tasks

After `Supervisor.start_link/2` returns `{:ok, pid}`, two async tasks run without blocking the
caller:

**Ollama auto-detection (synchronous, inline):**

```elixir
MiosaProviders.Ollama.auto_detect_model()
OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
```

This detects the best available Ollama model and assigns tier mappings (which Ollama model
corresponds to opus/sonnet/haiku capability levels). Runs synchronously so the startup banner
shows the correct model rather than a stale fallback.

**MCP server startup (async Task):**

```elixir
Task.start(fn ->
  OptimalSystemAgent.MCP.Client.start_servers()
  OptimalSystemAgent.MCP.Client.list_tools()
  OptimalSystemAgent.Tools.Registry.register_mcp_tools()
end)
```

MCP servers defined in `~/.osa/mcp.json` are started asynchronously. `start_servers/0` spawns
one `MCP.Server` GenServer per entry under `MCP.Supervisor`. `list_tools/0` blocks until each
server completes its JSON-RPC `initialize` handshake. `register_mcp_tools/0` writes discovered
tools into `:persistent_term` (the same store used by `Tools.Registry.list_tools_direct/0`).

Tools are unavailable until this Task completes, but the main application loop is fully functional
for built-in tool calls from the moment Bandit starts.

---

## Startup Timeline

```mermaid
sequenceDiagram
    participant APP as Application.start/2
    participant ETS as ETS Tables
    participant SOUL as Soul.load
    participant INFRA as Infrastructure
    participant SESS as Sessions
    participant AGSVC as AgentServices
    participant EXT as Extensions
    participant CHAN as Channels.Starter
    participant HTTP as Bandit (port 8089)
    participant MCP as MCP.Client (async)

    APP->>ETS: Create 7 named ETS tables
    APP->>SOUL: Soul.load() + PromptLoader.load()
    APP->>INFRA: start_link (rest_for_one)
    Note over INFRA: SessionRegistry → Events.Bus → Store.Repo → Tools.Registry → MCP.Supervisor
    APP->>SESS: start_link (one_for_one)
    Note over SESS: Channels.Supervisor → EventStreamRegistry → SessionSupervisor
    APP->>AGSVC: start_link (one_for_one)
    Note over AGSVC: Memory → Hooks → Learning → Vault → Scheduler
    APP->>EXT: start_link (one_for_one)
    Note over EXT: Intelligence + Swarm always; others conditional
    APP->>CHAN: start_link → handle_continue (deferred adapter startup)
    APP->>HTTP: start_link (port 8089)
    APP->>APP: Ollama auto_detect_model (synchronous)
    APP-->>MCP: Task.start (async): start_servers → list_tools → register_mcp_tools
```

---

## Shutdown Sequence

OSA uses standard OTP graceful shutdown. When the application receives a shutdown signal (SIGTERM,
`Application.stop/1`, or VM halt):

1. `OptimalSystemAgent.Supervisor` calls `Supervisor.stop/3` on itself.
2. Children are terminated in reverse start order (Bandit → Channels.Starter → Extensions →
   AgentServices → Sessions → Infrastructure → TaskSupervisor → Platform.Repo).
3. Each GenServer receives `terminate/2` with reason `:shutdown`. In-flight LLM calls are
   abandoned (the BEAM process exits). Persistent state (memory, tasks, vault, schedules) is
   already durable in SQLite — no flush is required.
4. `Agent.Loop` processes in `SessionSupervisor` receive `:shutdown` and call their `terminate/2`
   hooks: `session_end` hooks fire (including `session_cleanup` which removes ETS read-tracking
   entries for the session).
5. ETS tables are garbage collected when the owning process exits. Named tables owned by the
   application process persist until the VM exits.

**Maximum shutdown time:** OTP default is 5 seconds per child. Channel adapters that hold open
HTTP connections may delay shutdown if they do not implement `terminate/2` cleanly. Bandit drains
active connections before exiting.

---

## Restart Behavior

| Crash Location | Effect |
|---|---|
| `Events.Bus` | rest_for_one restarts Bus + all children above it (DLQ, Bridge, Repo, Tools, etc.). Sessions are unaffected if they do not hold references to Bus directly. |
| `Store.Repo` | rest_for_one restarts Repo + Tools.Registry + MCP components. In-flight SQLite writes are rolled back by Ecto on next start. |
| `Agent.Memory` | one_for_one restarts only Memory. Other AgentServices continue. Active sessions see a brief `:exit` from `Memory.recall/0` during restart but recover on retry. |
| `Agent.Loop` (session) | one_for_one restarts only that session's Loop process. The session ID is re-registered in SessionRegistry. Conversation history is reloaded from SQLite. |
| Channel adapter | one_for_one restarts only that adapter. Other sessions and channels continue. |
| Go.Tokenizer sidecar | Sidecar.Manager detects the Port exit and restarts the Go binary. `Agent.Context.estimate_tokens/1` falls back to heuristic estimation during the brief restart window. |
