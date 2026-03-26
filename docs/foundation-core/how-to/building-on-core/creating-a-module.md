# Creating a Module

Audience: developers adding any new Elixir module to the Daemon codebase —
whether a pure library module, a struct definition, or a helper. For GenServer
services, see [Creating a Service](./creating-a-service.md).

---

## Naming Conventions

### File names

Use `snake_case.ex`. The file name must match the last segment of the module
name, lowercased:

```
Daemon.Agent.Memory        → lib/daemon/agent/memory.ex
Daemon.Events.Bus          → lib/daemon/events/bus.ex
Daemon.Channels.NoiseFilter → lib/daemon/channels/noise_filter.ex
```

Elixir's compiler resolves module names from the file path. Mismatches cause
`UndefinedFunctionError` at runtime.

### Module names

Use `PascalCase`. Every segment of the module name corresponds to a directory
level:

```
lib/
└── daemon/
    ├── agent/
    │   ├── memory.ex          → Daemon.Agent.Memory
    │   └── loop/
    │       └── tool_executor.ex → Daemon.Agent.Loop.ToolExecutor
    ├── events/
    │   ├── bus.ex             → Daemon.Events.Bus
    │   └── dlq.ex             → Daemon.Events.DLQ
    └── channels/
        └── noise_filter.ex    → Daemon.Channels.NoiseFilter
```

### Compatibility shims

Modules in `lib/miosa/` are thin shims that satisfy call sites expecting the
`Miosa.*` namespace. If you are adding a new public API that other components
or external SDKs might call, consider whether a shim belongs in `lib/miosa/`
alongside the implementation in `lib/daemon/`.

---

## Directory Placement

| Directory | Purpose |
|-----------|---------|
| `lib/daemon/agent/` | Agent loop, memory, compactor, hooks, strategies |
| `lib/daemon/channels/` | Channel adapters and the noise filter |
| `lib/daemon/events/` | Event bus, DLQ, event struct, stream |
| `lib/daemon/providers/` | LLM provider modules and health checker |
| `lib/daemon/tools/` | Tool registry, cache, built-in tool implementations |
| `lib/daemon/vault/` | Structured memory (Vault subsystem) |
| `lib/daemon/signal/` | Signal Theory classifier |
| `lib/daemon/intelligence/` | Conversation tracking, context profiles |
| `lib/daemon/supervisors/` | Subsystem supervisor modules |
| `lib/daemon/platform/` | Multi-tenant PostgreSQL layer (opt-in) |
| `lib/miosa/` | Compatibility shims for the Miosa.* namespace |

If your module does not fit cleanly into any of the above, create a new
subdirectory that names the subsystem clearly. Do not place modules in the
root `lib/daemon/` directory unless they are application-level
concerns (e.g., `application.ex`, `cli.ex`).

---

## Module Template

```elixir
defmodule Daemon.MySubsystem.MyModule do
  @moduledoc """
  One-sentence summary of what this module does.

  Longer description: purpose, what data it operates on, what it depends on,
  what depends on it. Readers of this doc should be able to decide whether
  this is the right module to look at without reading the implementation.

  ## Usage

      result = MyModule.do_something(input)

  ## Dependencies

  Requires `Daemon.SomeOtherModule` to be running (started
  under `Supervisors.Infrastructure`).
  """

  # Aliases go here, grouped: external libs first, then internal
  alias Daemon.Events.Bus
  alias Daemon.Agent.Memory

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
defmodule Daemon.Events.Event do
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
