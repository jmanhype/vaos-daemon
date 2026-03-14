# Coding Standards

Audience: all developers contributing Elixir code to OSA.

These standards reflect the patterns used throughout the codebase. Consistency
matters more than personal preference — follow these even when you disagree.

---

## Naming

### Modules

`PascalCase`. Every path segment is a module segment:

```elixir
# lib/optimal_system_agent/agent/loop/tool_executor.ex
defmodule OptimalSystemAgent.Agent.Loop.ToolExecutor do
```

### Functions and variables

`snake_case`. Predicates end in `?`. Bang functions end in `!` and raise on
error:

```elixir
def available?, do: ...
def load!(path), do: File.read!(path)
def process(input), do: ...
```

### Module attributes (constants)

`snake_case` prefixed with `@`. Use descriptive names:

```elixir
@max_retries 3
@base_backoff_ms 1_000
@cancel_table :osa_cancel_flags
@failure_mode_sample_rate 10
```

### File names

`snake_case.ex`. Must match the last segment of the module name:

```
OptimalSystemAgent.Channels.NoiseFilter → channels/noise_filter.ex
```

---

## Documentation

Every public module requires `@moduledoc`. Every public function requires
`@doc` and `@spec`.

`@moduledoc false` is acceptable for internal modules that are not part of
any public API surface.

```elixir
defmodule OptimalSystemAgent.Events.Bus do
  @moduledoc """
  One-sentence summary.

  Longer description of purpose, dependencies, and usage.

  ## Usage

      Bus.emit(:system_event, %{message: "example"})

  """

  @doc """
  Emit an event through the goldrush-compiled router.

  ## Parameters

    * `event_type` - an atom from the allowed event types list
    * `payload` - map of event-specific data
    * `opts` - optional keyword list (`:source`, `:session_id`, `:parent_id`)

  ## Returns

  `{:ok, %Event{}}` on success.

  ## Examples

      iex> Bus.emit(:system_event, %{message: "test"})
      {:ok, %OptimalSystemAgent.Events.Event{}}

  """
  @spec emit(atom(), map(), keyword()) :: {:ok, Events.Event.t()} | {:error, term()}
  def emit(event_type, payload \\ %{}, opts \\ []) do
```

Private functions do not require `@doc`. Add inline comments only for
non-obvious logic. Comment the *why*, not the *what*:

```elixir
# Sample 1-in-10 events for failure-mode detection.
# Full detection on every event adds ~0.5ms per message on the hot path.
if :rand.uniform(@failure_mode_sample_rate) == 1 do
  FailureModes.detect(typed_event)
end
```

---

## Pattern Matching

Prefer function head pattern matching over `if`/`cond` in the function body:

```elixir
# Preferred
def handle({:ok, value}, state), do: process(value, state)
def handle({:error, reason}, state) do
  Logger.error("[MyModule] #{reason}")
  state
end

# Avoid
def handle(result, state) do
  if elem(result, 0) == :ok do
    process(elem(result, 1), state)
  else
    Logger.error("[MyModule] #{elem(result, 1)}")
    state
  end
end
```

Use `with` for happy-path chains that can fail at each step:

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

## GenServer Patterns

### handle_call for synchronous, handle_cast for fire-and-forget

```elixir
# Returns a value — use handle_call
def get_status do
  GenServer.call(__MODULE__, :get_status)
end

# No return needed — use handle_cast
def notify(event) do
  GenServer.cast(__MODULE__, {:notify, event})
end
```

### Defer slow initialization with handle_continue

Do not block `init/1`. Move slow work to `handle_continue`:

```elixir
@impl true
def init(opts) do
  {:ok, %{opts: opts}, {:continue, :init}}
end

@impl true
def handle_continue(:init, state) do
  data = load_data()   # slow — file I/O, HTTP, etc.
  {:noreply, Map.put(state, :data, data)}
end
```

### ETS for high-frequency reads

When a GenServer's state is read frequently by many callers, store it in ETS.
The GenServer serializes writes; ETS serves reads lock-free in the caller's
process:

```elixir
@table :my_data

def init(_opts) do
  :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
  {:ok, %{}}
end

def handle_call({:put, key, value}, _from, state) do
  :ets.insert(@table, {key, value})
  {:reply, :ok, state}
end

# Any process can call this without going through the GenServer
def get(key) do
  case :ets.lookup(@table, key) do
    [{^key, value}] -> {:ok, value}
    [] -> :error
  end
end
```

---

## Error Handling

Use `{:ok, value}` / `{:error, reason}` for all functions that can fail:

```elixir
@spec load(String.t()) :: {:ok, map()} | {:error, :not_found | :parse_error}
def load(path) do
  case File.read(path) do
    {:ok, contents} -> parse(contents)
    {:error, :enoent} -> {:error, :not_found}
  end
end
```

Tool `execute/1` functions must return `{:ok, String.t()}` or
`{:error, String.t()}`. The agent loop renders these strings directly in
conversation.

Use `raise` only for programmer errors (violated invariants, unreachable
states). Do not use exceptions for expected failures.

---

## Logging

Prefix every log message with `[ModuleName]` so lines can be filtered:

```elixir
require Logger

Logger.info("[MyModule] Initialized with #{count} items")
Logger.warning("[MyModule] Unexpected state: #{inspect(state)}")
Logger.error("[MyModule] Failed to connect: #{reason}")
Logger.debug("[MyModule] Processing: #{inspect(payload)}")
```

Never log: API keys, passwords, JWT tokens, or user message content (PII).

---

## Module Organization

Sections within a module, in order:

1. `@moduledoc`
2. `use`, `require`, `import`
3. `alias` (external libs first, then internal OSA modules)
4. `@behaviour`
5. Module attributes and struct definitions
6. Public API functions (with `@doc` + `@spec`)
7. `@impl true` callbacks
8. Private functions (`defp`)

Separate sections with a banner comment:

```elixir
# ── Client API ────────────────────────────────────────────────────

# ── Callbacks ─────────────────────────────────────────────────────

# ── Private ───────────────────────────────────────────────────────
```

---

## Imports and Aliases

Prefer `alias` over `import`. Use `import` only for macros (e.g.,
`require Logger`, `import Ecto.Query`):

```elixir
alias Req
alias Jason

alias OptimalSystemAgent.Events.Bus
alias OptimalSystemAgent.Agent.Memory
alias OptimalSystemAgent.Tools.Registry, as: Tools
```

---

## Configuration

Read configuration via a private function, not a module attribute. Attributes
are frozen at compile time; configuration may change at runtime:

```elixir
# Correct: reads current value on each call
defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)

# Incorrect: frozen at compile time
@max_iterations Application.get_env(:optimal_system_agent, :max_iterations, 30)
```

---

## Formatting

Run `mix format` before every commit. The project uses Elixir's built-in
formatter with default settings. CI fails on unformatted code:

```sh
mix format --check-formatted
```

---

## What to Avoid

- `spawn/1` or `spawn_link/1` without a supervisor — use `Task.start/1` or
  `Task.Supervisor.start_child/2`
- `Process.send_after/3` for recurring work — use `Agent.Scheduler`
- `String.to_atom/1` on external input — use `String.to_existing_atom/1` with
  a rescue clause
- Long `case` with more than 4–5 branches — refactor to function heads or a
  dispatch table
- Rescue exceptions to suppress crashes in supervised processes — let the
  supervisor restart

---

## Mix Aliases

| Alias | Expands to |
|-------|-----------|
| `mix setup` | `deps.get`, `ecto.setup`, `compile` |
| `mix chat` | Start CLI chat mode |
| `mix ecto.setup` | `ecto.create`, `ecto.migrate` |
| `mix ecto.reset` | `ecto.drop`, `ecto.setup` |

---

## Related

- [Creating a Module](../how-to/building-on-core/creating-a-module.md) — naming and placement
- [Creating a Service](../how-to/building-on-core/creating-a-service.md) — GenServer patterns
- [Review Guidelines](./review-guidelines.md) — what reviewers check
