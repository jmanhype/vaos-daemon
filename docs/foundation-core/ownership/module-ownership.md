# Module Ownership

This document maps OSA subsystems to their ownership status and the appropriate
contact for questions or architectural changes.

All subsystems are maintained by the MIOSA team. The distinctions here reflect
which changes require escalation to the project lead versus routine PR review.

---

## Ownership Categories

**Core** — Changes require project lead review. These modules define fundamental
contracts that affect the entire codebase.

**Subsystem** — Changes require at least one MIOSA team member review with domain
knowledge. Significant changes (new strategies, API surface) require project lead review.

**Extension** — Standard PR review. These modules are opt-in and self-contained.

**Generated / Shim** — Treated with caution. Changes affect compilation across the
entire project.

---

## Module Map

### Core Infrastructure

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `OptimalSystemAgent.Application` | Core | Project lead | Supervision tree root — any change affects boot order |
| `Supervisors.Infrastructure` | Core | Project lead | Core dependency ordering |
| `Supervisors.Sessions` | Core | Project lead | Session lifecycle |
| `Supervisors.AgentServices` | Core | Project lead | Agent service ordering |
| `Supervisors.Extensions` | Core | Project lead | Extension flag system |
| `Events.Bus` | Core | Project lead | goldrush compile — risky to change |
| `Providers.Registry` | Core | Project lead | Fallback chain logic, circuit breaker integration |
| `Providers.HealthChecker` | Core | Project lead | Circuit breaker thresholds affect all providers |
| `Tools.Registry` | Core | MIOSA team | Tool dispatch |
| `lib/miosa/shims.ex` | Generated | Project lead | Any change may break compilation of 25+ modules |

### Agent Loop

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Agent.Loop` | Core | Project lead | Main reasoning engine |
| `Agent.Loop.LLMClient` | Subsystem | MIOSA team | LLM call abstraction, idle timeout |
| `Agent.Loop.ToolExecutor` | Subsystem | MIOSA team | Permission enforcement, hook pipeline |
| `Agent.Loop.GenreRouter` | Subsystem | MIOSA team | Signal Theory genre routing |
| `Agent.Loop.Guardrails` | Core | Project lead | Security — prompt injection detection |
| `Agent.Loop.Checkpoint` | Subsystem | MIOSA team | Loop state checkpointing |

### Signal Theory

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Signal.Classifier` | Core | Project lead | Signal Theory implementation — changes need author review |
| `Channels.NoiseFilter` | Core | MIOSA team | Pre-loop filtering |
| `Events.Classifier` | Subsystem | MIOSA team | Auto-classification of events |
| `Events.FailureModes` | Subsystem | MIOSA team | VSM-inspired failure mode detection |

### Memory

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Agent.Memory` | Subsystem | MIOSA team | Multi-store memory coordination |
| `Agent.Memory.SQLiteBridge` | Subsystem | MIOSA team | Ecto/SQLite persistence |
| `Agent.Memory.Episodic` | Subsystem | MIOSA team | Episodic store |
| `Agent.Memory.KnowledgeBridge` | Subsystem | MIOSA team | Connects memory to knowledge store |
| `Vault.Supervisor` | Subsystem | MIOSA team | Vault lifecycle |
| `Vault.FactStore` | Subsystem | MIOSA team | Fact persistence |
| `Agent.Compactor` | Subsystem | MIOSA team | Context compression |

### Providers

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Providers.Anthropic` | Subsystem | MIOSA team | Anthropic API adapter |
| `Providers.Ollama` | Subsystem | MIOSA team | Ollama local inference adapter |
| `Providers.Google` | Subsystem | MIOSA team | Google Gemini adapter |
| `Providers.Cohere` | Subsystem | MIOSA team | Cohere adapter |
| `Providers.Replicate` | Subsystem | MIOSA team | Replicate adapter |
| `Providers.OpenAICompatProvider` | Subsystem | MIOSA team | Consolidated OpenAI-compatible adapter (13 providers) |
| `Agent.Tier` | Core | Project lead | Tier-to-model mapping for all 18 providers |
| `Agent.Roster` | Subsystem | MIOSA team | Agent-to-tier mapping |

### Orchestration and Swarm

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Agent.Orchestrator` | Subsystem | MIOSA team | Multi-agent task decomposition |
| `Agent.Orchestrator.SwarmMode` | Subsystem | MIOSA team | Swarm coordination |
| `Agent.Orchestrator.AgentRunner` | Subsystem | MIOSA team | Sub-agent execution |
| `Swarm.Supervisor` | Extension | MIOSA team | Swarm OTP tree |
| `Swarm.Mailbox` | Subsystem | MIOSA team | Inter-agent messaging |
| `Fleet.Supervisor` | Extension | MIOSA team | Fleet management (opt-in) |
| `Fleet.Registry` | Extension | MIOSA team | Remote agent registry |

### Channels

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Channels.CLI` | Subsystem | MIOSA team | Terminal channel |
| `Channels.HTTP` | Core | Project lead | HTTP API surface — breaking changes affect SDK |
| `Channels.HTTP.API.*` | Subsystem | MIOSA team | Individual route modules |
| `Channels.Telegram`, `Discord`, etc. | Extension | MIOSA team | Messaging platform adapters |
| `Channels.Manager` | Subsystem | MIOSA team | Dynamic channel lifecycle |

### Infrastructure Extensions (all opt-in)

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `Sandbox.Supervisor` | Extension | MIOSA team | Docker sandbox |
| `Sidecar.Manager` | Extension | MIOSA team | Go/Python sidecar coordination |
| `Python.Supervisor` | Extension | MIOSA team | Python sidecar |
| `Go.Tokenizer` | Extension | MIOSA team | Go tokenizer sidecar |
| `Intelligence.Supervisor` | Subsystem | MIOSA team | Communication intelligence |
| `Platform.Repo` | Extension | MIOSA team | PostgreSQL (multi-tenant) |
| `Platform.AMQP` | Extension | MIOSA team | AMQP publisher |

### SDK

| Module(s) | Category | Contact | Notes |
|---|---|---|---|
| `OsaSDK` / `SDK.*` | Core | Project lead | Public SDK surface — stability guarantee pending |
| `SDK.Supervisor` | Core | Project lead | SDK supervision |

---

## Questions About a Specific Module

For any module not listed here, check the `@moduledoc` for ownership notes.
If the `@moduledoc` does not specify, open a GitHub Discussion tagged with
the relevant subsystem area.

The canonical answer to "who should review this change?" is:
- If it modifies supervision tree structure or child ordering: project lead
- If it changes a public function signature documented with `@doc`: MIOSA team review
  + project lead for `Core` modules
- If it adds a new optional feature or extension: standard MIOSA team PR review
- If it changes `lib/miosa/shims.ex`: project lead, always
