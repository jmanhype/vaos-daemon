# Creating a Module

Audience: developers adding any new Elixir module to the OSA codebase —
whether a pure library module, a struct definition, or a helper. For GenServer
services, see [Creating a Service](./creating-a-service.md).

---

## Naming Conventions

### File names

Use `snake_case.ex`. The file name must match the last segment of the module
name, lowercased:

```
OptimalSystemAgent.Agent.Memory        → lib/optimal_system_agent/agent/memory.ex
OptimalSystemAgent.Events.Bus          → lib/optimal_system_agent/events/bus.ex
OptimalSystemAgent.Channels.NoiseFilter → lib/optimal_system_agent/channels/noise_filter.ex
```

Elixir's compiler resolves module names from the file path. Mismatches cause
`UndefinedFunctionError` at runtime.

### Module names

Use `PascalCase`. Every segment of the module name corresponds to a directory
level:

```
lib/
└── optimal_system_agent/
    ├── agent/
    │   ├── memory.ex          → OptimalSystemAgent.Agent.Memory
    │   └── loop/
    │       └── tool_executor.ex → OptimalSystemAgent.Agent.Loop.ToolExecutor
    ├── events/
    │   ├── bus.ex             → OptimalSystemAgent.Events.Bus
    │   └── dlq.ex             → OptimalSystemAgent.Events.DLQ
    └── channels/
        └── noise_filter.ex    → OptimalSystemAgent.Channels.NoiseFilter
```

### Compatibility shims

Modules in `lib/miosa/` are thin shims that satisfy call sites expecting the
`Miosa.*` namespace. If you are adding a new public API that other components
or external SDKs might call, consider whether a shim belongs in `lib/miosa/`
alongside the implementation in `lib/optimal_system_agent/`.

---

## Directory Placement

| Directory | Purpose |
|-----------|---------|
| `lib/optimal_system_agent/agent/` | Agent loop, memory, compactor, hooks, strategies |
| `lib/optimal_system_agent/channels/` | Channel adapters and the noise filter |
| `lib/optimal_system_agent/events/` | Event bus, DLQ, event struct, stream |
| `lib/optimal_system_agent/providers/` | LLM provider modules and health checker |
| `lib/optimal_system_agent/tools/` | Tool registry, cache, built-in tool implementations |
| `lib/optimal_system_agent/vault/` | Structured memory (Vault subsystem) |
| `lib/optimal_system_agent/signal/` | Signal Theory classifier |
| `lib/optimal_system_agent/intelligence/` | Conversation tracking, context profiles |
| `lib/optimal_system_agent/supervisors/` | Subsystem supervisor modules |
| `lib/optimal_system_agent/platform/` | Multi-tenant PostgreSQL layer (opt-in) |
| `lib/miosa/` | Compatibility shims for the Miosa.* namespace |

If your module does not fit cleanly into any of the above, create a new
subdirectory that names the subsystem clearly. Do not place modules in the
root `lib/optimal_system_agent/` directory unless they are application-level
concerns (e.g., `application.ex`, `cli.ex`).

---

## Module Template

```elixir
defmodule OptimalSystemAgent.MySubsystem.MyModule do
  @moduledoc """
  One-sentence summary of what this module does.

  Longer description: purpose, what data it operates on, what it depends on,
  what depends on it. Readers of this doc should be able to decide whether
  this is the right module to look at without reading the implementation.

  ## Usage

      result = MyModule.do_something(input)

  ## Dependencies

  Requires `OptimalSystemAgent.SomeOtherModule` to be running (started
  under `Supervisors.Infrastructure`).
  """

  # Aliases go here, grouped: external libs first, then internal
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Memory

  # Module-level attributes
  @default_timeout 5_000

  # ── Public API (documented) ─────────────────────────────────────────

  @doc """
  One-sentence summary.

  Full description of what the function does, including side effects.

  ## Parameters

    * `input` - description of the input

  ## Returns

  `{:ok, result}` on success. `{:error, reason}` if the input is invalid.

  ## Examples

      iex> MyModule.do_something("hello")
      {:ok, "HELLO"}

  """
  @spec do_something(String.t()) :: {:ok, String.t()} | {:error, term()}
  def do_something(input) when is_binary(input) do
    {:ok, process(input)}
  end

  def do_something(_input) do
    {:error, :invalid_input}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp process(input) do
    String.upcase(input)
  end
end
```

---

## Documentation Requirements

- Every public module must have `@moduledoc`.
- Every public function must have `@doc` and `@spec`.
- Private functions do not require `@doc`, but add inline comments for
  non-obvious logic. Comment the *why*, not the *what*:

```elixir
# We sample 1-in-10 events to keep overhead negligible on the hot path.
# Full detection on every event would add ~0.5ms per message.
if :rand.uniform(10) == 1 do
  FailureModes.detect(event)
end
```

---

## Pattern Matching over Conditionals

Prefer pattern matching in function heads over `if`/`cond` inside a function
body:

```elixir
# Preferred
def handle(:ok, _state), do: {:noreply, state}
def handle({:error, reason}, state) do
  Logger.error("Failed: #{reason}")
  {:noreply, state}
end

# Avoid
def handle(result, state) do
  if result == :ok do
    {:noreply, state}
  else
    Logger.error("Failed: #{elem(result, 1)}")
    {:noreply, state}
  end
end
```

---

## The `with` Construct for Happy Paths

Use `with` when you need to chain multiple operations that each return
`{:ok, value}` or `{:error, reason}`:

```elixir
def process_request(params) do
  with {:ok, validated} <- validate(params),
       {:ok, enriched}  <- enrich(validated),
       {:ok, result}    <- store(enriched) do
    {:ok, result}
  else
    {:error, :validation_failed} -> {:error, :bad_request}
    {:error, reason}             -> {:error, reason}
  end
end
```

---

## Struct Definitions

Place struct definitions in the module they belong to. Export the type:

```elixir
defmodule OptimalSystemAgent.Events.Event do
  @moduledoc "Typed event struct for the Events.Bus."

  @type t :: %__MODULE__{
    id: String.t(),
    type: atom(),
    payload: map(),
    timestamp: DateTime.t()
  }

  defstruct [:id, :type, :payload, :timestamp]
end
```

---

## Related

- [Creating a Service](./creating-a-service.md) — when the module is a GenServer
- [Registering Components](./registering-components.md) — expose the module as a tool, hook, or command
- [Coding Standards](../../development/coding-standards.md) — full style guide
