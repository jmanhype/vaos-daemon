# Testing Strategy

How to test OSA effectively. Covers Mix test setup, test helpers, mocking LLM responses,
testing tools, and testing the event system.

## Audience

Developers writing tests for OSA modules or contributions.

---

## Test Setup

Tests are in `test/`. The test helper at `test/test_helper.exs` starts ExUnit and excludes
integration tests by default:

```elixir
ExUnit.start(exclude: [:integration])
```

Run all tests:

```bash
mix test
```

Run with integration tests included:

```bash
mix test --include integration
```

Run a specific test file:

```bash
mix test test/agent/hooks_test.exs
```

Run tests matching a tag:

```bash
mix test --only hooks
```

### Test Database

In test environment, `AgentServices` uses `MiosaKnowledge.Backend.ETS` instead of
`MiosaKnowledge.Backend.Mnesia` (configured in `Supervisors.AgentServices.init/1`).
This means knowledge store tests are fast and in-memory, requiring no database setup.

---

## Test Modes: Unit vs Integration

OSA tests fall into two categories:

**Unit tests** (`async: true`): Test pure logic without starting the supervision tree.
Most module-level tests use this mode. They can run in parallel and are fast.

**Integration tests** (`async: false`): Require running GenServers (Hooks, Registry, etc.).
These tests check that `Process.whereis/1` returns a PID and skip if the process is not
running. They must run synchronously because shared GenServer state is not test-isolated.

The hooks tests demonstrate this pattern:

```elixir
defmodule OptimalSystemAgent.Agent.HooksTest do
  use ExUnit.Case, async: false

  setup do
    case Process.whereis(OptimalSystemAgent.Agent.Hooks) do
      nil -> {:ok, %{available: false}}
      _pid -> {:ok, %{available: true}}
    end
  end

  test "all 6 built-in hooks are registered", %{available: available} do
    if not available, do: flunk("Hooks GenServer not running")
    # ... actual assertions
  end
end
```

---

## Mocking LLM Responses

OSA ships with a `MockProvider` in `test/support/` (or registered as
`OptimalSystemAgent.Test.MockProvider` in `Providers.Registry` when `Mix.env() == :test`).

### Using the Mock Provider

```elixir
defmodule MyModuleTest do
  use ExUnit.Case, async: true

  test "agent loop uses the response content" do
    # The mock provider is registered as :mock in test env
    result = OptimalSystemAgent.Providers.Registry.chat(
      [%{role: "user", content: "hello"}],
      provider: :mock
    )

    assert {:ok, %{content: content, tool_calls: []}} = result
    assert is_binary(content)
  end
end
```

### Writing a Custom Mock Provider

For fine-grained control over responses, implement the provider behaviour inline:

```elixir
defmodule MyTest.FakeProvider do
  @behaviour OptimalSystemAgent.Providers.Behaviour

  def name, do: :fake
  def default_model, do: "fake-model"
  def available_models, do: ["fake-model"]

  def chat(_messages, _opts) do
    {:ok, %{content: "fake response", tool_calls: [], usage: %{}}}
  end

  def chat_stream(_messages, callback, _opts) do
    callback.({:text_delta, "fake "})
    callback.({:text_delta, "response"})
    callback.({:done, %{content: "fake response", tool_calls: [], usage: %{}}})
    :ok
  end
end

# Register it at test runtime:
OptimalSystemAgent.Providers.Registry.register_provider(:fake, MyTest.FakeProvider)
```

### Simulating Tool Calls

To test how the agent handles a tool call response:

```elixir
defmodule ToolCallFakeProvider do
  @behaviour OptimalSystemAgent.Providers.Behaviour

  def name, do: :tool_call_fake
  def default_model, do: "fake-model"

  def chat(_messages, _opts) do
    {:ok, %{
      content: "",
      tool_calls: [
        %{
          id: "call_abc123",
          name: "file_read",
          arguments: %{"path" => "/tmp/test.txt"}
        }
      ],
      usage: %{input_tokens: 10, output_tokens: 5}
    }}
  end
end
```

---

## Testing Tools

Tool modules are stateless functions — test them directly without starting the supervision
tree.

```elixir
defmodule OptimalSystemAgent.Tools.Builtins.FileReadTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead

  setup do
    # Create a temp file for testing
    path = Path.join(System.tmp_dir!(), "osa_test_#{:erlang.unique_integer()}.txt")
    File.write!(path, "hello world")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "reads a file and returns content", %{path: path} do
    assert {:ok, content} = FileRead.execute(%{"path" => path})
    assert content =~ "hello world"
  end

  test "returns error for missing file" do
    assert {:error, reason} = FileRead.execute(%{"path" => "/does/not/exist"})
    assert is_binary(reason)
  end
end
```

### Testing Tool Schema Validation

The `Tools.Registry.validate_arguments/2` function validates arguments against the tool's
JSON Schema. Test schemas against known-good and known-bad inputs:

```elixir
defmodule MyToolSchemaTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Registry

  defmodule MyTool do
    @behaviour MiosaTools.Behaviour
    def name, do: "my_tool"
    def description, do: "test"
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    end
    def execute(%{"query" => q}), do: {:ok, q}
  end

  test "valid arguments pass" do
    assert :ok = Registry.validate_arguments(MyTool, %{"query" => "hello"})
  end

  test "missing required field fails" do
    assert {:error, message} = Registry.validate_arguments(MyTool, %{})
    assert message =~ "my_tool"
  end
end
```

The pattern used in `test/tools/schema_validation_test.exs` follows this approach with
`FakeTool` and `OptionalTool` module definitions.

---

## Testing Events

Test event emission and handling without needing the full supervision tree:

```elixir
defmodule EventTest do
  use ExUnit.Case, async: false  # Events.Bus state is shared

  test "emitting a system_event calls registered handlers" do
    test_pid = self()

    ref = OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn event ->
      send(test_pid, {:received, event})
    end)

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{event: :test}, source: "test")

    assert_receive {:received, event}, 1000
    assert event[:type] == :system_event

    OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref)
  end
end
```

---

## Testing GenServers

The standard approach for GenServer tests follows `loop_test.exs`:

```elixir
defmodule OptimalSystemAgent.Agent.LoopTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure the Registry is running (start it if not already):
    case Process.whereis(OptimalSystemAgent.SessionRegistry) do
      nil ->
        start_supervised!(
          {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry}
        )
      _pid -> :ok
    end
    :ok
  end

  test "starts a GenServer process for a new session" do
    session_id = "smoke-loop-#{:erlang.unique_integer([:positive])}"

    pid = start_supervised!(
      {OptimalSystemAgent.Agent.Loop, [session_id: session_id, channel: :cli]},
      id: String.to_atom(session_id)
    )

    assert Process.alive?(pid)
  end
end
```

Key points:
- Use `start_supervised!/2` so ExUnit cleans up the process after the test.
- Generate unique IDs with `:erlang.unique_integer([:positive])` to prevent collisions.
- Check `Process.whereis/1` before starting dependencies to handle both isolated and
  full-application test environments.

---

## Test Coverage

Run with coverage:

```bash
mix test --cover
```

Coverage is reported by `mix test --cover`. The project targets 80%+ statement coverage.
Files in `lib/optimal_system_agent/` are included; generated files and `priv/` are not.

---

## Common Pitfalls

**Async tests sharing ETS tables:** OSA's ETS tables (`:osa_hooks`, `:osa_event_handlers`,
etc.) are global. Tests that mutate these tables must use `async: false`. Tests that only
read can use `async: true`.

**GenServer not running:** Many integration tests check `Process.whereis/1` and call
`flunk/1` when the process is absent. This is intentional — these tests only run when the
full application is started (e.g., `mix test` from the project root with the app started).

**Tool tests with side effects:** Tools like `ShellExecute`, `FileWrite`, and `Git` have
real side effects. Always use `System.tmp_dir!/0` for file paths and `on_exit/1` to clean up.

**Timing in event tests:** Event handlers run in supervised Tasks. After emitting an event,
use `assert_receive` with a timeout (typically 500-1000ms) rather than asserting
synchronously.
