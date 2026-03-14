# Service Owners

## Overview

This document maps each OSA subsystem to its ownership scope, primary
maintainer team, and the key interfaces it exposes to other subsystems.
Ownership means responsibility for design decisions, review authority over
changes, and the obligation to maintain tests and documentation.

All subsystems are currently maintained by the MIOSA team. The boundaries
below define architectural contracts — which subsystem owns which processes,
which exports which public API, and which subsystems are permitted to call
into which others.

---

## Subsystem Ownership Map

### Core Agent Loop

**Scope**: `lib/optimal_system_agent/agent/loop/`

**Responsible for**: The main agentic loop — receiving channel messages,
building context, calling LLMs, executing tools, persisting results, and
returning responses.

**Key modules**:
- `Agent.Loop` — GenServer wrapping the loop state machine
- `Agent.Loop.LLMClient` — LLM call orchestration with hook pipeline
- `Agent.Loop.ToolExecutor` — tool dispatch and result handling
- `Agent.Loop.Guardrails` — input safety checks
- `Agent.Loop.GenreRouter` — message classification and routing

**Interfaces exposed**:
- `Agent.Loop.start_link/1` — create a session
- `Agent.Loop.send_message/2` — deliver a user message to a running session
- `Agent.Loop.cancel/1` — cancel the current turn

**Dependencies**: Providers, Tools, Memory, Hooks, Events.Bus

---

### Providers

**Scope**: `lib/optimal_system_agent/providers/`

**Responsible for**: LLM provider adapters, provider health tracking, and
the goldrush-compiled provider router.

**Key modules**:
- `Providers.Registry` — provider selection and fallback chain
- `Providers.HealthChecker` — circuit breaker (exposed as `MiosaLLM.HealthChecker`)
- `Providers.Anthropic` — Anthropic Claude adapter
- `Providers.OpenAICompat` — OpenAI-compatible adapter (OpenAI, Groq, etc.)
- `Providers.Ollama` — local Ollama adapter

**Interfaces exposed**:
- `MiosaProviders.Registry.chat/2` — synchronous LLM call with fallback
- `MiosaProviders.Registry.chat_stream/3` — streaming LLM call
- `MiosaLLM.HealthChecker.is_available?/1` — circuit breaker query

**Dependencies**: Events.Bus (for LLM telemetry events), HealthChecker

---

### Channels

**Scope**: `lib/optimal_system_agent/channels/`

**Responsible for**: Channel adapters that bridge external communication
protocols to the agent loop. Each channel adapter is a supervised GenServer.

**Key modules**:
- `Channels.Supervisor` — DynamicSupervisor for adapters
- `Channels.HTTP` — Plug-based HTTP/SSE adapter (Bandit, port 8089)
- `Channels.CLI` — interactive terminal adapter
- `Channels.Telegram`, `Channels.Discord`, `Channels.Slack`, etc.
- `Channels.NoiseFilter` — signal-to-noise filtering for incoming messages
- `Channels.Starter` — deferred startup of configured channels

**Interfaces exposed**:
- `Channels.HTTP` — REST and SSE API (see `docs/architecture/`)
- Channel adapters consume `Agent.Loop.send_message/2`

**Dependencies**: Agent.Loop (session creation and message delivery),
Events.Bus (channel connected/disconnected events)

---

### Tools

**Scope**: `lib/optimal_system_agent/tools/`

**Responsible for**: Tool registration, goldrush-compiled dispatch, tool
result caching, and the `MiosaTools.Behaviour` contract that all tools implement.

**Key modules**:
- `Tools.Registry` — goldrush-compiled tool dispatcher
- `Tools.Cache` — tool result cache (ETS-backed)
- `MiosaTools.Behaviour` — tool behaviour contract

**Interfaces exposed**:
- `Tools.Registry.execute/2` — dispatch a tool call by name
- `Tools.Registry.list_tools/0` — enumerate registered tools
- `Tools.Registry.register_mcp_tools/0` — register tools from MCP servers

**Dependencies**: MCP.Client (for MCP tool registration), Events.Bus

---

### Memory

**Scope**: `lib/optimal_system_agent/agent/memory/`

**Responsible for**: Working memory, episodic memory, conversation history
persistence (SQLite), memory taxonomy, and the knowledge bridge.

**Key modules**:
- `Agent.Memory` — GenServer; working memory operations
- `Agent.Memory.Episodic` — episodic event log (ETS)
- `Agent.Memory.KnowledgeBridge` — sync to knowledge graph
- `Agent.Memory.Injector` — memory injection into LLM context
- `Agent.Memory.Taxonomy` — memory categorization

**Interfaces exposed**:
- `Agent.Memory.store/3` — persist a memory entry
- `Agent.Memory.recall/2` — retrieve relevant memories
- `Agent.Memory.conversation_history/1` — get session history from SQLite

**Dependencies**: Store.Repo (SQLite persistence), MiosaKnowledge.Store

---

### Vault

**Scope**: `lib/optimal_system_agent/vault/`

**Responsible for**: Secret storage, retrieval, and rotation. Provides a
safe way for tools and integrations to access credentials without hard-coding
them.

**Key modules**:
- `Vault.Supervisor` — supervises vault GenServers
- `Vault` — secret get/set/delete API

**Interfaces exposed**:
- `Vault.get/1` — retrieve a secret by key
- `Vault.set/2` — store a secret

**Dependencies**: Store.Repo (encrypted persistence), OS keychain (optional)

---

### Events

**Scope**: `lib/optimal_system_agent/events/`

**Responsible for**: The goldrush-compiled event bus, dead letter queue,
event struct definitions, event classification (Signal Theory), and failure
mode detection.

**Key modules**:
- `Events.Bus` — goldrush router + emission API
- `Events.DLQ` — dead letter queue with exponential backoff retry
- `Events.Event` — CloudEvent-compatible event struct
- `Events.Classifier` — Signal Theory classification
- `Events.FailureModes` — pattern-based failure detection

**Interfaces exposed**:
- `Events.Bus.emit/3` — emit a typed event
- `Events.Bus.subscribe/2` — register an event handler
- `Events.DLQ.depth/0` — queue depth for monitoring

**Dependencies**: Bridge.PubSub (fan-out to SSE clients), Telemetry.Metrics

---

### Hooks

**Scope**: `lib/optimal_system_agent/agent/hooks.ex`

**Responsible for**: The hook pipeline that intercepts pre/post LLM calls
and pre/post tool calls. Hooks are the extension point for spend guards,
safety checks, learning capture, and telemetry.

**Key modules**:
- `Agent.Hooks` — GenServer managing the hook registry and pipeline

**Interfaces exposed**:
- `Agent.Hooks.register/2` — register a hook function for an event
- `Agent.Hooks.run_pre_llm/2` — execute pre-LLM hooks
- `Agent.Hooks.run_post_llm/2` — execute post-LLM hooks
- `Agent.Hooks.run_pre_tool/2` — execute pre-tool hooks
- `Agent.Hooks.run_post_tool/2` — execute post-tool hooks

**Dependencies**: MiosaBudget.Budget (spend guard hook), Agent.Learning

---

### Commands

**Scope**: `lib/optimal_system_agent/commands/`

**Responsible for**: Slash command registration and dispatch. Built-in
commands, custom commands, and agent-created commands are all registered here.

**Key modules**:
- `Commands` — GenServer managing the command registry

**Interfaces exposed**:
- `Commands.register/2` — register a slash command handler
- `Commands.dispatch/2` — dispatch a slash command by name

**Dependencies**: Agent.Loop (for commands that act on sessions)

---

### Sandbox

**Scope**: `lib/optimal_system_agent/sandbox/`

**Responsible for**: Isolated code execution environments. Supports safe,
restricted, and unrestricted execution modes.

**Key modules**:
- `Sandbox.Supervisor` — supervises sandbox execution GenServers

**Interfaces exposed**:
- `Sandbox.execute/2` — execute code in a sandboxed environment

**Dependencies**: OS process management (Docker or native process group)

---

### Intelligence

**Scope**: `lib/optimal_system_agent/intelligence/`

**Responsible for**: Signal Theory communication intelligence — conversation
tracking, contact detection, proactive monitoring. Dormant until wired to a
session.

**Key modules**:
- `Intelligence.Supervisor` — always started, lightweight

**Dependencies**: Events.Bus

---

### Platform

**Scope**: `lib/optimal_system_agent/platform/`

**Responsible for**: Optional PostgreSQL-backed platform features — multi-tenant
management, AMQP event publishing.

**Key modules**:
- `Platform.Repo` — Ecto repo (opt-in via `DATABASE_URL`)
- `Platform.AMQP` — AMQP publisher (opt-in via `AMQP_URL`)

**Dependencies**: External PostgreSQL, external AMQP broker

---

### Fleet

**Scope**: `lib/optimal_system_agent/fleet/`

**Responsible for**: Fleet management for multi-agent deployments. Agent
registration, sentinel monitoring, and fleet-wide coordination.

**Key modules**:
- `Fleet.Supervisor` — fleet management supervisor (opt-in)

**Dependencies**: Events.Bus, SessionRegistry

---

### Swarm

**Scope**: `lib/optimal_system_agent/agent/orchestrator/`

**Responsible for**: Multi-agent coordination within a single node. Mailbox,
SwarmMode, and AgentPool for parallel agent task execution.

**Key modules**:
- `Agent.Orchestrator.Mailbox` — ETS-backed message queue
- `Agent.Orchestrator.SwarmMode` — swarm coordination GenServer
- `Agent.Orchestrator.SwarmMode.AgentPool` — DynamicSupervisor (max 50 agents)

**Dependencies**: SessionSupervisor, Events.Bus

---

### MCP

**Scope**: `lib/optimal_system_agent/mcp/`

**Responsible for**: Model Context Protocol client — server lifecycle,
JSON-RPC handshake, tool enumeration, and tool call dispatch.

**Key modules**:
- `MCP.Client` — MCP server management
- `MCP.Supervisor` — DynamicSupervisor for per-server GenServers
- `MCP.Registry` — server name-to-PID lookup

**Interfaces exposed**:
- `MCP.Client.start_servers/0` — launch configured MCP servers
- `MCP.Client.list_tools/0` — enumerate tools from all running servers
- `MCP.Client.call_tool/3` — invoke a tool on a specific MCP server

**Dependencies**: Tools.Registry (tool registration), OS process management

---

### Scheduler

**Scope**: `lib/optimal_system_agent/agent/scheduler/`

**Responsible for**: Cron-style task scheduling and time-based agent triggers.

**Key modules**:
- `Agent.Scheduler` — GenServer managing scheduled tasks

**Interfaces exposed**:
- `Agent.Scheduler.schedule/3` — register a scheduled task
- `Agent.Scheduler.cancel/1` — cancel a scheduled task

**Dependencies**: Events.Bus (system_event emission), Agent.Loop
