# Integration Tests

Audience: developers writing tests that exercise multiple OSA components
together, including the supervision tree, channels, and the agent loop.

---

## When to Write Integration Tests

Write an integration test when:

- The behaviour you are testing depends on two or more GenServers interacting
- You need to verify that a message flows correctly through channels,
  the agent loop, and the response path
- You need to verify that hooks fire in the correct order with the correct
  payload
- You are testing the full tool execution pipeline (hook + executor + result)

For isolated module logic, write a unit test instead. Integration tests are
slower and harder to maintain.

---

## Setup

Integration tests require the full OTP application tree to be running.
`test/test_helper.exs` starts the application:

```elixir
# test/test_helper.exs
ExUnit.start(exclude: [:integration])
```

Integration tests are tagged with `@tag :integration` and excluded from the
default `mix test` run. Include them explicitly:

```sh
mix test --include integration
```

### async: false

Integration tests must use `async: false`. They share the running application's
singleton processes (Events.Bus, Tools.Registry, Agent.Memory, etc.).

```elixir
defmodule OptimalSystemAgent.Integration.AgentLoopTest do
  use ExUnit.Case, async: false

  @moduletag :integration
end
```

---

## Application Setup

The application starts automatically when the test suite runs (because
`test_helper.exs` is evaluated with the application started in the Mix test
context). Verify it is running:

```elixir
setup do
  # Ensure the application is started
  assert Application.started_applications()
         |> Enum.any?(fn {app, _, _} -> app == :optimal_system_agent end)

  :ok
end
```

---

## Testing Agent Session Lifecycle

```elixir
defmodule OptimalSystemAgent.Integration.SessionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Events.Bus

  setup do
    session_id = "test:#{:rand.uniform(999_999)}"

    # Start an agent loop for this session
    {:ok, _pid} = DynamicSupervisor.start_child(
      OptimalSystemAgent.SessionSupervisor,
      {Loop, session_id: session_id, channel: :test}
    )

    on_exit(fn ->
      # Stop the loop after the test
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    %{session_id: session_id}
  end

  test "session registers in SessionRegistry", %{session_id: session_id} do
    assert [{_pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
  end

  test "message is persisted to memory", %{session_id: session_id} do
    Loop.process_message(session_id, %{
      content: "What is 2 + 2?",
      user_id: "test_user",
      channel: :test
    })

    # Allow async processing
    Process.sleep(500)

    messages = Memory.load_session(session_id)
    assert Enum.any?(messages, fn m -> m[:content] =~ "2 + 2" or m["content"] =~ "2 + 2" end)
  end
end
```

---

## Testing Channels

Channel adapters can be tested by sending messages directly to the loop and
verifying the response is dispatched back through the expected path.

For the CLI channel:

```elixir
defmodule OptimalSystemAgent.Integration.CLIChannelTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias OptimalSystemAgent.Channels.CLI

  test "CLI channel processes a message and returns a response" do
    # The CLI channel routes through the agent loop.
    # In tests, LLM calls are mocked so we get a deterministic response.
    session_id = "cli:test_#{:rand.uniform(9999)}"

    # Capture the response (the CLI channel sends {:response, text} to the caller)
    # This is adapter-specific — check the adapter's send_message/3 implementation
    # for the exact mechanism.
    assert :ok = CLI.send_message(session_id, "hello", [])
  end
end
```

For HTTP channel endpoints, use `Plug.Test`:

```elixir
defmodule OptimalSystemAgent.Integration.HTTPChannelTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @moduletag :integration

  alias OptimalSystemAgent.Channels.HTTP

  @opts HTTP.init([])

  test "GET /health returns ok" do
    conn =
      conn(:get, "/health")
      |> HTTP.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
  end

  test "POST /api/v1/orchestrate requires valid session_id" do
    conn =
      conn(:post, "/api/v1/orchestrate", Jason.encode!(%{
        session_id: "test:abc",
        message: "Hello"
      }))
      |> put_req_header("content-type", "application/json")
      |> HTTP.call(@opts)

    # Without auth configured (test.exs), the request should be processed
    assert conn.status in [200, 201, 202]
  end
end
```

---

## Testing Tool Execution Pipeline

Verify that a tool call goes through the full hook pipeline and executes
correctly:

```elixir
defmodule OptimalSystemAgent.Integration.ToolPipelineTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  test "pre_tool_use hook runs before tool execution" do
    results = Agent.get({:test_results, __MODULE__}, fn s -> s end) || []

    Hooks.register(%{
      name: "test_audit_hook_#{:rand.uniform(9999)}",
      event: :pre_tool_use,
      priority: 50,
      handler: fn payload ->
        send(self(), {:hook_fired, payload[:tool]})
        {:ok, payload}
      end
    })

    Tools.execute("file_read", %{"path" => "/tmp"})

    assert_receive {:hook_fired, "file_read"}, 1_000
  end

  test "spend_guard blocks tool calls when budget is exceeded" do
    # Artificially exceed the budget
    Application.put_env(:optimal_system_agent, :daily_budget_usd, 0.0)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :daily_budget_usd, 50.0) end)

    # Run the hook pipeline directly
    result = Hooks.run(:pre_tool_use, %{tool: "file_write", session_id: "test"})
    assert {:blocked, _reason} = result
  end
end
```

---

## Testing Event Subscriptions

```elixir
defmodule OptimalSystemAgent.Integration.EventBusTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias OptimalSystemAgent.Events.Bus

  test "emitting an event triggers subscribed handler" do
    test_pid = self()

    Bus.subscribe(:system_event, fn event ->
      send(test_pid, {:received, event})
    end)

    Bus.emit(:system_event, %{message: "integration test event"})

    assert_receive {:received, event}, 1_000
    assert event.payload[:message] == "integration test event"
  end
end
```

---

## Timing and async: false

Integration tests often involve asynchronous operations (events dispatched via
`Task.Supervisor`, hooks running via `run_async/2`, etc.). Strategies:

1. Use `assert_receive` with a reasonable timeout (500–2_000 ms).
2. Use `Process.sleep/1` sparingly, only when polling the database or ETS.
3. Register a hook or subscribe to an event to receive a signal when the async
   operation completes, rather than sleeping.

```elixir
# Preferred: receive-based assertion
assert_receive {:tool_complete, result}, 2_000

# Acceptable: sleep when no notification mechanism exists
Process.sleep(300)
assert Memory.load_session(session_id) != []

# Avoid: fixed large sleeps
Process.sleep(5_000)  # fragile and slow
```

---

## Related

- [Writing Unit Tests](./writing-unit-tests.md) — isolated module tests
- [Debugging Core](../debugging/debugging-core.md) — inspect the running system when tests fail
