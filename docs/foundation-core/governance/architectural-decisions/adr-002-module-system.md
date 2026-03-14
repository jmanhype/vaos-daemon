# ADR-002: Miosa Package Extraction and Shim Layer

## Status

Accepted (shim layer active as of v0.2.x)

## Date

2024-06-01

## Context

OSA was originally a monolith: all code under the `OptimalSystemAgent` namespace
in a single Mix project. As the system matured, seven logical subsystems were
identified as candidates for extraction into reusable, independently published
Hex packages under the `miosa_*` naming scheme:

| Package | Responsibility |
|---|---|
| `miosa_llm` | Provider health checking, circuit breaker |
| `miosa_providers` | LLM provider adapters (Anthropic, OpenAI, Ollama, etc.) |
| `miosa_memory` | Memory store, episodic memory, taxonomy, learning |
| `miosa_budget` | Token/cost budget, treasury |
| `miosa_signal` | Signal Theory event classification, CloudEvent |
| `miosa_tools` | Tool behaviour, middleware, pipeline |
| `miosa_knowledge` | Knowledge graph (Mnesia/ETS backend) |

The intent was to allow other Elixir projects to use these packages independently
of OSA.

### Problem

The extracted packages were placed in a separate repository. When OSA's `mix.exs`
referenced them as `path:` or git dependencies, build complexity increased
significantly:

- Umbrella project structure was required to keep CI fast
- Package API boundaries were not yet stable, causing frequent cross-package
  breaking changes during development
- Some packages had circular references at the type level
  (`miosa_signal` structs referenced in `miosa_memory`)
- The separate repo added friction for contributors — a single feature
  required changes across two repositories and two CI pipelines

The packages were not ready for public Hex publication. Running them as path
dependencies inside the OSA repo negated most of the intended benefits.

### Decision to Inline

The decision was made to inline all package implementations back into the
`OptimalSystemAgent` namespace and delete the external dependency declarations.
The actual implementations live at paths like:

- `OptimalSystemAgent.Providers.HealthChecker` (was: `MiosaLLM.HealthChecker`)
- `OptimalSystemAgent.Agent.Memory` (was: `MiosaMemory.Store`)
- `MiosaBudget.Budget` (inline implementation in `lib/miosa/shims.ex`)

## Decision

Create `lib/miosa/shims.ex` containing 28 alias modules that forward all
`Miosa*` namespace calls to their `OptimalSystemAgent.*` inline implementations.

The shim file serves three purposes:

1. **Compilation compatibility**: Code that calls `MiosaLLM.HealthChecker.record_success/1`
   compiles and dispatches correctly to the real implementation without any call-site changes.

2. **Behaviour compliance**: Modules declaring `@behaviour MiosaXxx.Behaviour` compile
   because the behaviour definition exists in the shim.

3. **Stub coverage**: Packages with no OSA equivalent yet (primarily `MiosaKnowledge`)
   are provided as lightweight stubs that return sensible defaults, allowing the
   system to compile and run without a fully implemented knowledge graph.

The shim file is a single file, not a separate module per file, to keep the
pattern visible and easy to audit in one place.

## Consequences

### Benefits

- **Single-repo build**: `mix deps.get && mix compile` works with no external
  path dependencies. CI runs in one repository.
- **Future extraction remains possible**: When the API boundaries stabilize and
  the packages are ready for Hex, the shims can be replaced with real external
  dependencies without changing call sites.
- **Reduced contributor friction**: New contributors do not need to set up the
  separate package repository.

### Costs

- **Compile warnings from forwarding**: Some `defdelegate` calls generate
  compiler warnings when the delegated function has a different arity or
  default arguments. These warnings are tracked and suppressed with `@dialyzer`
  annotations where necessary.
- **Namespace confusion**: Two namespaces (`Miosa*` and `OptimalSystemAgent.*`)
  exist for the same implementations. Contributors must understand that
  `MiosaLLM.HealthChecker` is a shim, not a separate module.
- **Stub debt**: `MiosaKnowledge` stubs return `:not_implemented` or empty
  results. Features depending on the knowledge graph are non-functional until
  a real implementation replaces the stubs.

## Shim Inventory

The following modules in `lib/miosa/shims.ex` are shims (not stubs):

| Shim module | Delegates to |
|---|---|
| `MiosaLLM.HealthChecker` | `OptimalSystemAgent.Providers.HealthChecker` |
| `MiosaProviders.Registry` | `OptimalSystemAgent.Providers.Registry` |
| `MiosaProviders.Ollama` | `OptimalSystemAgent.Providers.Ollama` |
| `MiosaProviders.Anthropic` | `OptimalSystemAgent.Providers.Anthropic` |
| `MiosaProviders.OpenAICompat` | `OptimalSystemAgent.Providers.OpenAICompat` |
| `MiosaProviders.Behaviour` | `OptimalSystemAgent.Providers.Behaviour` |
| `MiosaSignal.Event` | `OptimalSystemAgent.Events.Event` |
| `MiosaSignal.CloudEvent` | `OptimalSystemAgent.Protocol.CloudEvent` |
| `MiosaSignal.Classifier` | `OptimalSystemAgent.Events.Classifier` |
| `MiosaSignal.FailureModes` | `OptimalSystemAgent.Events.FailureModes` |
| `MiosaMemory.Episodic` | `OptimalSystemAgent.Agent.Memory.Episodic` |
| `MiosaMemory.Injector` | `OptimalSystemAgent.Agent.Memory.Injector` |
| `MiosaMemory.Taxonomy` | `OptimalSystemAgent.Agent.Memory.Taxonomy` |
| `MiosaMemory.Learning` | `OptimalSystemAgent.Agent.Learning` |
| `MiosaMemory.Cortex` | `OptimalSystemAgent.Agent.Cortex` |

The following are inline implementations (not delegates):

| Module | Location |
|---|---|
| `MiosaBudget.Budget` | `lib/miosa/shims.ex` (full GenServer) |
| `MiosaBudget.Treasury` | `lib/miosa/shims.ex` (full GenServer) |
| `MiosaSignal` | `lib/miosa/shims.ex` (Signal struct + functions) |
| `MiosaSignal.MessageClassifier` | `lib/miosa/shims.ex` |
| `MiosaTools.Behaviour` | `lib/miosa/shims.ex` |
| `MiosaTools.Instruction` | `lib/miosa/shims.ex` |
| `MiosaTools.Middleware` | `lib/miosa/shims.ex` |
| `MiosaTools.Pipeline` | `lib/miosa/shims.ex` |
| `MiosaMemory.Parser` | `lib/miosa/shims.ex` |
| `MiosaMemory.Index` | `lib/miosa/shims.ex` |

The following are stubs (not implemented):

| Module | Status |
|---|---|
| `MiosaKnowledge` | Stub — all operations return `:not_implemented` or empty |
| `MiosaKnowledge.Store` | Stub supervisor entry |
| `MiosaKnowledge.Backend.ETS` | Stub backend |
| `MiosaKnowledge.Backend.Mnesia` | Stub backend |
| `MiosaKnowledge.Context` | Stub |
| `MiosaKnowledge.Reasoner` | Stub |

## Exit Criteria for Shim Removal

The shim layer can be removed when:

1. All `miosa_*` packages are published to Hex with stable APIs
2. The packages are referenced as Hex dependencies in `mix.exs`
3. OSA-specific implementations are deleted from the OSA repository
4. `lib/miosa/shims.ex` is deleted
