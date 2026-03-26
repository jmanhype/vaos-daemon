# System Boundaries

**Audience:** Engineers integrating Daemon, operators deploying it, anyone trying to
understand what Daemon is responsible for and what it delegates to other systems.

---

## What Daemon Is

Daemon is an **AI agent orchestration system**. It receives input from users and
external systems, classifies that input, selects and invokes the appropriate LLM
provider, manages multi-agent collaboration, maintains memory across sessions,
executes tools in sandboxed environments, and delivers structured output through
a variety of channel adapters.

Concretely, Daemon owns:

- The agent reasoning loop (bounded ReAct with strategies)
- Signal Theory classification and routing logic
- The hook middleware pipeline
- Context assembly and token budget management
- Multi-agent orchestration and swarm coordination
- Session and conversation memory (4 layers)
- Tool execution and sandboxing
- Channel adapter lifecycle (12 platforms)
- LLM provider abstraction (18 providers, 3 tiers)
- The internal event bus and pub/sub infrastructure
- The REST API surface and SSE event streams
- The Vault structured memory system

---

## What Daemon Is Not

Understanding what Daemon does not do is as important as understanding what it does.

**Daemon is not a web framework.** Bandit and Plug are present for a narrow purpose:
exposing the HTTP API on port 8089 and receiving inbound webhooks from messaging
platforms. There is no routing DSL, no middleware stack for end-user web
applications, no template rendering, no cookie management for user sessions in
the web sense. Do not build a web application on top of Bandit/Daemon directly —
use a proper Phoenix application that calls the Daemon API.

**Daemon is not a database.** SQLite (via `ecto_sqlite3`) is used for durable local
storage of conversations, memory, vault entries, and telemetry. PostgreSQL (via
`postgrex`) is used for multi-tenant platform data when running as a hosted
service. Daemon does not expose a general-purpose queryable data layer to callers.
It manages its own storage internally.

**Daemon is not an LLM.** Daemon does not perform inference. It calls LLM provider
APIs. Adding a new LLM capability means adding or updating a provider adapter —
Daemon's role is always orchestration, never inference.

**Daemon is not a message broker.** Phoenix.PubSub and the goldrush event bus are
internal subsystems. They are not a general-purpose message queue for external
applications to publish to or subscribe from. External systems communicate with
Daemon through the REST API or channel-specific webhooks.

**Daemon is not a container orchestrator.** Docker support is present for the
sandbox subsystem — isolated code execution. Daemon does not manage production
container deployments, health checks for its own replicas, or service meshes.
That is the job of the operator's infrastructure (Kubernetes, Nomad, ECS, etc.).

---

## Component Boundaries

### Elixir Backend (Port 8089)

The backend is the core of the system. It owns all reasoning, memory, and
orchestration logic.

```
Responsibilities:
  - Signal Theory classification
  - Agent loop execution (ReAct, CoT, MCTS, etc.)
  - LLM provider calls and tier routing
  - Tool execution and sandboxing
  - Multi-agent orchestration and swarm coordination
  - Memory persistence (JSONL, SQLite, ETS)
  - Vault structured memory
  - Hook middleware pipeline
  - Event bus and pub/sub fanout
  - REST API (Bandit + Plug)
  - SSE event streams for clients
  - Webhook reception for messaging channels
  - MCP server management

Exposes:
  - REST API on port 8089
  - SSE stream at /api/v1/stream/:session_id
  - Health endpoint at /health
```

### Rust TUI Binary (`bin/osa`, `bin/daemon`)

A standalone Rust binary that provides a terminal interface. It is not a library
embedded in the Elixir backend — it is a separate process that connects to the
backend over HTTP/SSE.

```
Responsibilities:
  - Terminal rendering (xterm-compatible)
  - SSE stream consumption (real-time output display)
  - HTTP POST for user input submission
  - JWT token management and refresh
  - Startup coordination (waits for backend health)

Does NOT own:
  - Any agent logic
  - Any memory
  - Any LLM calls
  - Any tool execution
```

The TUI is a pure display client. All intelligence remains in the Elixir backend.

### Tauri + SvelteKit Desktop App (Port 9089 Sidecar)

The Command Center is a native desktop application built with Tauri 2 +
SvelteKit 2 + Svelte 5. It runs as a sidecar alongside the Elixir backend.

```
Responsibilities:
  - Full-featured chat UI with markdown rendering and code highlighting
  - Agent roster browser and task dispatch
  - Model and provider management UI
  - Embedded xterm.js terminal
  - Task tracking and memory browser
  - Real-time activity feed (SSE consumption)
  - Channel and MCP connector configuration
  - Token usage and budget dashboard
  - Settings and profile management

Connects to:
  - Elixir backend on port 8089 (HTTP + SSE)

Does NOT own:
  - Any backend logic
  - Any data storage (all state lives in backend SQLite/ETS)
```

### SQLite Local Storage

Used for single-user and development deployments. Managed entirely by the
Elixir backend through Ecto.

```
Stores:
  - Conversation history (messages table)
  - Session metadata
  - Memory entries (long-term JSONL overflow)
  - Telemetry metrics snapshots
  - Vault facts (supplementing the JSONL-based FactStore)

Does NOT store:
  - Multi-tenant user accounts (PostgreSQL)
  - Provider API keys (environment variables or ~/.daemon/.env)
  - Binary artifacts or uploaded files
```

### PostgreSQL (Optional — Multi-Tenant)

Used when Daemon runs as a hosted platform (MIOSA Cloud or self-hosted multi-tenant
deployment). Conditional: the `Platform.Repo` child in the root supervisor is
only started when `DAEMON_PLATFORM_MODE=true` and `DATABASE_URL` is set.

```
Stores:
  - Tenant accounts and authentication grants
  - Per-tenant configuration
  - Cross-instance coordination data
  - AMQP routing metadata

Not required for:
  - Single-user local deployments
  - Development environments
  - Docker Compose single-container deployments
```

---

## External Dependencies

### LLM Provider APIs

Daemon calls 18 external APIs for inference. These are outside Daemon's control. Daemon's
response to provider unreliability:

- `MiosaLLM.HealthChecker` — continuous health monitoring with circuit breaker
  pattern per provider
- Automatic fallback chain — if the primary provider fails, the next configured
  provider is tried
- Per-provider rate limiting and retry budgets in the provider adapters

Daemon does not cache LLM responses (beyond the classification ETS cache for Signal
Theory results). Every agent turn makes a live API call.

### Ollama (Local Inference)

Ollama is the default provider for new installations. It runs as a separate
process (typically on port 11434) and is not managed by Daemon's supervision tree.
Daemon connects to Ollama via HTTP. If Ollama is unavailable, Daemon falls back to the
next configured provider or notifies the user during setup.

Dynamic tier detection: at boot, Daemon queries Ollama's `/api/tags` endpoint, sorts
installed models by file size descending, and maps largest→elite,
middle→specialist, smallest→utility. This mapping is cached in `persistent_term`.

### Docker (Sandbox Execution)

The Docker daemon must be running on the host for the Docker sandbox backend to
function. Daemon does not start or manage Docker — it calls the Docker API to create
containers with specific security constraints:

```
Read-only root filesystem
CAP_DROP ALL (no Linux capabilities)
Network isolation (no outbound by default)
Memory and CPU limits per sandbox policy
Non-root user inside container
```

If Docker is unavailable, `Sandbox.Supervisor` starts with `:ignore` and the
Wasm backend is used as fallback.

### MCP Servers

Model Context Protocol servers are external processes managed by Daemon's
`MCP.Supervisor` (a `DynamicSupervisor`). Each MCP server entry in
`~/.daemon/mcp.json` gets its own supervised GenServer in Daemon. Daemon is responsible
for starting, monitoring, and restarting MCP server processes. MCP servers are
responsible for their own tool implementations.

### Go Sidecars (`priv/go/`)

Three Go binaries run as supervised OS processes:

| Binary | Role |
|---|---|
| `osa-tokenizer` | Fast token counting without LLM round-trip |
| `osa-git` | Git operations (blame, log, diff) for code tools |
| `osa-sysmon` | System resource monitoring for proactive mode |

These are not Elixir NIFs. They are external processes managed by
`Sidecar.Manager` via Elixir's `Port` mechanism. If a sidecar binary is absent
(e.g. not compiled yet), its supervisor child returns `:ignore`.

---

## Deployment Boundary Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Host Machine                                                       │
│                                                                     │
│  ┌─────────────────────────────┐   ┌──────────────────────────────┐│
│  │  Daemon Elixir Backend         │   │  Tauri Desktop App           ││
│  │  Port 8089                  │   │  Port 9089 (dev sidecar)     ││
│  │                             │   │                              ││
│  │  SQLite (local)             │◄──│  SvelteKit UI                ││
│  │  ETS / persistent_term      │   │  xterm.js terminal           ││
│  └──────────────┬──────────────┘   └──────────────────────────────┘│
│                 │ connects                                           │
│  ┌──────────────▼──────────────┐                                    │
│  │  Rust TUI (bin/osa)         │                                    │
│  │  Terminal client            │                                    │
│  └──────────────┬──────────────┘                                    │
│                 │ managed as OS processes                            │
│  ┌──────────────▼──────────────┐                                    │
│  │  Go Sidecars (priv/go/)     │                                    │
│  │  tokenizer │ git │ sysmon   │                                    │
│  └─────────────────────────────┘                                    │
│                                                                     │
│  ┌─────────────────────────────┐                                    │
│  │  Ollama (port 11434)        │  Optional — local inference        │
│  └─────────────────────────────┘                                    │
│                                                                     │
│  ┌─────────────────────────────┐                                    │
│  │  Docker daemon              │  Optional — sandbox execution      │
│  └─────────────────────────────┘                                    │
│                                                                     │
│  ┌─────────────────────────────┐                                    │
│  │  MCP servers (external)     │  Optional — npm/npx processes      │
│  └─────────────────────────────┘                                    │
└─────────────────────────────────────────────────────────────────────┘
                 │ HTTPS
┌────────────────▼────────────────────────────────────────────────────┐
│  External APIs                                                      │
│  Anthropic │ OpenAI │ Google │ Groq │ ... 14 more providers         │
│  Telegram │ Discord │ Slack │ WhatsApp │ ... 8 more channels        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Boundary Invariants

These constraints hold across all deployment configurations:

1. The Elixir backend is always the source of truth. Clients (TUI, desktop, HTTP)
   never write state independently — all state changes go through the backend API.

2. Provider API keys never travel through client processes. They are held by the
   backend in environment variables or `~/.daemon/.env`. The TUI and desktop app
   receive only rendered responses.

3. Sandboxed code execution never shares a process with the Elixir runtime. Docker
   containers, Wasm instances, and Sprites.dev microVMs are isolated at the OS
   level.

4. Channel adapters are stateless with respect to conversation context. Conversation
   state lives in the backend session registry and SQLite. Channel adapters hold
   only connection credentials and webhook configuration.

---

## Next

- [Dependency Rules](dependency-rules.md) — How Daemon's internal layers are
  allowed to depend on each other
- [Architecture Principles](architecture-principles.md) — Why these boundaries
  were drawn where they are
