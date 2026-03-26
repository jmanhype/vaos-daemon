# Daemon — VAOS Agent Runtime

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Version](https://img.shields.io/badge/Version-0.3.0-orange.svg)](#)

Elixir/OTP agent that classifies every input into a 5-tuple signal before routing it to a tiered LLM provider. 18 providers across 3 compute tiers (elite/specialist/utility). 12 channel adapters. 42 built-in tools. 4 swarm collaboration patterns. Runs locally with optional multi-tenant platform mode. Depends on two sibling libraries: `vaos_ledger` (epistemic governance) and `vaos_knowledge` (triple store).

```
Codebase (measured)
------------------------------------------------------------
Elixir/OTP (lib/)          92,731 lines   418 modules
Desktop (desktop/)         ~36,000 lines  Tauri 2 + SvelteKit 2 + Svelte 5
Rust TUI (priv/rust/tui/)  20,382 lines   Terminal interface, SSE client
Tests (test/)              34,065 lines   3,210 test definitions, 147 files
Go sidecars (priv/go/)        858 lines   Tokenizer, git helper, sysmon
Tauri backend (desktop/
  src-tauri/src/)              603 lines   Rust backend for desktop app
------------------------------------------------------------
Total                     ~185,000 lines
```

## Table of Contents

- [Signal Classification](#signal-classification)
- [3-Tier Routing](#3-tier-routing)
- [Architecture](#architecture)
- [Swarm Orchestration](#swarm-orchestration)
- [Tools](#tools)
- [Providers](#providers)
- [Channels](#channels)
- [Memory and Context](#memory-and-context)
- [Design Decisions](#design-decisions)
- [Known Limitations](#known-limitations)
- [Setup](#setup)
- [Usage](#usage)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [References](#references)
- [License](#license)

## Signal Classification

Every input is classified into a 5-tuple before the agent reasons about it. The classification determines which model handles the request, what strategy to use, and how much compute to allocate.

```
S = (Mode, Genre, Type, Format, Weight)
```

| Dimension | Values | Role |
|-----------|--------|------|
| Mode | `:execute`, `:build`, `:analyze`, `:maintain`, `:assist` | What to do |
| Genre | `:direct`, `:inform`, `:commit`, `:decide`, `:express` | Speech act type |
| Type | `"question"`, `"request"`, `"issue"`, `"scheduling"`, `"summary"`, `"report"`, `"general"` | Domain |
| Format | `:command`, `:message`, `:notification`, `:document` | Container type |
| Weight | 0.0 (trivial) to 1.0 (multi-step) | Informational density |

The classifier (`signal/classifier.ex`, 274 lines) has two paths:

1. **LLM-primary**: Sends the input to the configured provider with a classification prompt, parses the JSON response into the 5-tuple struct.
2. **Deterministic fallback**: Regex-based classification in `MiosaSignal.MessageClassifier` when the LLM is unavailable. Pattern-matches on keywords and message structure.

The struct also carries metadata: `raw` (original input), `channel`, `timestamp`, and `confidence` (`:high` for LLM, `:low` for regex fallback).

## 3-Tier Routing

The tier system maps signal complexity to compute level. Each tier defines token budgets and model assignments.

| Tier | Complexity Range | Example Models | Total Token Budget |
|------|-----------------|----------------|-------------------|
| `:utility` | 1-3 | claude-haiku-4-5, gpt-3.5-turbo, gemini-2.0-flash-lite | 100,000 |
| `:specialist` | 4-6 | claude-sonnet-4-6, gpt-4o-mini, gemini-2.0-flash | 200,000 |
| `:elite` | 7-10 | claude-opus-4-6, gpt-4o, gemini-2.5-pro | 250,000 |

Routing is by integer complexity score (1-10), determined by the orchestrator, not directly by the signal weight float. The tier assignment is in `agent/tier.ex`:

```elixir
def tier_for_complexity(complexity) when complexity <= 3, do: :utility
def tier_for_complexity(complexity) when complexity <= 6, do: :specialist
def tier_for_complexity(_complexity), do: :elite
```

Token budgets per tier are subdivided: system (8-20%), agent (12-15%), tools (8-12%), conversation (24-30%), execution (30%).

Ollama tiers are detected dynamically at boot by scanning installed models, sorting by file size, and mapping largest to elite, medium to specialist, smallest to utility. The mapping is cached in `:persistent_term`.

## Architecture

```
12 Channels
  CLI | HTTP | Telegram | Discord | Slack | WhatsApp | ...
                        |
         Hook Pipeline (priority-ordered middleware)
         security_check -> context_optimizer -> mcp_cache -> ...
                        |
              Signal Classifier
    S = (Mode, Genre, Type, Format, Weight)
    LLM-primary | Deterministic fallback
                        |
              Two-Tier Noise Filter
    Tier 1: <1ms regex | Tier 2: weight thresholds
                        | signals only
              Events.Bus (:daemon_event_router)
              goldrush-compiled Erlang bytecode
       |            |            |            |
   Agent Loop   Orchestrator   Swarm+PACT   Intelligence
   (tier route)  (32 agents)   (4 patterns)  (8 modules)
       |            |            |
              Shared Infrastructure
   Context Builder (token-budgeted, 4-tier priority)
   Compactor (3-zone sliding window)
   Memory (3-store + inverted index + episodic JSONL)
   Vault (8-category structured memory)
   Sandbox (Docker + Wasm + Sprites.dev)
       |            |            |            |
   18 Providers  39 Tools    Memory/Vault   OS Templates
   (3 tiers)     (goldrush    (JSONL)
                  dispatch)
```

### OTP Supervision Tree

Top-level strategy is `:rest_for_one` -- a crash in Infrastructure tears down Sessions, AgentServices, and Extensions above it.

```
Daemon.Supervisor (rest_for_one)
|
+-- Platform.Repo (PostgreSQL, conditional on platform_enabled config)
|
+-- Supervisors.Infrastructure (rest_for_one)
|   +-- SessionRegistry          Process registry for agent sessions
|   +-- Events.TaskSupervisor    Supervised async work
|   +-- PubSub                   Phoenix.PubSub (standalone, no Phoenix)
|   +-- Events.Bus               goldrush-compiled event routing
|   +-- Events.DLQ               Dead letter queue
|   +-- Bridge.PubSub            Event fan-out bridge
|   +-- Store.Repo               SQLite3 persistent storage
|   +-- EventStream              SSE event streaming
|   +-- Telemetry.Metrics        Event-driven metrics collection
|   +-- MiosaLLM.HealthChecker   Provider health + circuit breaker
|   +-- Providers.Registry       18 LLM providers, 3-tier routing
|   +-- Tools.Registry           Tool dispatcher (goldrush-compiled)
|   +-- Tools.Cache              Tool result caching
|   +-- Machines                 Composable skill sets
|   +-- Commands                 Slash commands
|   +-- OS.Registry              Template discovery
|   +-- MCP.Registry             MCP server registry
|   +-- MCP.Supervisor           DynamicSupervisor for MCP servers
|
+-- Supervisors.Sessions (one_for_one)
|   +-- Channels.Supervisor      DynamicSupervisor for 12 channel adapters
|   +-- EventStreamRegistry      Per-session SSE event streams
|   +-- SessionSupervisor        DynamicSupervisor for Agent Loop processes
|
+-- Supervisors.AgentServices (one_for_one)
|   +-- Agent.Memory             3-store architecture + episodic JSONL
|   +-- Agent.HeartbeatState     Session heartbeat tracking
|   +-- Agent.Tasks              Task management (replaced TaskQueue + TaskTracker)
|   +-- MiosaBudget.Budget       Token budget management
|   +-- Agent.Orchestrator       Multi-agent spawning + synthesis
|   +-- Agent.Progress           Real-time progress reporting
|   +-- Agent.Hooks              Priority-ordered middleware pipeline
|   +-- Agent.Learning           Pattern learning system
|   +-- MiosaKnowledge.Store     vaos_knowledge triple store bridge
|   +-- Memory.KnowledgeBridge   Knowledge <-> Memory bridge
|   +-- Vault.Supervisor         Structured memory (FactStore + Observer)
|   +-- Agent.Scheduler          Cron + heartbeat scheduling
|   +-- Agent.Compactor          3-zone context compression
|   +-- Agent.Cortex             Context aggregation delegate
|   +-- Agent.ProactiveMode      Autonomous proactive actions
|   +-- Webhooks.Dispatcher      Outbound webhook delivery
|   +-- Signal.Persistence       Signal classification persistence
|
+-- Supervisors.Extensions (one_for_one)
|   +-- Treasury                 Token treasury (opt-in)
|   +-- Orchestrator.Mailbox     Inter-agent message routing
|   +-- Orchestrator.SwarmMode   Swarm coordination state
|   +-- Swarm.DynamicSupervisor  DynamicSupervisor for swarm workers
|   +-- Fleet.Supervisor         Multi-instance fleet (opt-in)
|   +-- Go.Tokenizer             Go tokenizer sidecar (opt-in)
|   +-- Python.Supervisor        Python sidecar (opt-in)
|   +-- Go.Git                   Go git helper sidecar (opt-in)
|   +-- Go.Sysmon               Go system monitor sidecar (opt-in)
|   +-- WhatsAppWeb              WhatsApp Web sidecar (opt-in)
|   +-- Sandbox.Supervisor       Docker + Wasm + Sprites.dev (opt-in)
|   +-- Wallet                   Payment integration (opt-in)
|
+-- Channels.Starter             Deferred channel boot
+-- Bandit HTTP                  REST API on port 8089
```

7 ETS tables are created at Application.start: `:daemon_cancel_flags`, `:daemon_files_read`, `:daemon_survey_answers`, `:daemon_context_cache`, `:daemon_survey_responses`, `:daemon_session_provider_overrides`, `:daemon_pending_questions`.

## Swarm Orchestration

4 execution patterns defined in `swarm/patterns.ex` (476 lines):

| Pattern | Mechanism | Use Case |
|---------|-----------|----------|
| `:parallel` | `Task.async_stream` with 300s timeout | Independent subtasks (analysis, search) |
| `:pipeline` | Sequential: Agent A output -> Agent B input | Dependent stages (research -> implement -> test) |
| `:debate` | N-1 agents propose in parallel, last evaluates | Consensus building, design decisions |
| `:review_loop` | Coder produces, reviewer critiques, max 3 iterations | Code review, quality gates |

10 named pattern configurations ship in `priv/swarms/patterns.json`: code-analysis, full-stack, debug-swarm, performance-audit, security-audit, documentation, adaptive-debug, adaptive-feature, concurrent-migration, ai-pipeline.

**PACT framework** (`swarm/pact.ex`, 681 lines): Planning -> Action -> Coordination -> Testing with quality gates between each phase. Configurable quality threshold (default 0.7). Supports rollback on failure.

**Agent roster**: 32 agent module definitions in `agents/` (31 specialists + 1 master orchestrator).

**Swarm modules** (8 total): intelligence.ex, mailbox.ex, orchestrator.ex, pact.ex, patterns.ex, planner.ex, supervisor.ex, worker.ex.

## Tools

42 built-in tools registered in `Tools.Registry.load_builtin_tools/0`:

| Category | Tools |
|----------|-------|
| File operations | `file_read`, `file_write`, `file_edit`, `file_glob`, `file_grep`, `dir_list`, `multi_file_edit`, `diff` |
| Code intelligence | `code_symbols`, `codebase_explore`, `semantic_search`, `investigate`, `mcts_index` |
| Shell and system | `shell_execute`, `compute_vm`, `code_sandbox` |
| Web | `web_search`, `web_fetch`, `browser`, `computer_use` |
| Memory and vault | `memory_save`, `memory_recall`, `vault_remember`, `vault_context`, `vault_wake`, `vault_sleep`, `vault_checkpoint`, `vault_inject` |
| Agent coordination | `orchestrate`, `delegate`, `task_write`, `ask_user` |
| Skills | `create_skill`, `use_skill`, `skill_manager` |
| Version control | `git`, `github` |
| Notebook | `notebook_edit` |
| Session | `session_search`, `budget_status`, `wallet_ops` |

The `investigate` tool (1,862 lines) is notable: it runs full epistemic research with adversarial dual-prompt architecture. Three parallel literature searches (Semantic Scholar + OpenAlex + alphaXiv) feed FOR and AGAINST researchers. Citation verification checks every claim against actual paper abstracts. Evidence hierarchy scoring weights by publication type and citation count. Results are persisted to an AIEQ-Core epistemic ledger with Bayesian belief tracking. See `vaos_ledger` for the underlying defense stack.

MCP tools discovered at runtime from `~/.daemon/mcp.json` are available alongside built-in tools.

## Providers

18 providers in `providers/registry.ex`:

| Implementation | Providers |
|---------------|-----------|
| Native module | `anthropic`, `google`, `cohere`, `replicate`, `ollama` |
| OpenAI-compatible (shared module) | `openai`, `groq`, `together`, `fireworks`, `deepseek`, `perplexity`, `mistral`, `openrouter`, `qwen`, `moonshot`, `zhipu`, `volcengine`, `baichuan` |

Each provider maps to 3 tiers. Example tier assignments:

| Provider | Elite | Specialist | Utility |
|----------|-------|-----------|---------|
| anthropic | claude-opus-4-6 | claude-sonnet-4-6 | claude-haiku-4-5 |
| openai | gpt-4o | gpt-4o-mini | gpt-3.5-turbo |
| google | gemini-2.5-pro | gemini-2.0-flash | gemini-2.0-flash-lite |
| ollama | (auto-detected by model file size) | | |

Fallback chain with circuit breaker via `MiosaLLM.HealthChecker`. Rate-limited retry with exponential backoff (max 3 attempts). If the primary provider fails, the next healthy provider in the same tier picks up the request.

```bash
# Set provider via environment
export DAEMON_DEFAULT_PROVIDER=groq
export GROQ_API_KEY=gsk_...
```

## Channels

12 channel adapters in `channels/`:

| Channel | Module | Status | Notes |
|---------|--------|--------|-------|
| CLI | `cli.ex` + 5 sub-modules | Working | Built-in terminal with line editor, markdown rendering, spinner |
| HTTP/REST | `http.ex` + 37 route modules | Working | SDK API on port 8089, JWT auth optional |
| Telegram | `telegram.ex` | Working | Webhook + polling, group support |
| Discord | `discord.ex` | Implemented, not production-tested | Bot gateway |
| Slack | `slack.ex` | Implemented, not production-tested | Events API, HMAC-SHA256 verification |
| WhatsApp | `whatsapp.ex` | Implemented, not production-tested | Business API |
| Signal | `signal.ex` | Implemented, not production-tested | Signal CLI bridge |
| Matrix | `matrix.ex` | Implemented, not production-tested | Federation protocol |
| Email | `email.ex` | Implemented, not production-tested | IMAP polling + SMTP sending |
| QQ | `qq.ex` | Implemented, not production-tested | OneBot protocol |
| DingTalk | `dingtalk.ex` | Implemented, not production-tested | Robot webhook, HMAC-SHA256 signing |
| Feishu/Lark | `feishu.ex` | Implemented, not production-tested | Event subscriptions, AES decryption |

Each adapter handles webhook signature verification, rate limiting, and message format translation. Channels beyond CLI, HTTP, and Telegram have not been validated in production environments.

## Memory and Context

### Context Builder

Two-tier system in `agent/context.ex` (758 lines):

- **Tier 1 (Static)**: Cached in `persistent_term` via `Soul.static_base()`. Includes SYSTEM.md, tool definitions, rules, user profile, and Signal Theory tables. Anthropic cache hint (`cache_control: %{type: "ephemeral"}`) applied to the static block.
- **Tier 2 (Dynamic)**: Per-request, token-budgeted. 11 dynamic blocks: tool_process, runtime, environment, plan_mode, memory, episodic, task_state, workflow, skills, scratchpad, vault.

Budget formula: `dynamic_budget = max_tokens - reserve(8192) - conversation_tokens - static_tokens`

### Compactor

Three-zone sliding window in `agent/compactor.ex` (735 lines):

| Zone | Messages | Treatment |
|------|----------|-----------|
| HOT | Last 20 | Full fidelity |
| WARM | 21-50 | Progressive compression (LLM-summarized) |
| COLD | 51+ | Key-facts summary (importance-weighted) |

Importance-weighted retention: tool calls +50%, long content +30% (capped), acknowledgments -50%.

### Memory Stores

| Store | Backing | Scope |
|-------|---------|-------|
| Session | JSONL per-session | Current conversation |
| Long-term | MEMORY.md | Cross-session |
| Episodic | ETS inverted index | Keyword -> session mapping |

### Vault

Structured memory system in `vault/` (12 modules):

```
~/.daemon/vault/
+-- facts/          +-- decisions/      +-- lessons/
+-- preferences/    +-- commitments/    +-- relationships/
+-- projects/       +-- observations/   +-- handoffs/
+-- .vault/
    +-- facts.jsonl       Temporal fact store (append-only, versioned)
    +-- checkpoints/      Mid-session save points
    +-- dirty/            Dirty-death detection flags
```

8 memory categories with YAML frontmatter. ~15 regex patterns extract structured facts from free text without LLM calls. Observations get a relevance score (0.0-1.0) that decays exponentially over time. 4 context profiles (default/planning/incident/handoff) control what vault content enters the prompt.

6 tools: `vault_remember`, `vault_context`, `vault_wake`, `vault_sleep`, `vault_checkpoint`, `vault_inject`.

## Design Decisions

**Signal classification before routing.** Every input is classified by intent, domain, and complexity before touching the reasoning engine. Rationale: prevents expensive models from handling trivial requests, and ensures complex tasks get appropriate compute. Tradeoff: classification adds latency (one LLM call or regex match) to every interaction.

**goldrush for event routing.** Events.Bus and Tools.Registry compile Erlang bytecode modules (`:daemon_event_router`, `:daemon_tool_dispatcher`) using goldrush's `glc` API. Rationale: compiled bytecode dispatch is faster than GenServer-based routing for high-throughput event streams. Recompiled on tool hot-registration. Tradeoff: debugging compiled dispatch is harder than following GenServer calls. Uses a GitHub fork (`robertohluna/goldrush`).

**DynamicSupervisor for channels.** Each channel adapter runs under a DynamicSupervisor. Rationale: crash isolation -- a failing Telegram adapter does not take down the CLI or HTTP channel. Tradeoff: no static supervision guarantees; channel availability depends on successful dynamic start.

**Path dependencies for co-development.** `vaos_ledger` and `vaos_knowledge` are referenced as path deps, not Hex packages. Rationale: all three repos evolve together; path deps allow cross-repo changes without publishing. Tradeoff: all three repos must be cloned to expected relative paths.

**Phoenix.PubSub without Phoenix.** PubSub is used standalone for internal event fan-out between subsystems. Rationale: mature, well-tested library for topic-based messaging without pulling in the full Phoenix web framework. Bridge.PubSub connects goldrush events to PubSub topics.

**SQLite3 + Ecto for local persistence.** Store.Repo uses `ecto_sqlite3` for cost tracking, signals, and agent budgets. PostgreSQL (`postgrex`) is conditional on `platform_enabled` config for multi-tenant mode. Rationale: SQLite requires no external database server for single-user local operation.

## Known Limitations

- **gRPC encoding not implemented; HTTP fallback is live.** `daemon/vas_swarm/grpc_client.ex` connects to vaos-kernel via `gun.open` but `call_grpc/3` cannot encode protobuf (TODO). All 4 RPC methods (`request_token`, `submit_telemetry`, `submit_routing_log`, `confirm_audit`) have working HTTP fallbacks that hit vaos-kernel's REST API at `VAOS_KERNEL_HTTP_URL`. Token requests, telemetry, and routing logs all work over HTTP when gRPC is unavailable.

- **Signal classification cache not implemented.** The classifier moduledoc references "ETS-backed, 10-minute TTL" but `MiosaSignal.MessageClassifier` in `miosa/shims.ex` has no ETS caching. `classify_fast/2` directly calls `classify_deterministic/2` with no cache lookup or SHA256 key generation.

- **Channels beyond CLI/HTTP/Telegram are untested in production.** 9 of 12 channel adapters (Discord, Slack, WhatsApp, Signal, Matrix, Email, QQ, DingTalk, Feishu) have code but no evidence of production deployment or integration testing.

- **Path deps required.** `vaos_ledger` and `vaos_knowledge` must be cloned to `../vaos-ledger` and `../vaos-knowledge` respectively. Without them, compilation fails.

- **Rustler removed for OTP 28.** Line 82 of `mix.exs`: `# {:rustler, "~> 0.37", optional: true}` with note "OTP 28: rustler removed -- nif.ex uses pure Elixir fallbacks." NIF-dependent features use Elixir implementations.

- **CostTracker depends on SQLite3 migrations.** `agent/cost_tracker.ex` uses raw SQL (`INSERT ... ON CONFLICT DO UPDATE SET`) against `cost_events` and `agent_budgets` tables. These tables require Ecto migrations that may not have been run.

- **Homebrew tap does not exist.** No `brew tap` or `brew install` is available. Install from source.

## Setup

### Prerequisites

- Elixir >= 1.17
- Erlang/OTP >= 27
- Rust/Cargo (for TUI)
- Node.js 18+ (for desktop, optional)

### Clone All 3 Repos

The path dependencies expect this directory layout:

```
~/Projects/          (or any parent directory)
+-- vaos-daemon/           this repo
+-- vaos-ledger-build/   github.com/jmanhype/vaos-ledger
+-- vaos-knowledge/      github.com/jmanhype/vaos-knowledge
```

```bash
git clone <vaos-daemon-url> vaos-daemon
git clone <vaos-ledger-url> vaos-ledger-build
git clone <vaos-knowledge-url> vaos-knowledge

cd vaos-daemon
mix deps.get
mix compile
```

### Configuration

```bash
# Set provider and API key
export DAEMON_DEFAULT_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# Or use Ollama for local inference (no API key needed)
export DAEMON_DEFAULT_PROVIDER=ollama
```

### Docker

```bash
docker compose up -d
```

The compose file includes Daemon + Ollama with healthchecks and automatic dependency ordering.

## Usage

### CLI

```bash
bin/daemon                    # Backend + Rust TUI
mix daemon.chat               # Backend + built-in Elixir CLI (no TUI)
mix daemon.serve              # Backend only (for custom clients or desktop app)
```

### HTTP API

REST API on port 8089:

```bash
# Health check
curl http://localhost:8089/health

# Classify a message (Signal Theory 5-tuple)
curl -X POST http://localhost:8089/api/v1/classify \
  -H "Content-Type: application/json" \
  -d '{"message": "What is our Q3 revenue trend?"}'

# Run the full agent loop
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Content-Type: application/json" \
  -d '{"input": "Analyze our sales pipeline", "session_id": "my-session"}'

# Launch a swarm
curl -X POST http://localhost:8089/api/v1/swarm/launch \
  -H "Content-Type: application/json" \
  -d '{"task": "Review codebase for security issues", "pattern": "review_loop"}'

# List available models
curl http://localhost:8089/api/v1/models

# Stream events (SSE)
curl http://localhost:8089/api/v1/stream/my-session
```

JWT authentication: set `DAEMON_SHARED_SECRET` and `DAEMON_REQUIRE_AUTH=true`.

### MCP Configuration

```json
// ~/.daemon/mcp.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    }
  }
}
```

MCP tools are auto-discovered at boot and available alongside built-in tools.

### Desktop Command Center

```bash
cd desktop
npm install
npm run tauri:dev       # Development (hot-reload)
npm run tauri:build     # Production build
```

Connects to the Daemon backend on port 8089. Start the backend first.

### Custom Skills

Drop a markdown file in `~/.daemon/skills/your-skill/SKILL.md`:

```markdown
---
name: data-analyzer
description: Analyze datasets and produce insights
tools:
  - file_read
  - shell_execute
---

## Instructions

When asked to analyze data:
1. Read the file to understand its structure
2. Use shell commands to run analysis
3. Produce a summary with key findings
```

Available immediately -- no restart required.

## Testing

The test suite contains 3,210+ test definitions across 147 files (34,065 lines). The suite compiles and runs.

```bash
$ mix test
Finished in 182.6 seconds
3,210 tests, 1 failure (ComputerUse screenshot requires macOS screencapture)
```

Run `mix ecto.migrate` first if you see `no such table` errors (SQLite3 migrations required for CostTracker and signal persistence).

## Project Structure

```
lib/
  daemon/          Main codebase (418 modules across 44 subdirectories)
    agent/                       Core agent: loop, context, memory, compactor, cost_tracker
    agents/                      32 named agent definitions (31 specialists + 1 orchestrator)
    channels/                    12 channel adapters + HTTP routes (37 route modules)
    cli/                         Terminal interface: line editor, markdown, spinner
    events/                      Events.Bus (goldrush), DLQ, TaskSupervisor
    mcp/                         MCP server management (anubis_mcp)
    providers/                   18 LLM providers, registry, health checker
    signal/                      Signal classifier (5-tuple)
    store/                       Ecto + SQLite3 persistence
    supervisors/                 4 subsystem supervisors
    swarm/                       4 patterns, PACT framework, orchestrator, mailbox
    tools/                       42 built-in tools, registry (goldrush-compiled)
    vault/                       12 modules: fact store, observer, context profiles
    ...                          + 30 more subdirectories (sandbox, platform, fleet, etc.)
  miosa/                         2 files: memory_store.ex (1,182 lines), shims.ex
  vas_swarm/                     4 files: application.ex, chat.ex, decorator.ex, registry.ex
  mix/tasks/                     4 mix tasks: daemon.chat, daemon.sandbox.setup, daemon.serve, daemon.setup

desktop/                         Tauri 2 + SvelteKit 2 + Svelte 5 desktop app
  src/                           78 Svelte components, 39 TypeScript files
  src-tauri/                     Rust backend (603 lines)

priv/
  rust/tui/                      Rust TUI client (20,382 lines)
  go/                            Go sidecars: tokenizer, git, sysmon (858 lines)
  swarms/patterns.json           10 named swarm configurations
```

## References

- Luna, R. H. (2026). "Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems." Zenodo. https://zenodo.org/records/18774174
- Shannon, C. E. (1948). "A Mathematical Theory of Communication." *Bell System Technical Journal*, 27(3), 379-423.
- Ashby, W. R. (1956). *An Introduction to Cybernetics*. Chapman & Hall. -- Requisite variety: system variety must match input variety.
- Beer, S. (1972). *Brain of the Firm*. Allen Lane. -- Viable System Model: 5 operational modes for organizational viability.
- Wiener, N. (1948). *Cybernetics: Or Control and Communication in the Animal and the Machine*. MIT Press. -- Feedback loops in control systems.

## License

Apache 2.0 -- See [LICENSE](LICENSE).
