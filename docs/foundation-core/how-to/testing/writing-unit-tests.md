# Writing Unit Tests

Audience: developers writing ExUnit tests for OSA modules.

---

## Conventions

### File naming

Test files mirror the source tree under `test/`:

```
lib/optimal_system_agent/agent/hooks.ex
  → test/optimal_system_agent/agent/hooks_test.exs

lib/optimal_system_agent/events/bus.ex
  → test/optimal_system_agent/events/bus_test.exs

lib/optimal_system_agent/channels/noise_filter.ex
  → test/optimal_system_agent/channels/noise_filter_test.exs
```

### Module naming

```elixir
defmodule OptimalSystemAgent.Agent.HooksTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Hooks
  # ...
end
```

### Async tests

Use `async: true` for tests that do not touch shared ETS tables, the SQLite
database, or any named process that runs as a singleton. Most pure unit tests
qualify.

Use `async: false` when:
- The test reads or writes global ETS tables (`:osa_hooks`, `:osa_cancel_flags`, etc.)
- The test starts the full application (`OptimalSystemAgent.Application`)
- The test sends messages to a named GenServer

---

## Test Structure

Follow the Arrange-Act-Assert pattern:

```elixir
defmodule OptimalSystemAgent.Channels.NoiseFilterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.NoiseFilter

  describe "check/2" do
    test "passes substantive messages" do
      # Arrange
      message = "Please analyze the deployment pipeline for bottlenecks"

      # Act
      result = NoiseFilter.check(message, nil)

      # Assert
      assert result == :pass
    end

    test "filters single-character inputs" do
      assert NoiseFilter.check("k", nil) == :filtered
    end

    test "filters common filler words" do
      for word <- ["ok", "thanks", "lol", "yeah"] do
        assert NoiseFilter.check(word, nil) == :filtered,
               "Expected '#{word}' to be filtered"
      end
    end

    test "filters low signal weight messages" do
      # Signal weight of 0.10 is below the definitely_noise threshold (0.15)
      assert NoiseFilter.check("ok", 0.10) == :filtered
    end

    test "requests clarification for uncertain signal weight" do
      # Weight 0.50 falls in the uncertain band (0.35–0.65)
      result = NoiseFilter.check("hello", 0.50)
      assert result == :clarify
    end
  end
end
```

---

## Mocking LLM Calls

LLM calls are disabled in the test environment. The test configuration sets:

```elixir
# config/test.exs
config :optimal_system_agent, classifier_llm_enabled: false
config :optimal_system_agent, compactor_llm_enabled: false
```

This means:
- `Signal.Classifier` falls back to deterministic pattern matching
- `Agent.Compactor` skips LLM summarization steps (uses truncation only)

For modules that call the LLM directly via `MiosaProviders.Registry`, inject a
mock provider using `Application.put_env/3` inside the test:

```elixir
setup do
  # Override provider to return a fixed response
  Application.put_env(:optimal_system_agent, :test_llm_response, %{
    content: "Mocked response",
    tool_calls: []
  })
  on_exit(fn -> Application.delete_env(:optimal_system_agent, :test_llm_response) end)
  :ok
end
```

For more isolated tests, pass the provider as a dependency:

```elixir
# Design the module to accept a provider module as a parameter
MyModule.process(message, provider: MockProvider)
```

---

## Testing Tools Directly

Call `execute/1` directly without going through the hook pipeline or agent loop:

```elixir
defmodule OptimalSystemAgent.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead

  describe "execute/1" do
    test "reads an existing file" do
      # Write a temp file
      path = System.tmp_dir!() <> "/osa_test_#{:rand.uniform(9999)}.txt"
      File.write!(path, "hello from OSA")
      on_exit(fn -> File.rm(path) end)

      result = FileRead.execute(%{"path" => path})

      assert {:ok, content} = result
      assert content =~ "hello from OSA"
    end

    test "returns error for nonexistent file" do
      result = FileRead.execute(%{"path" => "/nonexistent/path/file.txt"})
      assert {:error, _reason} = result
    end
  end
end
```

---

## Testing GenServers

Start the GenServer under a test-specific name to avoid conflicts with the
running application:

```elixir
defmodule OptimalSystemAgent.Agent.HooksTest do
  use ExUnit.Case, async: false   # async: false — uses named GenServer

  alias OptimalSystemAgent.Agent.Hooks

  setup do
    # Start a fresh Hooks GenServer for this test
    {:ok, pid} = Hooks.start_link(name: :"test_hooks_#{:rand.uniform(9999)}")
    %{hooks_pid: pid}
  end

  test "registers and runs a hook", %{hooks_pid: pid} do
    name = "test_hook_#{:rand.uniform(9999)}"

    GenServer.call(pid, {:register, %{
      name: name,
      event: :pre_tool_use,
      priority: 50,
      handler: fn payload -> {:ok, Map.put(payload, :tagged, true)} end
    }})

    {:ok, result} = GenServer.call(pid, {:run, :pre_tool_use, %{tool: "file_read"}})
    assert result[:tagged] == true
  end
end
```

---

## Test Utilities and Fixtures

Shared helpers live in `test/support/`. ExUnit includes this path for the
test environment via `elixirc_paths(:test)` in `mix.exs`.

```elixir
# test/support/factories.ex
defmodule OptimalSystemAgent.Test.Factories do
  def session_id, do: "test:#{:rand.uniform(999_999)}"

  def user_message(content \\ "Hello") do
    %{
      role: "user",
      content: content,
      timestamp: DateTime.utc_now()
    }
  end
end
```

Use in tests:

```elixir
import OptimalSystemAgent.Test.Factories

session_id = session_id()
msg = user_message("Deploy the staging environment")
```

---

## Running Tests

```sh
# All unit tests
mix test

# A single file
mix test test/optimal_system_agent/channels/noise_filter_test.exs

# A specific test by line number
mix test test/optimal_system_agent/channels/noise_filter_test.exs:15

# With verbose output
mix test --trace

# Include integration tests (excluded by default)
mix test --include integration
```

---

## Coverage

Generate an HTML coverage report:

```sh
mix test --cover
```

Coverage is reported per file. Target: 80% statement coverage for all public
modules in `lib/optimal_system_agent/`.

---

## Related

- [Integration Tests](./integration-tests.md) — tests that require the full OTP tree
- [Coding Standards](../../development/coding-standards.md) — style and patterns
