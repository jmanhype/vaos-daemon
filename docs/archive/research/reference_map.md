# OSA Package Extraction — Reference Map

Generated during research phase for tasks #10 and #11.

## Package Mapping Summary

| Package | App atom | Root module | Path dep |
|---|---|---|---|
| miosa_signal | `:miosa_signal` | `MiosaSignal` | `../miosa_signal` |
| miosa_memory | `:miosa_memory` | `MiosaMemory` | `../miosa_memory` |
| miosa_tools | `:miosa_tools` | `MiosaTools` | `../miosa_tools` |
| miosa_providers | `:miosa_providers` | `MiosaProviders` | `../miosa_providers` |

---

## 1. miosa_signal

**Extracts:** `OptimalSystemAgent.Signal.*`, `OptimalSystemAgent.Events.*`

### Module renames

| Old (OSA) | New (miosa_signal) |
|---|---|
| `OptimalSystemAgent.Signal` | `MiosaSignal` |
| `OptimalSystemAgent.Signal.Classifier` | `MiosaSignal.Classifier` |
| `OptimalSystemAgent.Events.Event` | `MiosaSignal.Event` |
| `OptimalSystemAgent.Events.Classifier` | `MiosaSignal.Events.Classifier` |
| `OptimalSystemAgent.Events.FailureModes` | `MiosaSignal.Events.FailureModes` |
| `OptimalSystemAgent.Events.Stream` | `MiosaSignal.Events.Stream` |
| `OptimalSystemAgent.Events.DLQ` | `MiosaSignal.Events.DLQ` |

### OSA files that reference these modules

**Signal / Signal.Classifier:**
- `lib/optimal_system_agent/channels/http/api.ex:39` — `alias OptimalSystemAgent.Signal.Classifier`
- `lib/optimal_system_agent/signal/classifier.ex` — module definition (will move or become shim)
- `lib/optimal_system_agent/signal.ex` — module definition (will move or become shim)
- `lib/optimal_system_agent/channels/manager.ex:36` — `OptimalSystemAgent.Channels.Signal` (different — this is the Signal messenger channel, NOT Signal Theory)
- `lib/optimal_system_agent/agent/loop.ex:6` — doc reference only
- `lib/optimal_system_agent/agent/loop/genre_router.ex:9` — doc reference only
- `lib/optimal_system_agent/agent/context.ex:12` — doc reference only

**Events.Event:**
- `lib/optimal_system_agent/events/bus.ex:30` — `alias OptimalSystemAgent.Events.Event`
- `lib/optimal_system_agent/events/failure_modes.ex:29` — `alias OptimalSystemAgent.Events.Event`
- `lib/optimal_system_agent/events/classifier.ex:16` — `alias OptimalSystemAgent.Events.Event`
- `lib/optimal_system_agent/events/event.ex` — module definition

**Events.Classifier:**
- `lib/optimal_system_agent/events/bus.ex:31` — `alias OptimalSystemAgent.Events.Classifier`
- `lib/optimal_system_agent/events/failure_modes.ex:30` — `alias OptimalSystemAgent.Events.Classifier`
- `lib/optimal_system_agent/events/classifier.ex` — module definition

**Events.FailureModes:**
- `lib/optimal_system_agent/events/failure_modes.ex` — module definition

**Events.Stream:**
- `lib/optimal_system_agent/events/bus.ex:101` — `OptimalSystemAgent.Events.Stream.append(...)`
- `lib/optimal_system_agent/events/stream.ex` — module definition

**Events.DLQ:**
- `lib/optimal_system_agent/events/bus.ex:249,253` — `OptimalSystemAgent.Events.DLQ.enqueue(...)`
- `lib/optimal_system_agent/supervisors/infrastructure.ex:33` — supervisor child spec
- `lib/optimal_system_agent/events/dlq.ex` — module definition

---

## 2. miosa_memory

**Extracts:** `OptimalSystemAgent.Agent.Memory.*`, `OptimalSystemAgent.Agent.Learning`, `OptimalSystemAgent.Agent.Cortex`

### Module renames

| Old (OSA) | New (miosa_memory) |
|---|---|
| `OptimalSystemAgent.Agent.Memory` | `MiosaMemory` (or `MiosaMemory.Store`) |
| `OptimalSystemAgent.Agent.Memory.Taxonomy` | `MiosaMemory.Taxonomy` |
| `OptimalSystemAgent.Agent.Memory.Episodic` | `MiosaMemory.Episodic` |
| `OptimalSystemAgent.Agent.Memory.Injector` | `MiosaMemory.Injector` |
| `OptimalSystemAgent.Agent.Learning` | `MiosaMemory.Learning` |
| `OptimalSystemAgent.Agent.Cortex` | `MiosaMemory.Cortex` |

*Note: `MiosaMemory.Emitter` and `MiosaMemory.NullEmitter` already exist in miosa_memory scaffold.*

### OSA files that reference these modules

**Agent.Memory:**
- `lib/optimal_system_agent/channels/http/api/session_routes.ex:17`
- `lib/optimal_system_agent/channels/http/api/data_routes.ex:17`
- `lib/optimal_system_agent/commands/data.ex:19`
- `lib/optimal_system_agent/commands/info.ex:128,214`
- `lib/optimal_system_agent/commands/session.ex:13,50,135,235`
- `lib/optimal_system_agent/commands/config.ex:105`
- `lib/optimal_system_agent/commands/system.ex:518`
- `lib/optimal_system_agent/sdk/memory.ex:9`
- `lib/optimal_system_agent/sdk/session.ex:13`
- `lib/optimal_system_agent/sdk/supervisor.ex:70`
- `lib/optimal_system_agent/supervisors/agent_services.ex:21`
- `lib/optimal_system_agent/intelligence/proactive_monitor.ex:22`
- `lib/optimal_system_agent/tools/builtins/semantic_search.ex:47`
- `lib/optimal_system_agent/tools/builtins/memory_save.ex:28`
- `lib/optimal_system_agent/tools/builtins/memory_recall.ex:28`
- `lib/optimal_system_agent/agent/loop.ex:22`
- `lib/optimal_system_agent/agent/cortex.ex:20`
- `lib/optimal_system_agent/agent/context.ex:484`
- `lib/optimal_system_agent/agent/memory.ex` — module definition

**Agent.Memory.Taxonomy / Episodic / Injector:**
- `lib/optimal_system_agent/agent/context.ex:43-45` — aliased
- `lib/optimal_system_agent/agent/memory/injector.ex:22` — `alias OptimalSystemAgent.Agent.Memory.Taxonomy`
- `lib/optimal_system_agent/agent/memory/taxonomy.ex` — module definition
- `lib/optimal_system_agent/agent/memory/episodic.ex` — module definition
- `lib/optimal_system_agent/agent/memory/injector.ex` — module definition

**Agent.Learning:**
- `lib/optimal_system_agent/channels/http/api/data_routes.ex:283`
- `lib/optimal_system_agent/commands/agents.ex:286,287`
- `lib/optimal_system_agent/commands/system.ex:389`
- `lib/optimal_system_agent/sdk/supervisor.ex:77`
- `lib/optimal_system_agent/supervisors/agent_services.ex:30`
- `lib/optimal_system_agent/tools/builtins/semantic_search.ex:65`
- `lib/optimal_system_agent/agent/context.ex:362,363`
- `lib/optimal_system_agent/agent/learning.ex` — module definition

**Agent.Cortex:**
- `lib/optimal_system_agent/commands/info.ex:263,264,265`
- `lib/optimal_system_agent/commands/system.ex:531`
- `lib/optimal_system_agent/supervisors/agent_services.ex:33`
- `lib/optimal_system_agent/agent/cortex.ex` — module definition

---

## 3. miosa_tools

**Extracts:** `OptimalSystemAgent.Tools.Behaviour`, `OptimalSystemAgent.Tools.Instruction`, `OptimalSystemAgent.Tools.Middleware`, `OptimalSystemAgent.Tools.Pipeline`

*Note: `Tools.Registry` and all builtins stay in OSA — only the abstract contracts move.*

### Module renames

| Old (OSA) | New (miosa_tools) |
|---|---|
| `OptimalSystemAgent.Tools.Behaviour` | `MiosaTools.Behaviour` |
| `OptimalSystemAgent.Tools.Instruction` | `MiosaTools.Instruction` |
| `OptimalSystemAgent.Tools.Middleware` | `MiosaTools.Middleware` |
| `OptimalSystemAgent.Tools.Middleware.Noop` | `MiosaTools.Middleware.Noop` |
| `OptimalSystemAgent.Tools.Middleware.Logging` | `MiosaTools.Middleware.Logging` |
| `OptimalSystemAgent.Tools.Middleware.Timing` | `MiosaTools.Middleware.Timing` |
| `OptimalSystemAgent.Tools.Middleware.Validation` | `MiosaTools.Middleware.Validation` |
| `OptimalSystemAgent.Tools.Pipeline` | `MiosaTools.Pipeline` |

*Note: `MiosaTools.Behaviour` and `MiosaTools.Instruction` already exist in miosa_tools scaffold.*

### OSA files that reference these modules

**Tools.Behaviour** (every tool file that uses `@behaviour OptimalSystemAgent.Tools.Behaviour`):
- `lib/optimal_system_agent/tools/behaviour.ex` — module definition
- `lib/osa_sdk.ex` (indirectly via behaviour contract)
- `lib/optimal_system_agent/sdk/tool.ex:51` — `@behaviour OptimalSystemAgent.Tools.Behaviour`
- `test/support/mock_provider.ex:18` — (wrong category — this is Providers.Behaviour, see below)
- All builtin tool files in `lib/optimal_system_agent/tools/builtins/` — each has `@behaviour OptimalSystemAgent.Tools.Behaviour`

**Tools.Instruction:**
- `lib/optimal_system_agent/tools/instruction.ex` — module definition
- `lib/optimal_system_agent/tools/pipeline.ex:35` — `alias OptimalSystemAgent.Tools.Instruction`
- `lib/optimal_system_agent/tools/middleware.ex:34` — `alias OptimalSystemAgent.Tools.Instruction`

**Tools.Middleware:**
- `lib/optimal_system_agent/tools/middleware.ex` — module definition (all sub-modules too)

**Tools.Pipeline:**
- `lib/optimal_system_agent/tools/pipeline.ex` — module definition

---

## 4. miosa_providers

**Extracts:** `OptimalSystemAgent.Providers.Behaviour`, `OptimalSystemAgent.Providers.Registry`, all provider implementations

### Module renames

| Old (OSA) | New (miosa_providers) |
|---|---|
| `OptimalSystemAgent.Providers.Behaviour` | `MiosaProviders.Behaviour` |
| `OptimalSystemAgent.Providers.Registry` | `MiosaProviders.Registry` |
| `OptimalSystemAgent.Providers.Anthropic` | `MiosaProviders.Anthropic` |
| `OptimalSystemAgent.Providers.OpenAICompat` | `MiosaProviders.OpenAICompat` |
| `OptimalSystemAgent.Providers.OpenAICompatProvider` | `MiosaProviders.OpenAICompatProvider` |
| `OptimalSystemAgent.Providers.Ollama` | `MiosaProviders.Ollama` |
| `OptimalSystemAgent.Providers.Google` | `MiosaProviders.Google` |
| `OptimalSystemAgent.Providers.Cohere` | `MiosaProviders.Cohere` |
| `OptimalSystemAgent.Providers.Replicate` | `MiosaProviders.Replicate` |
| `OptimalSystemAgent.Providers.ToolCallParsers` | `MiosaProviders.ToolCallParsers` |

### OSA files that reference these modules (impact: HIGH — deeply threaded)

**Providers.Registry** (alias `Providers` or `ProvReg`):
- `lib/optimal_system_agent/supervisors/infrastructure.ex:46` — child spec
- `lib/optimal_system_agent/sdk/supervisor.ex:61`
- `lib/optimal_system_agent/application.ex:70`
- `lib/optimal_system_agent/agent/loop.ex:974`
- `lib/optimal_system_agent/agent/loop/llm_client.ex:10`
- `lib/optimal_system_agent/agent/context.ex:51`
- `lib/optimal_system_agent/agent/orchestrator.ex:27`
- `lib/optimal_system_agent/agent/orchestrator/wave_executor.ex:14`
- `lib/optimal_system_agent/agent/orchestrator/agent_runner.ex:21`
- `lib/optimal_system_agent/agent/orchestrator/swarm_worker.ex:28`
- `lib/optimal_system_agent/agent/orchestrator/complexity.ex:12`
- `lib/optimal_system_agent/agent/workflow.ex:19`
- `lib/optimal_system_agent/agent/cortex.ex:21`
- `lib/optimal_system_agent/agent/compactor.ex:57`
- `lib/optimal_system_agent/agent/auto_fixer.ex:44`
- `lib/optimal_system_agent/agent/explorer.ex:19`
- `lib/optimal_system_agent/channels/http.ex:79,96`
- `lib/optimal_system_agent/channels/http/api/data_routes.ex:120,138,206,209,228,230,232,235`
- `lib/optimal_system_agent/commands/info.ex:126`
- `lib/optimal_system_agent/commands/model.ex:52,85,100,141,170`
- `lib/optimal_system_agent/commands/system.ex:472`
- `lib/optimal_system_agent/recipes/recipe.ex:47`
- `lib/optimal_system_agent/swarm/orchestrator.ex:31`
- `lib/optimal_system_agent/swarm/planner.ex:32`
- `lib/optimal_system_agent/swarm/worker.ex:28`
- `lib/optimal_system_agent/swarm/intelligence.ex:45`
- `lib/optimal_system_agent/tools/builtins/delegate.ex:16`
- `lib/optimal_system_agent/tools/builtins/web_fetch.ex:4`
- `lib/optimal_system_agent/signal/classifier.ex:34`
- `lib/optimal_system_agent/providers/registry.ex` — module definition

**Providers.Behaviour:**
- `lib/optimal_system_agent/providers/behaviour.ex` — module definition
- `lib/optimal_system_agent/providers/anthropic.ex:14`
- `lib/optimal_system_agent/providers/ollama.ex:16`
- `lib/optimal_system_agent/providers/google.ex:15`
- `lib/optimal_system_agent/providers/cohere.ex:15`
- `lib/optimal_system_agent/providers/replicate.ex:18`
- `lib/optimal_system_agent/providers/registry.ex:271`
- `test/support/mock_provider.ex:18`

**Providers.Ollama** (auto-detect, model listing):
- `lib/optimal_system_agent/application.ex:70`
- `lib/optimal_system_agent/channels/http.ex:170`
- `lib/optimal_system_agent/channels/http/api/data_routes.ex:206`
- `lib/optimal_system_agent/commands/model.ex:204,220,259,281`
- `lib/mix/tasks/osa.chat.ex:34`
- `lib/mix/tasks/osa.serve.ex:26`

---

## 5. mix.exs Changes Required

Add to `deps/0` in `OptimalSystemAgent.MixProject`:

```elixir
# Extracted signal theory + events package
{:miosa_signal, path: "../miosa_signal"},

# Extracted memory subsystem
{:miosa_memory, path: "../miosa_memory"},

# Extracted tool contracts (behaviour, instruction, middleware, pipeline)
{:miosa_tools, path: "../miosa_tools"},

# Extracted LLM provider implementations
{:miosa_providers, path: "../miosa_providers"},
```

---

## 6. Integration Notes

### What stays in OSA after extraction

- `OptimalSystemAgent.Events.Bus` — event bus is OSA-internal infrastructure
- `OptimalSystemAgent.Tools.Registry` — tool registry with goldrush dispatch
- All `OptimalSystemAgent.Tools.Builtins.*` — builtin tool implementations
- All channel adapters (`Channels.*`)
- Agent loop, orchestrator, supervisors
- SDK (`osa_sdk.ex`, `sdk/*`)

### What moves to packages

- **miosa_signal**: Signal struct + CloudEvents envelope, Signal.Classifier (LLM-based), Events.Event/Classifier/FailureModes/Stream/DLQ
- **miosa_memory**: Agent.Memory GenServer, Memory.Taxonomy/Episodic/Injector, Agent.Learning, Agent.Cortex
- **miosa_tools**: Tools.Behaviour contract, Tools.Instruction struct, Tools.Middleware pipeline, Tools.Pipeline
- **miosa_providers**: All Providers.* modules including Registry GenServer

### Shim strategy

After extraction, the OSA files that were module definitions become either:
1. **Deleted** — if callers are updated to use new module names
2. **Shims** (`defmodule OldName, do: defdelegate ...`) — for gradual migration

Preferred approach: **update callers directly** (no shims — shims create confusion). The reference map above identifies every caller file.

### Dependency graph for OSA's new packages

```
OSA
├── miosa_signal   (no OSA deps, standalone)
├── miosa_memory   (may depend on miosa_signal for event emission)
├── miosa_tools    (no OSA deps, standalone)
├── miosa_providers → miosa_llm (already a dep)
├── miosa_llm      (already added)
├── miosa_budget   (already added)
└── miosa_knowledge (already added)
```
