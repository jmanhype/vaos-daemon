# OptimalSystemAgent (OSA) Ecosystem Map

> 300 Elixir modules, ~68K lines, 1958 tests
> Last updated: 2026-03-08 (commit 7e9fc2d)

---

## Supervision Tree

```
OptimalSystemAgent.Application (rest_for_one)
|
+-- [Platform.Repo]                    # opt-in PostgreSQL (DATABASE_URL)
|
+-- Supervisors.Infrastructure         # rest_for_one — CORE FOUNDATION
|   +-- SessionRegistry (Registry)
|   +-- Events.TaskSupervisor          # supervised async tasks (max 100)
|   +-- PubSub (Phoenix.PubSub)
|   +-- Events.Bus                     # goldrush-compiled event routing
|   +-- Events.DLQ                     # dead letter queue (3 retries)
|   +-- Bridge.PubSub                  # event fan-out bridge
|   +-- Store.Repo                     # SQLite3 persistent storage
|   +-- Telemetry.Metrics              # telemetry subscriber
|   +-- MiosaLLM.HealthChecker         # EXTRACTED: circuit breaker for providers
|   +-- Providers.Registry             # goldrush-compiled :osa_provider_router
|   +-- Tools.Registry                 # goldrush-compiled :osa_tool_dispatcher
|   +-- Machines                       # machine/OS template registry
|   +-- Commands                       # slash command registry
|   +-- OS.Registry                    # OS template discovery
|   +-- MCP.Registry (Registry)        # MCP server name lookup
|   +-- MCP.Supervisor (DynamicSup)    # per-server MCP GenServers
|
+-- Supervisors.Sessions               # one_for_one — SESSION MANAGEMENT
|   +-- Channels.Supervisor (DynamicSup) # CLI, HTTP, Telegram, Discord, etc.
|   +-- EventStreamRegistry (Registry)
|   +-- SessionSupervisor (DynamicSup)   # per-session agent Loop processes
|
+-- Supervisors.AgentServices           # one_for_one — AGENT INTELLIGENCE
|   +-- Agent.Memory                    # long-term memory (episodic + semantic)
|   +-- Agent.HeartbeatState            # session heartbeat tracking
|   +-- Agent.Workflow                  # multi-step workflow engine
|   +-- MiosaBudget.Budget              # EXTRACTED: token/cost budget tracking
|   +-- Agent.TaskQueue                 # task queuing + priority scheduling
|   +-- Agent.Orchestrator              # multi-agent coordination
|   +-- Agent.Progress                  # progress reporting
|   +-- Agent.TaskTracker               # task lifecycle tracking
|   +-- Agent.Hooks                     # pre/post tool-use hooks (ETS metrics)
|   +-- Agent.Learning                  # pattern learning + skill extraction
|   +-- MiosaKnowledge.Store            # semantic knowledge graph
|   +-- Memory.KnowledgeBridge          # knowledge ↔ memory bridge
|   +-- Vault.Supervisor                # structured memory subsystem
|   |   +-- Vault.FactStore             # ETS + JSONL temporal fact store
|   |   +-- Vault.Observer              # buffered observation pipeline
|   +-- Agent.Scheduler                 # cron-like job scheduling
|   +-- Agent.Compactor                 # context window compaction
|   +-- Agent.Cortex                    # cross-agent synthesis
|
+-- Supervisors.Extensions              # one_for_one — OPT-IN SUBSYSTEMS
|   +-- [Agent.Treasury]               # opt-in: token treasury
|   +-- Intelligence.Supervisor         # Signal Theory intelligence
|   +-- Swarm.Supervisor               # multi-agent swarm coordination
|   +-- [Fleet.Supervisor]             # opt-in: multi-instance fleet
|   +-- Sidecar.Manager                # always: sidecar registry + circuit breakers
|   +-- [Go.Tokenizer]                 # opt-in: Go tokenizer sidecar
|   +-- [Python.Supervisor]            # opt-in: Python sidecar (embeddings)
|   +-- [Go.Git]                       # opt-in: Go git sidecar
|   +-- [Go.Sysmon]                    # opt-in: Go system monitor
|   +-- [WhatsAppWeb]                  # opt-in: WhatsApp Web sidecar
|   +-- [Sandbox.Supervisor]           # opt-in: code sandbox pool
|   +-- [Wallet.Mock + Wallet]         # opt-in: crypto wallet
|   +-- [System.Updater]              # opt-in: OTA updates
|   +-- [Platform.AMQP]               # opt-in: RabbitMQ publisher
|
+-- Channels.Starter                    # deferred channel startup (handle_continue)
+-- Bandit (HTTP on :8089)              # SDK API surface — started LAST
```

Items in `[brackets]` are conditionally started via config/env flags.

---

## Module Domains (lib/optimal_system_agent/)

### 1. Agent Core (`agent/`)
The brain. Manages the agent loop, context, strategies, and all intelligence services.

| Module | Lines | Purpose |
|--------|-------|---------|
| `loop.ex` | 1097 | Main agent loop: prompt -> LLM -> tool exec -> repeat |
| `loop/llm_client.ex` | — | LLM call abstraction (provider-agnostic) |
| `loop/tool_executor.ex` | — | Tool execution with hooks + budget checks |
| `loop/guardrails.ex` | — | Safety guardrails (read-before-write, etc.) |
| `loop/checkpoint.ex` | — | Session checkpoint/restore |
| `loop/genre_router.ex` | — | Signal Theory genre-based routing |
| `context.ex` | 726 | Context window builder (system prompt assembly) |
| `orchestrator.ex` | 829 | Multi-agent task decomposition + wave execution |
| `orchestrator/agent_runner.ex` | 738 | Spawn + manage sub-agent processes |
| `orchestrator/complexity.ex` | — | Task complexity analysis |
| `orchestrator/complexity_scaler.ex` | — | Scale agent count by complexity |
| `orchestrator/decomposer.ex` | — | Break tasks into sub-tasks |
| `orchestrator/explorer.ex` | — | Wave-0 codebase exploration |
| `orchestrator/wave_executor.ex` | — | Execute agent waves (parallel groups) |
| `orchestrator/git_versioning.ex` | — | Git branching for orchestrated tasks |
| `orchestrator/goal_dispatch.ex` | — | Goal-based agent dispatch |
| `orchestrator/skill_manager.ex` | — | Orchestrator skill management |
| `orchestrator/state_machine.ex` | — | Orchestration state machine |
| `memory.ex` | 1317 | Long-term memory: episodic + semantic + decay |
| `memory/episodic.ex` | — | Episodic memory (conversation recall) |
| `memory/injector.ex` | — | Memory injection into context |
| `memory/taxonomy.ex` | — | Memory categorization taxonomy |
| `hooks.ex` | 532 | Pre/post tool-use hooks (ETS atomic metrics) |
| `compactor.ex` | 734 | Context window compaction (summarize old messages) |
| `cortex.ex` | — | Cross-session synthesis + insight extraction |
| `learning.ex` | 590 | Pattern learning + auto-skill generation |
| `workflow.ex` | 785 | Multi-step workflow tracking |
| `scheduler.ex` | 642 | Cron-like scheduling (cron_engine, heartbeat, persistence, job_executor) |
| `task_queue.ex` | 572 | Priority task queue |
| `task_tracker.ex` | 700 | Task lifecycle (pending -> running -> done) |
| `auto_fixer.ex` | 725 | Auto-fix failing tool calls |
| `roster.ex` | 648 | Agent registry + role prompts + swarm presets |
| `agent_behaviour.ex` | 28 | `@behaviour` contract for agent modules |
| `strategy.ex` | — | Strategy pattern (selects reasoning strategy) |
| `strategies/` | — | CoT, MCTS, ReAct, Reflection, ToT |
| `tier.ex` | — | Model tier detection (elite/specialist/utility) |
| `appraiser.ex` | — | Response quality scoring |
| `progress.ex` | — | Progress reporting to channels |
| `heartbeat_state.ex` | — | Session heartbeat tracking |
| `explorer.ex` | — | Codebase exploration (standalone) |
| `directive.ex` | — | Agent directive struct |
| `scratchpad.ex` | — | Agent scratchpad (working memory) |
| `treasury.ex` | — | Token treasury (opt-in) |

### 2. Agent Modules (`agents/`)
25 specialized agent definitions, each implementing `AgentBehaviour`.

| Tier | Agents |
|------|--------|
| **Elite** | `master_orchestrator`, `architect`, `dragon` (10K+ RPS), `nova` (AI/ML) |
| **Specialist** | `backend_go`, `frontend_react`, `frontend_svelte`, `database`, `security_auditor`, `red_team`, `debugger`, `test_automator`, `code_reviewer`, `performance_optimizer`, `devops`, `api_designer`, `refactorer`, `doc_writer`, `dependency_analyzer`, `typescript_expert`, `tailwind_expert`, `go_concurrency`, `orm_expert` |
| **Utility** | `explorer`, `formatter` |

### 3. Providers (`providers/`)
LLM provider adapters — all implement the same interface.

| Module | Purpose |
|--------|---------|
| `registry.ex` | Goldrush-compiled provider router |
| `behaviour.ex` | Provider behaviour contract |
| `anthropic.ex` | Anthropic Claude API |
| `openai_compat.ex` | OpenAI-compatible (OpenAI, Groq, Together, etc.) |
| `ollama.ex` | Ollama local models |
| `replicate.ex` | Replicate API |
| `cohere.ex` | Cohere API |
| `tool_call_parsers.ex` | Parse tool calls from LLM responses |

### 4. Tools (`tools/`)
Tool system — 33 built-in tools + MCP tools + SDK tools.

| Module | Purpose |
|--------|---------|
| `registry.ex` (1129L) | Goldrush-compiled tool dispatcher |
| `behaviour.ex` | Tool behaviour contract |
| `instruction.ex` | Tool instruction system |
| `middleware.ex` | Tool middleware pipeline |
| `pipeline.ex` | Tool execution pipeline |
| **Builtins:** | |
| `shell_execute` | Shell command execution |
| `file_read/write/edit/glob/grep` | File system operations |
| `git` | Git operations |
| `github` | GitHub API |
| `web_fetch/search` | Web access |
| `ask_user` | User interaction |
| `delegate` | Delegate to sub-agent |
| `orchestrate` | Multi-agent orchestration |
| `memory_save/recall` | Memory operations |
| `session_search` | Search past sessions |
| `task_write` | Task management |
| `budget_status` | Budget reporting |
| `create_skill` | Create new skills |
| `skill_manager` | Manage skills |
| `knowledge` | Knowledge graph queries |
| `semantic_search` | Semantic code search |
| `code_symbols` | AST symbol extraction |
| `codebase_explore` | Codebase exploration |
| `multi_file_edit` | Multi-file editing |
| `wallet_ops` | Wallet operations |
| `mcts_index` | MCTS search index |
| `dir_list` | Directory listing |
| `browser` | Browser automation (Playwright) |
| `code_sandbox` | Sandboxed code execution |
| `computer_use` | Computer use (screen control) |
| `diff` | Diff generation |
| `notebook_edit` | Jupyter notebook editing |
| `vault_remember` | Store memory with fact extraction |
| `vault_context` | Build profiled context from vault |
| `vault_wake` | Session start with dirty-death detection |
| `vault_sleep` | Session end with handoff document |
| `vault_checkpoint` | Mid-session vault save |
| `vault_inject` | Keyword-matched prompt injection |

### 5. Channels (`channels/`)
I/O adapters — how users interact with OSA.

| Module | Purpose |
|--------|---------|
| `behaviour.ex` | Channel behaviour contract |
| `cli.ex` (939L) | Interactive CLI (line editor, spinner, markdown, plan review) |
| `http.ex` + `http/api.ex` | HTTP/REST API (Plug/Bandit) |
| `http/api/*_routes.ex` | Route modules (agent, auth, channel, fleet, session, tool, etc.) |
| `http/auth.ex` | JWT authentication |
| `http/rate_limiter.ex` | Rate limiting |
| `http/integrity.ex` | Request integrity checks |
| `session.ex` | Session management |
| `manager.ex` | Channel lifecycle manager |
| `starter.ex` | Deferred channel startup |
| `noise_filter.ex` | Input noise filtering |
| `telegram.ex` | Telegram bot |
| `discord.ex` | Discord bot |
| `slack.ex` | Slack bot |
| `whatsapp.ex` | WhatsApp (Cloud API) |
| `matrix.ex` | Matrix protocol |
| `email.ex` | Email channel |
| `signal.ex` | Signal messenger |
| `dingtalk.ex` | DingTalk |
| `feishu.ex` | Feishu/Lark |
| `qq.ex` | QQ messenger |

### 6. Events (`events/`)
Event-driven architecture backbone.

| Module | Purpose |
|--------|---------|
| `bus.ex` | Core event bus (goldrush-compiled routing) |
| `event.ex` | Event struct definition |
| `stream.ex` | SSE event streaming |
| `classifier.ex` | Event classification |
| `dlq.ex` | Dead letter queue (retry + drop) |
| `failure_modes.ex` | Failure mode definitions |

### 7. Swarm (`swarm/`)
Multi-agent swarm coordination.

| Module | Purpose |
|--------|---------|
| `supervisor.ex` | Swarm supervision |
| `orchestrator.ex` | Swarm task orchestration |
| `intelligence.ex` (789L) | Swarm intelligence algorithms |
| `planner.ex` | Task decomposition + agent selection |
| `worker.ex` | Individual swarm worker |
| `pact.ex` (681L) | Agent agreement/consensus protocol |
| `patterns.ex` | Swarm patterns (parallel, pipeline, review) |
| `mailbox.ex` | Inter-agent messaging |

### 8. Intelligence (`intelligence/`)
Signal Theory communication intelligence.

| Module | Purpose |
|--------|---------|
| `comm_coach.ex` (578L) | Communication coaching |
| `proactive_monitor.ex` (524L) | Proactive task detection |
| `conversation_tracker.ex` | Conversation state tracking |
| `contact_detector.ex` | Contact/entity detection |
| `supervisor.ex` | Intelligence subsystem supervisor |

### 9. Signal Theory (`signal/`)
MIOSA's unique differentiator — encoding quality measurement.

| Module | Purpose |
|--------|---------|
| `signal.ex` | Signal struct (Mode, Genre, Type, Format, Structure) |
| `signal/classifier.ex` (544L) | Classify outputs against S/N ratio |

### 10. Platform (`platform/`)
Multi-tenant platform layer (opt-in via DATABASE_URL).

| Module | Purpose |
|--------|---------|
| `repo.ex` | PostgreSQL Ecto repo |
| `auth.ex` | Platform authentication |
| `tenants.ex` | Tenant management |
| `grants.ex` | Permission grants |
| `os_instances.ex` | OS instance management |
| `amqp.ex` | RabbitMQ event publisher |
| `schemas/` | Ecto schemas |

### 11. SDK (`sdk/`)
External SDK for building on OSA.

| Module | Purpose |
|--------|---------|
| `sdk.ex` | SDK entry point |
| `session.ex` | Session management |
| `message.ex` | Message handling |
| `tool.ex` | Tool registration |
| `permission.ex` | Permission system |
| `memory.ex` | Memory access |
| `tier.ex` | Tier configuration |
| `mcp.ex` | MCP integration |
| `supervisor.ex` | SDK process supervisor |

### 12. Vault (`vault/`)
Structured memory system with typed categories, fact extraction, and session lifecycle.

| Module | Purpose |
|--------|---------|
| `vault.ex` | Facade API (remember, recall, context, wake, sleep, checkpoint, inject) |
| `category.ex` | 8 typed memory categories with dir mapping + frontmatter |
| `store.ex` | Markdown filesystem store with YAML frontmatter |
| `observation.ex` | Scored observations with exponential time-based decay |
| `fact_extractor.ex` | ~15 regex patterns for rule-based fact extraction |
| `fact_store.ex` | GenServer + ETS + JSONL with temporal versioning |
| `observer.ex` | Buffered observation pipeline (classify → score → flush) |
| `supervisor.ex` | Supervises FactStore + Observer |
| `session_lifecycle.ex` | Wake/sleep/checkpoint/recover + dirty-death flag files |
| `context_profile.ex` | 4 profiles (default/planning/incident/handoff) with caps |
| `handoff.ex` | Session handoff document creation/loading |
| `inject.ex` | Keyword-matched vault content injection |

### 13. Other Subsystems

| Domain | Key Modules | Purpose |
|--------|-------------|---------|
| **Fleet** | `supervisor`, `registry`, `sentinel`, `dashboard` | Multi-instance coordination |
| **Sidecar** | `manager`, `registry`, `protocol`, `circuit_breaker`, `telemetry` | Go/Python sidecar management |
| **Store** | `repo`, `message`, `task` | SQLite3 persistence |
| **Recipes** | `recipe.ex` (533L) | Multi-step workflow templates |
| **MCP** | `client.ex`, + DynamicSupervisor | Model Context Protocol integration |
| **Commands** | `agents`, `auth`, `channels`, `config`, `data`, `dev`, `info`, `model`, `scheduler_cmd`, `session`, `system` | Slash commands |
| **Security** | `shell_policy.ex` | Shell command allowlist/blocklist |
| **Onboarding** | `onboarding.ex` (1120L), `channels.ex`, `selector.ex` | First-run setup wizard |
| **Protocol** | `cloud_event.ex`, `oscp.ex` | CloudEvents + OSCP protocol |
| **Sandbox** | `pool.ex` | Code sandbox pooling |
| **Go sidecars** | `tokenizer.ex`, `git.ex`, `sysmon.ex` | Go binary sidecars |
| **Python** | `supervisor.ex`, `embeddings.ex` | Python sidecar for embeddings |
| **Tenant** | `config.ex` | Per-tenant configuration |
| **Telemetry** | `metrics.ex` | Telemetry event handling |
| **Workspace** | `workspace.ex` | Working directory management |
| **Soul** | `soul.ex` | Agent personality/identity |
| **PromptLoader** | `prompt_loader.ex` | System prompt loading |
| **MCTS** | `node.ex` + `strategies/mcts/` | Monte Carlo Tree Search |

---

## Extracted Packages (sibling directories)

These were previously embedded in OSA and have been extracted as standalone packages.

| Package | Location | Purpose | Tests |
|---------|----------|---------|-------|
| **miosa_llm** | `../miosa_llm/` | LLM provider utilities: circuit breaker, rate limiting, health checking | 12 |
| **miosa_budget** | `../miosa_budget/` | Token/cost budget tracking with injectable event emitter | 15 |
| **miosa_knowledge** | `../miosa_knowledge/` | Semantic triple store with pluggable backends | — |

OSA depends on all three via `path:` deps in `mix.exs`.

**Bridge modules in OSA:**
- `budget_emitter.ex` — implements `MiosaBudget.Emitter` behaviour, forwards budget events to `Events.Bus`

---

## Data Flow

```
User Input
    |
    v
Channel (CLI / HTTP / Telegram / ...)
    |
    v
Session (DynamicSupervisor)
    |
    v
Agent.Loop -----> Context.build() -----> Provider (Anthropic/Ollama/OpenAI/...)
    |                                          |
    |  <--- LLM response (text + tool_calls) <-+
    |
    v
Tool Executor -----> Hooks.run(:pre_tool_use)
    |                      |
    |                 Tool.execute()
    |                      |
    |                 Hooks.run(:post_tool_use)
    |
    +---> Events.Bus.emit() --> Telemetry, Learning, Budget
    |
    v
Loop continues until: stop token, max turns, budget exceeded, or cancel flag
```

---

## ETS Tables (shared state)

| Table | Purpose | Access |
|-------|---------|--------|
| `:osa_cancel_flags` | Loop cancel flags | public, set |
| `:osa_files_read` | Read-before-write tracking | public, set |
| `:osa_survey_answers` | ask_user HTTP answers | public, set |
| `:osa_context_cache` | Ollama model context sizes | public, set |
| `:osa_hooks` | Hook registrations | public, ordered_set, write_concurrency |
| `:osa_hook_metrics` | Hook execution metrics (atomic counters) | public, set, write_concurrency |
| `:osa_vault_facts` | Vault fact store (temporal versioning) | public, set, read_concurrency |

---

## Key Dependencies

| Dep | Purpose |
|-----|---------|
| `goldrush` | Compiled Erlang event routing (BEAM speed dispatch) |
| `req` | HTTP client for LLM APIs |
| `jason` | JSON encoding/decoding |
| `phoenix_pubsub` | Internal event fan-out |
| `bandit` + `plug` | HTTP server (no Phoenix framework) |
| `ecto_sql` + `ecto_sqlite3` | Local SQLite3 storage |
| `postgrex` | Platform PostgreSQL (opt-in) |
| `bcrypt_elixir` | Password hashing |
| `amqp` | RabbitMQ (opt-in) |
| `file_system` | Filesystem watching (skill hot reload) |
| `yaml_elixir` | YAML parsing |
| `ex_json_schema` | Tool argument validation |
| `telemetry*` | Telemetry ecosystem |

---

## File Size Distribution

| Range | Count | Description |
|-------|-------|-------------|
| 1000+ lines | 4 | memory.ex, tools/registry.ex, onboarding.ex, loop.ex |
| 500-999 lines | 18 | Core agent services, providers, intelligence |
| 200-499 lines | ~60 | Most modules |
| < 200 lines | ~218 | Agent defs, behaviours, helpers, small tools |

**Total: 300 files, ~68K lines**
