# Glossary

**Audience:** Everyone. These are the canonical definitions for terms used
throughout all Daemon documentation. When a term appears capitalized in Daemon docs,
it refers to the definition here.

Definitions are organized by conceptual cluster, not alphabetically.

---

## Signal Theory

### Signal

A classified input tuple produced by the Signal Theory classifier. Every user
message, system event, and channel input that enters Daemon is transformed into a
Signal before routing.

```
Signal = (Mode, Genre, Type, Format, Weight)
```

Signals are not the raw messages — they are the result of classifying the raw
message. The Signal is what the routing layer acts on; the original text is what
the agent reasons about.

Reference: `Daemon.Signal.Classifier`

---

### Weight

A continuous value in [0.0, 1.0] that encodes the informational density and
task complexity of a Signal. Weight is the primary routing dimension — it
determines which compute Tier handles a request.

```
0.00 – 0.20  Noise         (greetings, filler, single words)
0.20 – 0.35  Low           (simple acknowledgments, trivial questions)
0.35 – 0.65  Medium        (standard questions, single-step requests)
0.65 – 0.90  High          (complex tasks, multi-part requests)
0.90 – 1.00  Critical      (production incidents, emergencies)
```

Weight is computed by the LLM classifier with a deterministic regex fallback.
Results are cached in ETS (SHA256 key, 10-minute TTL).

---

### Tier

One of three compute tiers selected by Weight. Tier determines which LLM model
class handles the request, what token budget is allocated, and how many
concurrent sub-agents can be spawned.

| Tier | Weight Range | Model Class | Token Budget | Max Agents |
|---|---|---|---|---|
| Utility | 0.00 – 0.35 | 8B local, Haiku, GPT-3.5 | 100K | 10 |
| Specialist | 0.35 – 0.65 | 70B local, Sonnet, GPT-4o-mini | 200K | 30 |
| Elite | 0.65 – 1.00 | Frontier: Opus, GPT-4o, Gemini Pro | 250K | 50 |

Reference: `Daemon.Agent.Tier`

---

### Mode

The operational action dimension of a Signal. Five values:

| Mode | Meaning | Typical tasks |
|---|---|---|
| BUILD | Create something new | scaffold, generate, write, implement |
| EXECUTE | Perform an action now | run, deploy, send, trigger |
| ANALYZE | Produce insight | report, compare, trend, review |
| MAINTAIN | Fix or update | fix, migrate, patch, upgrade, debug |
| ASSIST | Provide guidance | explain, teach, clarify, help understand |

Mode is the primary input to strategy selection. BUILD + high Weight routes to
the Orchestrator. ASSIST rarely does.

---

### Genre

The communicative act dimension of a Signal. Five values:

```
DIRECT   — A command: "do this"
INFORM   — Sharing information: "FYI, the build failed"
COMMIT   — A promise: "I'll handle it by Friday"
DECIDE   — An approval or choice: "approved", "let's go with option B"
EXPRESS  — Emotional expression: "thanks", "this is frustrating"
```

Genre drives response style and memory behavior. COMMIT triggers task tracking.
EXPRESS shifts tone in the response.

---

### Noise Filter

A two-tier pre-routing filter that runs before the event bus, preventing low-value
inputs from consuming agent resources.

```
Tier 1 — Regex patterns (<1ms): catch greetings, single words, pure whitespace
Tier 2 — Weight threshold: if Weight < configured floor (default 0.1), drop
```

Signals that pass the noise filter reach `Events.Bus`. Those that do not are
either responded to with a lightweight canned response or silently discarded,
depending on channel configuration.

---

## Agent Loop

### Agent Loop

A `GenServer` process that manages one agent session. Each active session has
exactly one Agent Loop process, identified by session ID in the
`Daemon.SessionRegistry`.

The loop's turn cycle: build context → call LLM provider → parse response →
execute tool calls (if any) → check halt conditions → emit response → repeat
until halt.

The loop is bounded: a maximum iteration count per turn prevents runaway
reasoning. When the limit is reached, the loop emits whatever partial result is
available and halts.

Reference: `Daemon.Agent.Loop`

---

### Strategy

A reasoning approach applied by the Agent Loop to a given turn. Strategies are
selected based on Signal Mode, Weight, and turn history.

| Strategy | When used | Description |
|---|---|---|
| ReAct | Default | Reason → Act → Observe cycles (standard tool use) |
| CoT | ANALYZE, medium Weight | Chain-of-thought without tool calls |
| Reflection | After failed turns | Reason about what went wrong, retry |
| MCTS | High Weight, open-ended | Monte Carlo Tree Search over response branches |
| Tree of Thoughts | Critical Weight | Deliberate exploration of solution trees |

Reference: `Daemon.Agent.Strategy`

---

### Halt Condition

A condition that causes the Agent Loop to stop iterating and emit its current
result. Halt conditions include:

- A final response with no tool calls (natural completion)
- Reaching the maximum iteration count for the current tier
- A `budget_exceeded` signal from the Budget guard
- A `block` return from the hook pipeline on a critical path
- An unrecoverable provider error after the configured retry budget is exhausted

---

## Orchestration

### Orchestrator

A `GenServer` (`Daemon.Agent.Orchestrator`) that decomposes complex
tasks into sub-agent work units and manages their execution. The Orchestrator is
invoked when a Signal's Mode is BUILD or EXECUTE and its Weight is above the
orchestration threshold (typically 0.65).

The Orchestrator's lifecycle per task:

1. Analyze complexity via LLM (produces a complexity score 1–10)
2. Decompose into dependency-aware tasks
3. Assign each task to a Tier and Agent Role
4. Execute tasks in dependency-ordered waves (parallel within wave,
   sequential across waves)
5. Track progress via Events.Bus
6. Synthesize results from all sub-agents into a final response

Reference: `Daemon.Agent.Orchestrator`

---

### Swarm

A collaborative multi-agent execution pattern. Where the Orchestrator
decomposes a single goal into sequential waves, a Swarm runs multiple agents
with defined interaction patterns:

| Pattern | Description |
|---|---|
| `:parallel` | All agents work simultaneously on independent subtasks |
| `:pipeline` | Output of agent N is input to agent N+1 |
| `:debate` | Agents produce competing responses; consensus is synthesized |
| `:review_loop` | Agent builds, reviewer critiques, builder fixes, repeat |

Agents in a swarm communicate via the mailbox pattern: each sub-agent's output
is posted to a named mailbox in ETS; the swarm coordinator reads and routes.

Reference: `Daemon.Swarm.*`

---

### PACT

A quality-gated orchestration framework: Planning → Action → Coordination →
Testing. Applied to multi-agent tasks to ensure that outputs meet quality
criteria before synthesis.

```
Planning      — decompose, assign tiers, validate the plan
Action        — execute sub-agents in waves
Coordination  — track progress, collect wave outputs
Testing       — evaluate outputs, retry failures, escalate if needed
```

PACT is enforced by the Orchestrator state machine. A synthesis response is not
emitted until the Testing phase completes or the budget is exhausted.

---

### Roster

The catalog of named agent roles available for sub-agent dispatch. The Roster
maps role names to tier, description, and system prompt template. 31 named roles
are defined in `Daemon.Agent.Roster`, plus 17 specialized roles for
swarm patterns.

Examples: `researcher`, `builder`, `reviewer`, `tester`, `writer`, `debugger`,
`architect`, `security-auditor`, `performance-optimizer`.

---

### DLQ

Dead Letter Queue. A supervised `GenServer` (`Daemon.Events.DLQ`)
that receives events that fail routing or processing in `Events.Bus`. Failed
events are stored in ETS with their error reason and a retry count. The DLQ
exposes a manual retry API and periodic automatic retry for transient failures.

Events that exceed the maximum retry count are logged and discarded. The DLQ
ensures that event processing failures are observable and recoverable rather
than silently lost.

Reference: `Daemon.Events.DLQ`

---

## Memory and Knowledge

### Vault

Daemon's structured memory system. The Vault stores typed facts, decisions, lessons,
preferences, commitments, relationships, projects, and observations as files on
disk under `~/.daemon/vault/`.

The Vault goes beyond flat-file memory:

- **8 typed categories** — each with YAML frontmatter and a defined schema
- **Fact extraction** — ~15 regex patterns extract structured facts from free
  text without an LLM call
- **Temporal decay scoring** — observations have a relevance score (0.0–1.0)
  that decays exponentially over time
- **Session lifecycle hooks** — Wake (detect dirty deaths), Checkpoint (periodic
  save), Sleep (handoff doc creation)
- **Context profiles** — 4 profiles (default, planning, incident, handoff)
  control what Vault content enters the prompt
- **Prompt injection** — keyword matching selects relevant facts/decisions to
  inject into the system prompt

6 tools expose the Vault to the agent: `vault_remember`, `vault_context`,
`vault_wake`, `vault_sleep`, `vault_checkpoint`, `vault_inject`.

Reference: `Daemon.Vault.*`

---

### Cortex

A `GenServer` that acts as a context aggregation delegate. The Cortex synthesizes
information from multiple memory layers (episodic, vault, long-term) into a
consolidated "bulletin" — a concise summary of active topics, recent decisions,
and current context that is injected into the dynamic context block during prompt
assembly.

The Cortex does not store data — it reads from Memory, Vault, and Episodic and
produces a synthesized view.

Reference: `Daemon.Agent.Cortex`

---

### Episodic Memory

A keyword-inverted index stored in ETS that maps terms to session IDs. When
the agent processes a turn, it writes a JSONL episode record containing the
turn content, tool calls, and outcome. At context assembly time, the episodic
index is queried with keywords from the current input, and matching episodes
are retrieved and ranked by recency score.

Episodic memory bridges the gap between the session-scoped conversation log
and the cross-session long-term memory: it allows retrieval of specific past
events without loading all historical context.

Reference: `Daemon.Agent.Memory.Episodic`

---

### Knowledge Graph

A semantic triple store managed by `MiosaKnowledge.Store`. Supports SPARQL-style
queries and OWL 2 RL reasoning. Backed by Mnesia in production (persistence,
distributed) and ETS in test (fast, ephemeral).

The Knowledge Graph stores learned patterns, solutions, and entity relationships
across sessions. It is populated by the Learning subsystem when the agent
completes tasks successfully. The `semantic_search` tool queries it at runtime.

Reference: `MiosaKnowledge.*`, `Daemon.Agent.Memory.KnowledgeBridge`

---

## Infrastructure

### ETS

Erlang Term Storage. In-memory, concurrent key-value store provided by the BEAM
runtime. ETS tables in Daemon are owned by GenServers (which are the sole writers)
and read directly by caller processes (no GenServer bottleneck on reads).

Key ETS tables in Daemon:

| Table | Owner | Contents |
|---|---|---|
| `:daemon_hooks` | `Agent.Hooks` | Registered hook entries (bag) |
| `:daemon_hooks_metrics` | `Agent.Hooks` | Atomic execution counters |
| `:daemon_signal_cache` | Signal Classifier | Classification results, 10-min TTL |
| `:daemon_tool_cache` | `Tools.Cache` | Tool schema cache |
| `:daemon_episodic` | `Memory.Episodic` | Keyword → session inverted index |

---

### goldrush

A compiled Erlang event routing library (Daemon fork of extend/goldrush). goldrush
compiles event-matching predicates into real Erlang bytecode modules at startup.
This means event routing at runtime is a BEAM function call — no hash lookups, no
ETS reads, no pattern dispatch at the routing layer.

Three goldrush-compiled modules in Daemon:

| Module | Compiled by | Purpose |
|---|---|---|
| `:daemon_event_router` | `Events.Bus` | Route events to subscribers |
| `:daemon_tool_dispatcher` | `Tools.Registry` | Route tool calls to handlers |
| `:daemon_provider_router` | `Providers.Registry` | Route LLM calls to adapters |

Reference: `Daemon.Events.Bus`, `Daemon.Tools.Registry`

---

## Extensibility

### Hook

A middleware function registered for a specific lifecycle event in the agent
loop. Hooks run in priority order (lower number = first). Each hook receives a
payload map and returns `{:ok, payload}`, `{:block, reason}`, or `:skip`.

```
{:ok, payload}    — continue; payload may be modified
{:block, reason}  — stop the pipeline; the action is not performed
:skip             — this hook does not apply; continue to next hook
```

Lifecycle events: `pre_tool_use`, `post_tool_use`, `pre_compact`, `session_start`,
`session_end`, `pre_response`, `post_response`.

Built-in hooks: `security_check` (p10), `spend_guard` (p8), `mcp_cache` (p15),
`cost_tracker` (p25), `mcp_cache_post` (p15), `telemetry` (p90).

Registration goes through a GenServer (serialized writes). Execution reads from
ETS in the caller's process (no bottleneck).

Reference: `Daemon.Agent.Hooks`

---

### Channel

An I/O adapter that translates between a communication platform's format and
Daemon's internal event representation. Each channel is a supervised process (or
process group) under `Channels.Supervisor`.

All channels implement `Daemon.Channels.Behaviour`:

```elixir
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(session_id :: String.t(), message :: map()) :: :ok | {:error, term()}
@callback format_input(raw :: term()) :: {:ok, map()} | {:error, term()}
```

The 12 channels: CLI, HTTP/REST, Telegram, Discord, Slack, WhatsApp, Signal,
Matrix, Email, QQ, DingTalk, Feishu/Lark.

---

### Soul

The identity and personality configuration for an Daemon deployment. A Soul is a
set of files in `~/.daemon/soul/` (or the default bundled soul) that define:

- `SYSTEM.md` — the base system prompt template
- `RULES.md` — behavioral constraints
- `PROFILE.md` — user/organization profile injected into context

The Soul's `SYSTEM.md` is interpolated once at session start and cached in
`persistent_term` as the static base (Tier 1 of context assembly). This is the
mechanism that enables ~90% prompt cache hit rates on Anthropic: the static base
is marked `cache_control: ephemeral`.

Reference: `Daemon.Soul`

---

### Machine

A composable set of skills, tools, and prompts grouped into a named capability
bundle. Machines are loaded from `~/.daemon/machines/` and registered with
`Daemon.Machines` at startup. A Machine might bundle a set of tools
with a set of instructions for using them together — for example, a `code-review`
Machine that includes `file_read`, `file_grep`, `shell_execute`, and a set of
review heuristics.

Machines are opt-in: the agent loads only the machines enabled in its
configuration.

---

### Skill

A single callable capability exposed to the agent as a tool call. Skills are the
atomic unit of agent capability. Two kinds:

**Elixir module skills** — implement `Daemon.Skills.Behaviour`, define
a JSON Schema for parameters, and return `{:ok, result}` or `{:error, reason}`.
Registered programmatically at startup or runtime.

**SKILL.md skills** — a markdown file with YAML frontmatter declaring the skill
name, description, and available tools. Loaded dynamically from `~/.daemon/skills/`.
No code required. Available immediately after dropping the file — no restart.

```markdown
---
name: my-skill
description: What this skill does
tools:
  - file_read
  - shell_execute
---
## Instructions
...
```

---

### MCP (Model Context Protocol)

An open protocol for connecting external tool servers to AI agents. Daemon's
`MCP.Supervisor` manages a pool of MCP server processes. Each server entry in
`~/.daemon/mcp.json` gets a supervised GenServer that manages the server's lifecycle,
discovers its available tools, and bridges those tools into Daemon's tool registry.

MCP tools are treated identically to built-in skills from the agent's perspective.

Reference: `Daemon.MCP.*`

---

## Deployment

### Session

The stateful context of a single user interaction sequence. A session has:

- A unique session ID
- An Agent Loop process (in `SessionRegistry`)
- A conversation message list
- A token budget allocation (from `MiosaBudget.Budget`)
- Vault lifecycle state (wake/active/sleeping)
- A heartbeat timestamp (for idle detection)

Sessions are persistent across restarts: the conversation log is written to
SQLite, so an Agent Loop process restart does not lose conversation history.

---

### Platform Mode

An optional operating mode where Daemon runs as a multi-tenant hosted service.
Activated by `DAEMON_PLATFORM_MODE=true`. Adds:

- `Platform.Repo` (PostgreSQL) for tenant data
- JWT-based multi-tenant authentication
- RabbitMQ AMQP publisher for cross-instance events
- Fleet coordination across multiple Daemon instances

Platform Mode is not required for single-user local deployments.

---

*This glossary is the authoritative reference for Daemon terminology. If a term is
used in Daemon documentation but not defined here, that is a documentation gap —
add it.*
