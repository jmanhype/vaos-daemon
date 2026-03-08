# OptimalSystemAgent

A production AI agent framework built in pure Elixir/OTP. OSA runs autonomous agents that reason, use tools, remember context across sessions, orchestrate sub-agents, and connect to any LLM provider — all under OTP supervision with crash recovery, backpressure, and zero external runtime dependencies.

```
287 modules · 32 subsystems · 25 agent roles · 32 tools · 18 LLM providers · 10 channels
```

---

## Quick Links

- [Installation](getting-started/installation.md) — Prerequisites and first run
- [Configuration](getting-started/configuration.md) — Config keys, env vars, feature flags
- [Quickstart](getting-started/quickstart.md) — Hello-world agent in 5 minutes
- [System Overview](architecture/overview.md) — Full ecosystem map and supervision tree
- [HTTP API](frontend/http-api.md) — REST endpoint reference
- [CLI Commands](frontend/cli-reference.md) — All slash commands

---

## Architecture

How the system is designed and why.

| | |
|---|---|
| [System Overview](architecture/overview.md) | Ecosystem map, supervision tree, module organization |
| [Data Flow](architecture/data-flow.md) | Message lifecycle: channel → agent loop → tool execution → response |
| [Signal Theory](architecture/signal-theory.md) | The governing framework — S=(M,G,T,F,W), S/N maximization |
| [SDK](architecture/sdk.md) | Public contracts for tools, agents, channels, hooks |
| [ADRs](architecture/adr/) | Architectural decision records |

---

## Backend

### Agent Loop

The core reasoning engine. Each turn: build context → call LLM → parse response → execute tools → check halt conditions → repeat.

| | |
|---|---|
| [Core Loop](backend/agent-loop/loop.md) | Bounded ReAct engine — turn lifecycle, guardrails, halt conditions |
| [Context Builder](backend/agent-loop/context.md) | Two-tier token-budgeted prompt assembly with 11 dynamic blocks |
| [Strategies](backend/agent-loop/strategies.md) | CoT, Reflection, MCTS, Tree of Thoughts — selection logic and step types |
| [Compactor](backend/agent-loop/compactor.md) | Context window compression at the 90% threshold |
| [Scratchpad](backend/agent-loop/scratchpad.md) | Provider-agnostic extended thinking (Anthropic native or `<think>` injection) |
| [AutoFixer](backend/agent-loop/auto-fixer.md) | Iterative test/lint fix loop with retry budget |

### Memory & Knowledge

Five layers of memory — from per-turn working memory to a persistent knowledge graph with SPARQL and OWL reasoning.

| | |
|---|---|
| [Overview](backend/memory/overview.md) | 5-layer architecture and how the layers interact |
| [Memory Store](backend/memory/memory-store.md) | JSONL + SQLite dual-write, query strategies |
| [Episodic](backend/memory/episodic.md) | Temporal event tracking — patterns, solutions, decisions |
| [Learning](backend/memory/learning.md) | Pattern/solution capture, confidence scoring, KnowledgeBridge sync |
| [Knowledge Graph](backend/memory/knowledge-graph.md) | `miosa_knowledge` — SPARQL, OWL 2 RL reasoning, ETS/Mnesia backends |
| [Cortex](backend/memory/cortex.md) | Bulletin generation, active topics, cross-session synthesis |
| [Taxonomy](backend/memory/taxonomy.md) | Classification scheme and context injection rules |

### Orchestration

Multi-agent coordination — decompose goals into tasks, assign to specialized agents, execute in waves.

| | |
|---|---|
| [Orchestrator](backend/orchestration/orchestrator.md) | Goal dispatch, complexity scoring, wave execution |
| [Agent Roster](backend/orchestration/agents.md) | 25 roles across Haiku/Sonnet/Opus tiers |
| [Swarm Mode](backend/orchestration/swarm.md) | Parallel, pipeline, and fan-out/fan-in patterns |
| [Fleet](backend/orchestration/fleet.md) | Remote agent management across instances |
| [Delegation](backend/orchestration/delegation.md) | Sub-agent dispatch — mailbox, negotiation, state machine |

### Tools

32 built-in tools with Goldrush-compiled dispatch, middleware pipeline, and schema validation.

| | |
|---|---|
| [Overview](backend/tools/overview.md) | Registry, dispatch, middleware pipeline |
| [File Tools](backend/tools/file-tools.md) | `file_read`, `file_write`, `file_edit`, `file_glob`, `file_grep`, `dir_list` |
| [Execution Tools](backend/tools/execution-tools.md) | `shell_execute`, `code_sandbox`, `browser`, `computer_use` |
| [Intelligence Tools](backend/tools/intelligence-tools.md) | `semantic_search`, `memory_recall`, `memory_save`, `knowledge` |
| [Integration Tools](backend/tools/integration-tools.md) | `web_fetch`, `web_search`, `github`, `git` |
| [Custom Tools](backend/tools/custom-tools.md) | Building tools with `MiosaTools.Behaviour`, schema, middleware |

### Channels

Input/output adapters — how users and systems talk to OSA.

| | |
|---|---|
| [Overview](backend/channels/overview.md) | Channel behaviour contract, lifecycle, registration |
| [CLI](backend/channels/cli.md) | Terminal REPL — streaming output, task display |
| [HTTP](backend/channels/http.md) | REST API — routing, session binding, SSE streaming |
| [Messaging](backend/channels/messaging.md) | Discord, Slack, Telegram, WhatsApp, Signal, Matrix, Email, DingTalk, Feishu, QQ |

### Events

Internal event bus — every mutation, tool call, and state change emits a structured event.

| | |
|---|---|
| [Event Bus](backend/events/bus.md) | Goldrush-compiled dispatch, classifier, DLQ, failure modes |
| [Protocol](backend/events/protocol.md) | OSCP envelope format, CloudEvents codec |
| [Telemetry](backend/events/telemetry.md) | ETS metrics counters, hook telemetry, emission points |

### Platform

Multi-tenant infrastructure for running OSA as a hosted service.

| | |
|---|---|
| [Authentication](backend/platform/auth.md) | JWT validation, grants, platform auth routes |
| [Tenants](backend/platform/tenants.md) | Multi-tenancy — schema, isolation model |
| [AMQP](backend/platform/amqp.md) | RabbitMQ integration for cross-instance messaging |
| [Instances](backend/platform/instances.md) | Multi-instance coordination, OS instance registry |

### Infrastructure

Low-level services that everything else depends on.

| | |
|---|---|
| [Sandbox](backend/infrastructure/sandbox.md) | Code execution isolation — policy, limits, escape prevention |
| [MCP](backend/infrastructure/mcp.md) | Model Context Protocol — server discovery, tool bridging |
| [Sidecar](backend/infrastructure/sidecar.md) | External service lifecycle management |
| [Scheduler](backend/infrastructure/scheduler.md) | Cron jobs, heartbeat, proactive trigger timing |
| [Security](backend/infrastructure/security.md) | Shell policy, command allowlist/blocklist |
| [Intelligence](backend/infrastructure/intelligence.md) | Proactive monitoring, signal-driven autonomous work |

### LLM Providers

18 providers with circuit breaker, rate limiting, and health checking via `miosa_llm`.

| | |
|---|---|
| [Overview](backend/providers/overview.md) | Provider architecture, `miosa_llm` infrastructure |
| [Configuration](backend/providers/configuration.md) | API keys, base URLs, model aliases, defaults |

Per-provider guides: [Anthropic](backend/providers/anthropic.md) · [OpenAI](backend/providers/openai.md) · [Google](backend/providers/google.md) · [Groq](backend/providers/groq.md) · [Ollama](backend/providers/ollama.md) · [DeepSeek](backend/providers/deepseek.md) · [OpenRouter](backend/providers/openrouter.md) · [Mistral](backend/providers/mistral.md) · [Cohere](backend/providers/cohere.md) · [Perplexity](backend/providers/perplexity.md) · [Fireworks](backend/providers/fireworks.md) · [Together](backend/providers/together.md) · [Replicate](backend/providers/replicate.md) · [Chinese](backend/providers/chinese.md)

---

## Frontend

| | |
|---|---|
| [HTTP API Reference](frontend/http-api.md) | All REST endpoints — auth, sessions, agents, fleet, orchestration, data, knowledge |
| [CLI Reference](frontend/cli-reference.md) | All slash commands organized by category |

---

## Features

| | |
|---|---|
| [Recipes](features/recipes.md) | Reusable workflow templates — define, store, execute |
| [Skills](features/skills.md) | Dynamic skill system — built-in + SKILL.md custom skills |
| [Hooks](features/hooks.md) | 13 lifecycle events, 10 active hooks, custom hook authoring |
| [Voice](features/voice.md) | Voice I/O — STT, TTS, audio level meter, cross-platform |
| [Proactive Mode](features/proactive-mode.md) | Autonomous work triggered by signals and schedules |
| [Tasks](features/tasks.md) | Task tracking, queue management, workflow engine |

---

## Operations

| | |
|---|---|
| [Deployment](operations/deployment.md) | Docker, systemd, Nginx, production checklist |
| [Debugging](operations/debugging.md) | Log queries, ETS inspection, common failure patterns |
| [Changelog](operations/changelog.md) | Release history |

---

## Research

Internal research and competitive analysis — not user-facing documentation.

| | |
|---|---|
| [Competitors](research/competitors/) | 14 competitors analyzed — positioning, feature gaps |
| [Flows](research/flows/) | Message flow analysis across competitor architectures |
| [Prompt Engineering](research/prompt-engineering/) | System prompt research and strategy |
| [Roadmap](research/roadmap/) | 5-phase plan through Q3 2026 |
| [Agent Dispatch](research/agent-dispatch/) | Multi-agent dispatch framework research |

---

## Archive

All original documentation preserved in [`archive/`](archive/) with its original directory structure. Nothing was deleted — files were reorganized into the structure above.

---

## Directory Map

```
docs/
├── getting-started/          Install, config, quickstart
├── architecture/             System design, Signal Theory, ADRs
├── backend/
│   ├── agent-loop/           Core reasoning engine (6 docs)
│   ├── memory/               5-layer memory system (7 docs)
│   ├── orchestration/        Multi-agent coordination (5 docs)
│   ├── tools/                32 built-in tools (6 docs)
│   ├── channels/             I/O adapters (4 docs)
│   ├── events/               Event bus and telemetry (3 docs)
│   ├── platform/             Multi-tenant infrastructure (4 docs)
│   ├── infrastructure/       Low-level services (6 docs)
│   └── providers/            18 LLM providers (16 docs)
├── frontend/                 HTTP API + CLI reference
├── features/                 Recipes, skills, hooks, voice, tasks
├── operations/               Deploy, debug, changelog
├── research/                 Competitors, flows, roadmap
└── archive/                  Original docs (preserved)
```
