# OSA — the Optimal System Agent

> One AI that maximizes signal, eliminates noise, and finds the optimal path — across code, work, and life. Elixir/OTP + Rust TUI. Runs locally. Open-source.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/Tests-1958-brightgreen.svg)](#)
[![Version](https://img.shields.io/badge/Version-0.2.5-orange.svg)](#)

---

## Why OSA Exists

Every agent framework processes every message the same way. "Build me a REST API with auth" gets the same pipeline as "What time is it?" Same model, same context window, same latency, same cost. No understanding of what the message actually *is* before throwing compute at it.

We built OSA to fix this. It's the AI layer of [MIOSA](https://miosa.ai) — an operating system for running your entire business. One agent handling everything: code, operations, communication, analysis, orchestration. The foundation is Signal Theory: every input is classified by intent, domain, and complexity *before* it touches the reasoning engine. The right model gets the right task. Multi-step problems get decomposed into parallel sub-agents. The agent remembers what worked and what didn't across sessions.

~112,000 lines of Elixir/OTP. ~2,000 tests. Runs locally. Your data stays yours.

```
Codebase Breakdown
──────────────────────────────────────────
Elixir/OTP (lib/)          69,000 lines   Core agent, orchestration, providers,
                                          channels, tools, swarm, sandbox
Rust TUI (priv/rust/tui/)  20,000 lines   Terminal interface, SSE client,
                                          auth, rendering
Tests (test/)              22,000 lines   ~2,000 tests across all modules
Go utilities (priv/go/)       900 lines   Tokenizer, git helper, sysmon
Config                        500 lines   Runtime, dev, test, prod
──────────────────────────────────────────
Total                     ~112,000 lines
```

---

## What Makes OSA Different

### 1. Signal Classification

Before the agent reasons about anything, it understands what you're asking. Every input is classified into a 5-tuple that determines how it gets processed — which model handles it, what strategy to use, how much compute to spend:

```
S = (Mode, Genre, Type, Format, Weight)

Mode:   What to do     — BUILD, EXECUTE, ANALYZE, MAINTAIN, ASSIST
Genre:  Speech act     — DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type:   Domain         — question, request, issue, scheduling, summary, report
Format: Container      — message, command, document, notification
Weight: Complexity     — 0.0 (trivial) → 1.0 (critical, multi-step)
```

"Help me build a rocket" → BUILD mode, high weight → routes to the most capable model with orchestration. "What time is it?" → ASSIST mode, low weight → fast model, direct answer, no overhead. The classifier is LLM-primary with a deterministic fallback when the LLM is unavailable. Results are cached in ETS (SHA256 key, 10-minute TTL).

### 2. Intelligent Routing

The classification drives everything downstream:

```
Weight 0.0–0.35  →  Utility tier (Haiku, GPT-3.5, 8B models) — fast, cheap
Weight 0.35–0.65 →  Specialist tier (Sonnet, GPT-4o-mini, 70B) — balanced
Weight 0.65–1.0  →  Elite tier (Opus, GPT-4o, Pro models) — full reasoning
```

A simple lookup doesn't need Opus. A complex refactor doesn't belong on Haiku. The system matches compute to complexity automatically — no manual model switching.

### 3. Autonomous Task Orchestration

Complex tasks get decomposed into parallel sub-agents:

```
User: "Build me a REST API with auth, tests, and docs"

OSA Orchestrator:
  ├── Research agent — analyzing codebase
  ├── Builder agent  — writing implementation
  ├── Tester agent   — writing tests
  └── Writer agent   — writing documentation

Synthesis: 4 agents completed — files created, tests passing, docs written.
```

The orchestrator analyzes complexity via LLM, decomposes into dependency-aware waves, spawns sub-agents with role-specific prompts, tracks real-time progress via event bus, and synthesizes results.

### 4. Multi-Agent Swarm Collaboration

```elixir
# Four collaboration patterns
:parallel     # All agents work simultaneously
:pipeline     # Agent output feeds into next agent
:debate       # Agents argue, consensus emerges
:review_loop  # Build → review → fix → re-review
```

Mailbox-based inter-agent messaging. Dependency-aware wave execution. PACT framework (Planning → Action → Coordination → Testing) with quality gates at every phase.

### 5. Sandbox Isolation (Docker, Wasm, Sprites.dev)

Three sandbox backends for isolated code execution:

| Backend | Isolation | Use Case |
|---------|-----------|----------|
| **Docker** | Full OS — read-only root, CAP_DROP ALL, network isolation | Production, untrusted code |
| **Wasm** | wasmtime with fuel limits and restricted filesystem | Lightweight, fast startup |
| **Sprites.dev** | Firecracker microVMs with checkpoint/restore | Cloud sandboxes, persistent state |

Per-agent sandbox allocation via the Registry. Warm container pool for Docker. All backends implement a common `Sandbox.Behaviour`.

### 6. 18 LLM Providers × 3 Tiers

Every provider maps to three compute tiers — elite, specialist, utility:

```
anthropic:  claude-opus-4-6      → claude-sonnet-4-6     → claude-haiku-4-5
openai:     gpt-4o               → gpt-4o-mini           → gpt-3.5-turbo
google:     gemini-2.5-pro       → gemini-2.0-flash      → gemini-2.0-flash-lite
groq:       llama-3.3-70b        → llama-3.1-70b         → llama-3.1-8b-instant
ollama:     [auto-detected by model size — largest→elite, smallest→utility]
...and 13 more providers
```

Shared `OpenAICompat` base for 14 providers. Native implementations for Anthropic, Google, Cohere, Replicate, and Ollama. Automatic fallback chain: if primary fails, next provider picks up. Ollama tiers are detected dynamically at boot.

```bash
export OSA_DEFAULT_PROVIDER=groq
export GROQ_API_KEY=gsk_...
# Done. OSA now uses Groq for all inference.
```

### 7. Communication Intelligence

Five modules that understand how people communicate:

| Module | What It Does |
|--------|-------------|
| **Communication Profiler** | Learns each contact's style — response time, formality, topic preferences |
| **Communication Coach** | Scores outbound message quality before sending — clarity, tone, completeness |
| **Conversation Tracker** | Tracks depth from casual chat to deep strategic discussion (4 levels) |
| **Proactive Monitor** | Watches for silence, drift, and engagement drops — triggers alerts |
| **Contact Detector** | Identifies who's talking in under 1 millisecond |

### 8. Context & Memory

**Token-budgeted context assembly:**
```
CRITICAL (unlimited): System identity, active tools
HIGH     (40%):       Recent conversation turns, current task state
MEDIUM   (30%):       Relevant memories (keyword-searched, not full dump)
LOW      (remaining): Workflow context, environmental info
```

**Three-zone compression:** HOT (last 10 msgs, full fidelity) → WARM (progressive compression) → COLD (key facts only, importance-weighted).

**Three-store memory:** Session JSONL, persistent MEMORY.md, ETS inverted index for keyword → session mapping.

### 9. Hook Middleware Pipeline

Priority-ordered hooks fire at lifecycle events:

```
security_check (p10)     — Block dangerous tool calls
context_optimizer (p12)  — Track tool load, warn on heavy usage
mcp_cache (p15)          — Cache MCP schemas in persistent_term
budget_tracker (p25)     — Token budget enforcement
quality_check (p30)      — Output quality scoring
episodic_memory (p60)    — Write JSONL episodes
metrics_dashboard (p80)  — JSONL metrics + periodic summary
...
```

Each hook returns `{:ok, payload}`, `{:block, reason}`, or `:skip`. Blocked = pipeline stops.

---

## 12 Chat Channels

| Channel | Features |
|---------|----------|
| **CLI** | Built-in terminal interface |
| **HTTP/REST** | SDK API surface on port 8089 |
| **Telegram** | Webhook + polling, group support |
| **Discord** | Bot gateway, slash commands |
| **Slack** | Events API, slash commands, blocks |
| **WhatsApp** | Business API, webhook verification |
| **Signal** | Signal CLI bridge, group support |
| **Matrix** | Federation-ready, E2EE support |
| **Email** | IMAP polling + SMTP sending |
| **QQ** | OneBot protocol |
| **DingTalk** | Robot webhook, outgoing messages |
| **Feishu/Lark** | Event subscriptions, card messages |

Each channel adapter handles webhook signature verification, rate limiting, and message format translation.

---

## Install

### Homebrew (macOS / Linux)

```bash
brew tap miosa-osa/tap
brew install osagent
osagent
```

### One-liner (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | sh
osagent
```

The installer detects OS/arch, auto-installs Rust and Elixir if missing, builds both components, and installs `osa` and `osagent` to `~/.local/bin/`.

### From Source

```bash
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
mix setup              # deps + database + compile
bin/osa                # start talking
```

Requires Elixir 1.17+, Erlang/OTP 27+, Rust/Cargo (for TUI).

### Docker

```bash
docker compose up -d
```

The compose file includes OSA + Ollama with healthchecks and automatic dependency ordering. The production container runs as a non-root `osa` user with minimal privileges.

---

## Quick Start

| Command | What it does |
|---|---|
| `osa` | **Recommended.** Backend + Rust TUI in one command. Works from any directory. |
| `osa --dev` | Dev mode (profile isolation, port 19001) |
| `osa setup` | Run the setup wizard (provider, API keys) |
| `mix osa.chat` | Backend + built-in Elixir CLI (no TUI) |
| `mix osa.serve` | Backend only (for custom clients) |
| `osagent` | TUI binary only (connects to running backend) |

**First time?** Just run `osa`. It auto-detects first run and launches the setup wizard.

### Switch Providers

```bash
# Local AI (default — free, private, no API key)
osa setup              # select Ollama

# Cloud — pick any of 18 providers
osa setup              # select Anthropic, OpenAI, Groq, DeepSeek, etc.

# Or set env vars directly (in ~/.osa/.env)
OSA_DEFAULT_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
```

---

## HTTP API

OSA exposes a REST API on port 8089:

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

# Launch an agent swarm
curl -X POST http://localhost:8089/api/v1/swarm/launch \
  -H "Content-Type: application/json" \
  -d '{"task": "Review codebase for security issues", "pattern": "review_loop"}'

# List available models
curl http://localhost:8089/api/v1/models

# Stream events (SSE)
curl http://localhost:8089/api/v1/stream/my-session
```

JWT authentication supported for production — set `OSA_SHARED_SECRET` and `OSA_REQUIRE_AUTH=true`. The SSE stream and HTTP client auto-refresh expired tokens transparently.

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                      12 Channels                           │
│  CLI │ HTTP │ Telegram │ Discord │ Slack │ WhatsApp │ ...  │
└───────────────────────┬───────────────────────────────────┘
                        │
┌───────────────────────▼───────────────────────────────────┐
│     Hook Pipeline (priority-ordered middleware)             │
│     security_check → context_optimizer → mcp_cache → ...   │
└───────────────────────┬───────────────────────────────────┘
                        │
┌───────────────────────▼───────────────────────────────────┐
│            Signal Classifier (LLM-primary)                 │
│    S = (Mode, Genre, Type, Format, Weight)                 │
│    ETS cache │ Deterministic fallback                      │
└───────────────────────┬───────────────────────────────────┘
                        │
┌───────────────────────▼───────────────────────────────────┐
│         Two-Tier Noise Filter                              │
│    Tier 1: <1ms regex │ Tier 2: weight thresholds          │
└───────────────────────┬───────────────────────────────────┘
                        │ signals only
┌───────────────────────▼───────────────────────────────────┐
│         Events.Bus (:osa_event_router)                     │
│         goldrush-compiled Erlang bytecode                  │
└───┬──────────┬──────────┬──────────┬─────────────────────┘
    │          │          │          │
┌───▼───┐ ┌───▼─────┐ ┌──▼────┐ ┌──▼───────────┐
│ Agent │ │Orchest- │ │ Swarm │ │Intelligence  │
│ Loop  │ │rator   │ │ +PACT │ │  (5 mods)    │
│       │ │         │ │       │ │              │
│ Tier  │ │ Roster  │ │ Intel │ │ Profiler     │
│ Route │ │ 52 defs │ │ Votes │ │ Coach        │
└───┬───┘ └───┬─────┘ └──┬────┘ │ Tracker      │
    │         │          │      │ Monitor      │
    │         │          │      │ Detector     │
    │         │          │      └──────────────┘
  ┌─▼─────────▼──────────▼─────────────────────────────────┐
  │             Shared Infrastructure                       │
  │  Context Builder (token-budgeted, 4-tier priority)     │
  │  Compactor (3-zone sliding window, importance-weighted) │
  │  Memory (3-store + inverted index + episodic JSONL)    │
  │  Cortex (knowledge synthesis)                          │
  │  Scheduler (cron + heartbeat)                          │
  │  Sandbox (Docker + Wasm + Sprites.dev)                 │
  └────────────────────────────────────────────────────────┘
       │           │          │          │
  ┌────▼────┐ ┌───▼─────┐ ┌──▼────┐ ┌───▼──────┐
  │18 LLM   │ │Skills   │ │Memory │ │  OS      │
  │Providers│ │Registry │ │(JSONL)│ │Templates │
  │ 3 tiers │ │37 defs  │ │       │ │          │
  └─────────┘ │91 cmds  │ └───────┘ └──────────┘
              └─────────┘
```

### OTP Supervision Tree

Every component is supervised across 4 subsystem supervisors. If any part crashes, OTP restarts just that component — no downtime, no data loss, no manual intervention. The top-level uses `rest_for_one` so a crash in Infrastructure tears down everything above it.

```
OptimalSystemAgent.Supervisor (rest_for_one)
│
├── Platform.Repo (PostgreSQL — conditional, multi-tenant)
│
├── Supervisors.Infrastructure (rest_for_one)
│   ├── SessionRegistry          Process registry for agent sessions
│   ├── Events.TaskSupervisor    Supervised async work
│   ├── PubSub                   Phoenix.PubSub core messaging
│   ├── Events.Bus               goldrush-compiled event routing
│   ├── Events.DLQ               Dead letter queue
│   ├── Bridge.PubSub            Event fan-out bridge
│   ├── Store.Repo               SQLite3 persistent storage
│   ├── Telemetry.Metrics        Event-driven metrics collection
│   ├── MiosaLLM.HealthChecker   Provider health + circuit breaker
│   ├── Providers.Registry       18 LLM providers, 3-tier routing
│   ├── Tools.Registry           Tool dispatcher (goldrush-compiled)
│   ├── Machines                 Composable skill sets
│   ├── Commands                 91 built-in + custom slash commands
│   ├── OS.Registry              Template discovery + connection
│   └── MCP.Supervisor           DynamicSupervisor for MCP servers
│
├── Supervisors.Sessions (one_for_one)
│   ├── Channels.Supervisor      DynamicSupervisor — 12 channel adapters
│   ├── EventStreamRegistry      Per-session SSE event streams
│   └── SessionSupervisor        DynamicSupervisor — Agent Loop processes
│
├── Supervisors.AgentServices (one_for_one)
│   ├── Agent.Memory             3-store architecture + episodic JSONL
│   ├── Agent.HeartbeatState     Session heartbeat tracking
│   ├── Agent.Workflow           Workflow state machine
│   ├── MiosaBudget.Budget       Token budget management
│   ├── Agent.TaskQueue          Task queuing + prioritization
│   ├── Agent.Orchestrator       Multi-agent spawning + synthesis
│   ├── Agent.Progress           Real-time progress reporting
│   ├── Agent.TaskTracker        Task lifecycle tracking
│   ├── Agent.Hooks              Priority-ordered middleware pipeline
│   ├── Agent.Learning           Pattern learning system
│   ├── Agent.Scheduler          Cron + heartbeat scheduling
│   ├── Agent.Compactor          3-zone context compression
│   ├── Agent.Cortex             Knowledge synthesis
│   └── Agent.ProactiveMode      Autonomous proactive actions
│
├── Supervisors.Extensions (one_for_one)
│   ├── Treasury                 Token treasury (opt-in)
│   ├── Intelligence.Supervisor  5 communication modules
│   ├── Fleet.Supervisor         Multi-instance fleet (opt-in)
│   ├── Sidecar.Manager          Go/Python sidecar lifecycle
│   │   ├── Go.Tokenizer         Fast tokenization sidecar
│   │   ├── Go.Git               Git operations sidecar
│   │   ├── Go.Sysmon            System monitoring sidecar
│   │   ├── Python.Supervisor    Python execution sidecar
│   │   └── WhatsAppWeb          Baileys WhatsApp bridge
│   ├── Sandbox.Supervisor       Docker + Wasm + Sprites.dev (opt-in)
│   ├── Wallet                   Payment integration (opt-in)
│   ├── System.Updater           OTA update checker (opt-in)
│   └── Platform.AMQP            RabbitMQ publisher (opt-in)
│
├── Channels.Starter             Deferred channel boot
└── Bandit HTTP                  REST API on port 8089
```

---

## Adding Custom Skills

### SKILL.md (No Code)

Drop a markdown file in `~/.osa/skills/your-skill/SKILL.md`:

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

Available immediately — no restart, no rebuild.

### Elixir Module

```elixir
defmodule MyApp.Skills.Calculator do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "calculator"

  @impl true
  def description, do: "Evaluate a math expression"

  @impl true
  def parameters do
    %{"type" => "object",
      "properties" => %{
        "expression" => %{"type" => "string"}
      }, "required" => ["expression"]}
  end

  @impl true
  def execute(%{"expression" => expr}) do
    {result, _} = Code.eval_string(expr)
    {:ok, "#{result}"}
  end
end

# Register at runtime:
OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.Calculator)
```

---

## MCP Integration

```json
// ~/.osa/mcp.json
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

MCP tools are auto-discovered and available alongside built-in skills.

---

## Theoretical Foundation

OSA is grounded in four principles from communication and systems theory:

1. **Shannon (Channel Capacity):** Every channel has finite capacity. Match compute to complexity — don't burn your best model on trivial tasks.
2. **Ashby (Requisite Variety):** The system must match the variety of its inputs — 18 providers, 12 channels, unlimited skills, 5 reasoning strategies.
3. **Beer (Viable System Model):** Five operational modes (Build, Assist, Analyze, Execute, Maintain) mirror the five subsystems every viable organization needs.
4. **Wiener (Feedback Loops):** Every action produces feedback. The agent learns across sessions — memory, knowledge graph, pattern recognition, cortex synthesis.

**Research:** [Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems](https://zenodo.org/records/18774174) (Luna, 2026)

---

## MIOSA Ecosystem

OSA is the intelligence layer of the MIOSA platform:

| Setup | What You Get |
|-------|-------------|
| **OSA standalone** | Full AI agent in your terminal — chat, automate, orchestrate |
| **OSA + BusinessOS** | Proactive business assistant with CRM, scheduling, revenue alerts |
| **OSA + ContentOS** | Content operations agent — drafting, scheduling, engagement analysis |
| **OSA + Custom Template** | Build your own OS template. OSA handles the intelligence. |
| **MIOSA Cloud** | Managed instances with enterprise governance and 99.9% uptime |

[miosa.ai](https://miosa.ai)

---

## Documentation

| Doc | What It Covers |
|-----|---------------|
| [Documentation Index](docs/README.md) | Full docs map — 312 docs across all subsystems |
| [Architecture](docs/architecture/overview.md) | Ecosystem map, supervision tree, module organization |
| [Agent Loop](docs/backend/agent-loop/loop.md) | Core reasoning engine, strategies, context builder |
| [Memory & Knowledge](docs/backend/memory/overview.md) | 5-layer memory, knowledge graph, SPARQL, OWL reasoning |
| [Orchestration](docs/backend/orchestration/orchestrator.md) | Multi-agent decomposition, waves, swarms, PACT |
| [Tools](docs/backend/tools/overview.md) | 32 built-in tools, middleware pipeline, custom tools |
| [LLM Providers](docs/backend/providers/overview.md) | 18 providers, circuit breaker, tier routing |
| [HTTP API](docs/frontend/http-api.md) | Every endpoint, auth, SSE, error codes |
| [CLI Reference](docs/frontend/cli-reference.md) | All slash commands organized by category |
| [Features](docs/features/) | Recipes, skills, hooks, voice, proactive mode, tasks |
| [Deployment](docs/operations/deployment.md) | Docker, systemd, Nginx, production checklist |

---

## Team

Built by [Roberto H. Luna](https://github.com/robertohluna) and the [MIOSA](https://miosa.ai) team.

## Contributing

We prefer **skills over code changes.** Write a SKILL.md, share it with the community. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [MIOSA](https://miosa.ai). Grounded in [Signal Theory](https://zenodo.org/records/18774174). Powered by the BEAM.
