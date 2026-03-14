# Custom Middleware and Hooks

OSA has two complementary middleware systems. The `Agent.Hooks` system intercepts tool
execution at the agent level. The `MiosaTools.Middleware` system intercepts tool execution
at the SDK level. This guide covers both.

## Audience

Developers who need to intercept, block, transform, or observe tool calls before or after
execution.

---

## Agent.Hooks System

`Agent.Hooks` is the primary hook system. Six built-in hooks are registered at boot:

| Name | Event | Priority | Purpose |
|------|-------|----------|---------|
| `spend_guard` | `pre_tool_use` | 8 | Block when budget is exceeded |
| `security_check` | `pre_tool_use` | 10 | Block dangerous shell commands |
| `mcp_cache` | `pre_tool_use` | 15 | Inject cached MCP schemas |
| `mcp_cache_post` | `post_tool_use` | 15 | Populate MCP schema cache |
| `cost_tracker` | `post_tool_use` | 25 | Record actual API spend |
| `telemetry` | `post_tool_use` | 90 | Emit tool timing telemetry |

Priority ordering: lower number runs first. Pre-tool hooks can block the chain. Post-tool
hooks observe results.

### Supported Hook Events

```elixir
@type hook_event ::
  :pre_tool_use    # Before a tool executes — can block
  | :post_tool_use   # After a tool executes — observe only
  | :pre_compact     # Before context window compaction
  | :session_start   # When a session begins
  | :session_end     # When a session ends
  | :pre_response    # Before the agent sends a response
  | :post_response   # After the agent sends a response
```

### Hook Return Values

```elixir
{:ok, payload}        # Continue with (possibly modified) payload
{:block, reason}      # Stop the chain; only valid for pre_tool_use
:skip                 # Skip this hook silently; chain continues
```

### Writing a Custom Hook

```elixir
# A hook that logs all file writes to an audit trail:
audit_hook = fn payload ->
  if payload.tool_name == "file_write" do
    path = get_in(payload, [:arguments, "path"]) || "unknown"
    session = payload[:session_id] || "unknown"
    Logger.info("[Audit] session=#{session} file_write path=#{path}")
  end
  {:ok, payload}
end

OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "audit_writes",
  audit_hook,
  priority: 5  # Run before security_check
)
```

### Blocking Tool Execution

A hook returning `{:block, reason}` halts the pre_tool_use chain. The tool does not execute.
The reason string is returned to the caller as `{:blocked, reason}`.

```elixir
# Block all network tools for a restricted session:
restriction_hook = fn payload ->
  network_tools = ["web_fetch", "web_search", "github"]
  if payload.tool_name in network_tools do
    {:block, "Network access is disabled for this session"}
  else
    {:ok, payload}
  end
end

OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "network_restriction",
  restriction_hook,
  priority: 1  # Must run before security_check (priority 10)
)
```

### Modifying the Payload

Pre-tool hooks can transform the payload before the tool executes. The modified payload
flows to the next hook and eventually to the tool itself.

```elixir
# Inject the session's workspace dir into every file operation:
workspace_hook = fn payload ->
  case payload.tool_name do
    tool when tool in ["file_read", "file_write", "file_edit"] ->
      args = payload.arguments
      # Prepend workspace to relative paths
      updated_args =
        if Map.has_key?(args, "path") and not String.starts_with?(args["path"], "/") do
          workspace = fetch_workspace(payload.session_id)
          Map.put(args, "path", Path.join(workspace, args["path"]))
        else
          args
        end
      {:ok, %{payload | arguments: updated_args}}

    _ ->
      {:ok, payload}
  end
end
```

### Inspecting Hook State

```elixir
# List all registered hooks and their priorities:
OptimalSystemAgent.Agent.Hooks.list_hooks()
# => %{
#   pre_tool_use: [
#     %{name: "spend_guard", priority: 8},
#     %{name: "security_check", priority: 10},
#     ...
#   ],
#   post_tool_use: [...]
# }

# Get execution metrics:
OptimalSystemAgent.Agent.Hooks.metrics()
# => %{
#   pre_tool_use: %{calls: 42, total_us: 12000, avg_us: 285},
#   post_tool_use: %{...}
# }
```

### Hooks Architecture

Registration is serialized through the `Agent.Hooks` GenServer. Hook execution reads
directly from ETS in the caller's process (no GenServer bottleneck). Metrics are tracked
in a separate ETS table with write_concurrency enabled.

A crashing hook does not crash the pipeline. Errors are caught, logged, and the chain
continues with the original payload. This is verified by the test in `hooks_test.exs`:

```elixir
test "a crashing post_tool_use hook does not crash the pipeline" do
  Hooks.register(:post_tool_use, "crasher_hook", fn _payload ->
    raise "kaboom"
  end, priority: 1)

  payload = %{tool_name: "test", result: "ok", duration_ms: 10, session_id: "test"}
  result = Hooks.run(:post_tool_use, payload)
  assert {:ok, _} = result
end
```

### Running Hooks Asynchronously

For post-tool hooks whose results are not needed by the caller:

```elixir
# Fire-and-forget — returns :ok immediately, runs hooks in a Task.
Hooks.run_async(:post_tool_use, payload)
```

---

## MiosaTools.Middleware System

The `MiosaTools.Middleware` system is a composable pipeline for the SDK layer. It wraps
tool execution with a stack of middleware modules.

### Middleware Behaviour

```elixir
@behaviour MiosaTools.Middleware

@impl true
def call(instruction, next, opts) do
  # instruction :: %Instruction{tool: String.t(), params: map()}
  # next :: (instruction -> {:ok, result} | {:error, reason})
  # opts :: keyword()

  # Pre-processing:
  modified = transform_instruction(instruction)

  # Call the next middleware (or the tool itself):
  case next.(modified) do
    {:ok, result} ->
      # Post-processing:
      {:ok, enrich_result(result)}

    {:error, _} = error ->
      error
  end
end
```

### Built-in Middleware Modules

Three built-in middleware modules are available:

**`Middleware.Validation`** — Rejects instructions with empty tool names. Runs first in
any recommended stack.

**`Middleware.Timing`** — Records execution duration. Does not alter the result.

**`Middleware.Logging`** — Logs tool name and outcome. Does not alter the result.

### Composing a Middleware Stack

```elixir
alias MiosaTools.{Instruction, Middleware}

instruction = %Instruction{
  tool: "my_tool",
  params: %{"query" => "example"}
}

stack = [
  Middleware.Validation,
  Middleware.Timing,
  Middleware.Logging,
  MyApp.CustomMiddleware
]

executor = fn inst ->
  OptimalSystemAgent.Tools.Registry.execute(inst.tool, inst.params)
end

case Middleware.execute(instruction, stack, executor) do
  {:ok, result} -> handle_result(result)
  {:error, reason} -> handle_error(reason)
end
```

### Middleware with Options

Pass options via tuple entries in the stack:

```elixir
stack = [
  Middleware.Validation,
  {MyApp.RateLimitMiddleware, [max_calls_per_minute: 60]},
  Middleware.Timing
]
```

The middleware receives opts as the third argument to `call/3`.

### Short-Circuiting

Middleware can halt the chain by returning an error without calling `next`:

```elixir
defmodule MyApp.BlockingMiddleware do
  @behaviour MiosaTools.Middleware

  @impl true
  def call(instruction, _next, _opts) do
    if blocked?(instruction.tool) do
      {:error, "Tool #{instruction.tool} is not permitted"}
    else
      # Never called next — chain is halted
      {:error, "blocked"}
    end
  end
end
```

This is the pattern tested in `test/tools/middleware_test.exs`:

```elixir
test "middleware can short-circuit execution" do
  inst = %Instruction{tool: "test", params: %{}}
  assert {:error, "blocked by middleware"} =
           Middleware.execute(inst, [BlockingMW], &success_executor/1)
end
```

---

## Choosing Between Hooks and Middleware

Use **`Agent.Hooks`** when:
- You need to intercept tool calls in the live agent loop.
- You want to block execution (pre_tool_use) or observe results (post_tool_use).
- You need to react to session lifecycle events.
- You are extending a running OSA instance without modifying core code.

Use **`MiosaTools.Middleware`** when:
- You are building an SDK application on top of OSA.
- You need a composable, ordered pipeline for a specific set of tool calls.
- You want to unit-test the pipeline in isolation without a running agent.
