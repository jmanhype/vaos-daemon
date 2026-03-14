# Extension Points

Audience: engineers adding new capabilities to OSA — custom tools, providers,
channels, hooks, or swarm patterns. Each section shows the exact behaviour or
struct the new implementation must satisfy, with a working skeleton.

---

## 1. Custom Tools

Tools are the primary extension point. A tool is a module that implements
`MiosaTools.Behaviour` and registers itself in `Tools.Registry`.

### Behaviour Contract

```elixir
# lib/miosa/shims.ex
defmodule MiosaTools.Behaviour do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()         # JSON Schema object
  @callback execute(params :: map()) :: {:ok, any()} | {:error, String.t()}
  @callback safety() :: :read_only | :write_safe | :write_destructive | :terminal
  @callback available?() :: boolean()

  @optional_callbacks safety: 0, available?: 0
end
```

### Minimal Implementation

```elixir
defmodule OptimalSystemAgent.Tools.Builtins.MyTool do
  use MiosaTools.Behaviour
  require Logger

  @impl true
  def name, do: "my_tool"

  @impl true
  def description, do: "Does something useful given an input string."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string", "description" => "The input to process"}
      },
      "required" => ["input"]
    }
  end

  @impl true
  def execute(%{"input" => input}) do
    result = String.upcase(input)
    {:ok, result}
  end

  def execute(_), do: {:error, "Missing required parameter: input"}

  @impl true
  def safety, do: :read_only

  @impl true
  def available?, do: true
end
```

### Registration

**At boot** — add the tool to the `load_builtin_tools/0` map in `Tools.Registry`:

```elixir
# lib/optimal_system_agent/tools/registry.ex
defp load_builtin_tools do
  %{
    # ... existing tools ...
    "my_tool" => OptimalSystemAgent.Tools.Builtins.MyTool
  }
end
```

**At runtime** (hot reload, no restart required):

```elixir
OptimalSystemAgent.Tools.Registry.register(MyApp.MyTool)
```

This triggers a goldrush dispatcher recompile. The tool is immediately available
to running sessions.

### Argument Validation

Arguments are validated against `parameters/0` using `ex_json_schema` before
`execute/1` is called. If validation fails, the LLM receives the error string and
will retry with corrected arguments. Your schema should be precise to minimize
retry loops.

### Availability Gating

`available?/0` is called each time the tool list is built for a session. Return
`false` to hide the tool from the LLM when its dependency is absent:

```elixir
@impl true
def available? do
  System.find_executable("my-binary") != nil
end
```

---

## 2. Custom LLM Providers

A provider adapter wraps an external LLM API. All providers implement
`OptimalSystemAgent.Providers.Behaviour`.

### Behaviour Contract

```elixir
# lib/optimal_system_agent/providers/behaviour.ex
@callback chat(messages :: list(message()), opts :: keyword()) :: chat_result()
@callback chat_stream(messages :: list(message()), callback :: function(), opts :: keyword()) ::
            :ok | {:error, String.t()}
@callback name() :: atom()
@callback default_model() :: String.t()
@callback available_models() :: list(String.t())

@optional_callbacks [chat_stream: 3, available_models: 0]
```

Canonical response shape:

```elixir
{:ok, %{
  content: String.t(),          # text response (empty if tool_calls present)
  tool_calls: [                 # list of tool invocations
    %{id: String.t(), name: String.t(), arguments: map()}
  ]
}}
```

### Minimal Implementation

```elixir
defmodule MyApp.Providers.MyLLM do
  @behaviour OptimalSystemAgent.Providers.Behaviour

  @base_url "https://api.myllm.example.com/v1"

  @impl true
  def name, do: :myllm

  @impl true
  def default_model, do: "myllm-base"

  @impl true
  def available_models, do: ["myllm-base", "myllm-large"]

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :myllm_api_key)
    model = Keyword.get(opts, :model, default_model())

    body = %{
      model: model,
      messages: format_messages(messages),
      max_tokens: Keyword.get(opts, :max_tokens, 4096)
    }

    case Req.post("#{@base_url}/chat/completions",
           json: body,
           headers: [{"Authorization", "Bearer #{api_key}"}],
           receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, nil}}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{"role" => msg.role, "content" => msg.content}
    end)
  end

  defp parse_response(%{"choices" => [%{"message" => msg} | _]}) do
    tool_calls =
      (msg["tool_calls"] || [])
      |> Enum.map(fn tc ->
        %{
          id: tc["id"],
          name: tc["function"]["name"],
          arguments: Jason.decode!(tc["function"]["arguments"])
        }
      end)

    {:ok, %{content: msg["content"] || "", tool_calls: tool_calls}}
  end

  defp parse_response(other), do: {:error, "Unexpected response: #{inspect(other)}"}
end
```

### Registration

**Runtime** (no restart):

```elixir
OptimalSystemAgent.Providers.Registry.register_provider(:myllm, MyApp.Providers.MyLLM)
```

**Config-time** — the registry's `@providers` compile-time map is the canonical
source. For permanent additions, add to `Providers.Registry` directly and rebuild.

### Rate-Limit Signaling

Return `{:error, {:rate_limited, retry_after_seconds}}` to signal the registry to
apply backoff and try the next provider in the fallback chain. The HealthChecker
records this and marks the provider as temporarily unavailable.

---

## 3. Custom Channel Adapters

A channel adapter connects a messaging platform to the agent loop.

### Behaviour Contract

```elixir
# lib/optimal_system_agent/channels/behaviour.ex
@callback channel_name() :: atom()
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(chat_id :: String.t(), message :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}
@callback connected?() :: boolean()
```

### Minimal Implementation

```elixir
defmodule MyApp.Channels.MyPlatform do
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Agent.Loop

  # ── Behaviour Callbacks ──

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :my_platform

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, _opts \\ []) do
    GenServer.call(__MODULE__, {:send, chat_id, message})
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(_opts) do
    api_key = Application.get_env(:optimal_system_agent, :my_platform_api_key)
    if is_nil(api_key) do
      Logger.info("[MyPlatform] Not configured — skipping")
      :ignore
    else
      {:ok, %{api_key: api_key}}
    end
  end

  @impl true
  def handle_cast({:inbound, platform_user_id, text}, state) do
    # Get or create a session for this user
    session_id = Session.session_id_for(:my_platform, platform_user_id)
    Session.ensure_started(session_id, channel: :my_platform, user_id: platform_user_id)

    # Hand off to the agent loop
    Task.start(fn ->
      case Loop.process_message(session_id, text) do
        {:ok, response} ->
          send_message(platform_user_id, response)
        {:error, reason} ->
          Logger.error("[MyPlatform] Loop error: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:send, chat_id, message}, _from, state) do
    result = Req.post("https://api.myplatform.example.com/send",
      json: %{to: chat_id, text: message},
      headers: [{"Authorization", "Bearer #{state.api_key}"}])

    case result do
      {:ok, %{status: 200}} -> {:reply, :ok, state}
      other -> {:reply, {:error, other}, state}
    end
  end
end
```

### Registration

Channels are started by `Channels.Starter` via `Channels.Manager`. To add a new
channel, extend `Channels.Manager.channel_specs/0` (or the Starter's channel
list) to include your module. Channels that return `:ignore` from `init/1`
(missing config) are silently skipped.

---

## 4. Custom Hooks

Hooks intercept the agent lifecycle at defined events. They can inspect, modify,
or block execution.

### Hook Function Type

```elixir
# lib/optimal_system_agent/agent/hooks.ex
@type hook_fn :: (map() -> {:ok, map()} | {:block, String.t()} | :skip)

@type hook_event ::
    :pre_tool_use | :post_tool_use | :pre_compact
    | :session_start | :session_end | :pre_response | :post_response
```

### Hook Payload Contents

| Event | Payload keys |
|-------|-------------|
| `:pre_tool_use` | `:tool_name`, `:arguments`, `:session_id`, `:provider` |
| `:post_tool_use` | `:tool_name`, `:arguments`, `:result`, `:duration_ms`, `:session_id` |
| `:pre_compact` | `:messages`, `:session_id`, `:turn_count` |
| `:session_start` | `:session_id`, `:channel`, `:user_id` |
| `:session_end` | `:session_id`, `:turn_count`, `:duration_ms` |
| `:pre_response` | `:content`, `:session_id`, `:tool_calls_count` |
| `:post_response` | `:content`, `:session_id`, `:delivered` |

### Registration

```elixir
OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "my_audit_hook",
  fn payload ->
    Logger.info("[Audit] Tool #{payload.tool_name} by session #{payload.session_id}")
    {:ok, payload}   # always continue
  end,
  priority: 20       # lower = runs earlier; built-in security_check is p10
)
```

### Blocking Example

```elixir
OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "production_lock",
  fn %{tool_name: tool, arguments: args} = payload ->
    if tool == "shell_execute" and is_prod_command?(args["command"]) do
      {:block, "shell_execute blocked in production: #{args["command"]}"}
    else
      {:ok, payload}
    end
  end,
  priority: 5        # run before security_check (p10)
)
```

A `:block` return prevents tool execution and injects the reason string into the
conversation as a system message. The LLM then receives the block reason and will
produce a response explaining why it cannot execute the request.

### Modifying Payloads

Pre-hooks can modify `arguments` before execution. This is useful for parameter
injection (e.g., always prepending a working directory to file paths):

```elixir
OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "path_prefix",
  fn %{tool_name: "file_read", arguments: args} = payload ->
    safe_path = Path.join("/safe/root", args["path"])
    {:ok, put_in(payload, [:arguments, "path"], safe_path)}
  end,
  priority: 30
)
```

---

## 5. Custom Swarm Patterns

Swarms coordinate multiple `Agent.Loop` processes. The four built-in patterns are
`:parallel`, `:pipeline`, `:debate`, and `:review`. New patterns implement the
`Swarm.Patterns` behaviour (or are added directly as clauses).

### Built-in Pattern Invocation

```elixir
# lib/optimal_system_agent/swarm/orchestrator.ex
{:ok, swarm_id} = OptimalSystemAgent.Swarm.Orchestrator.launch(
  "Analyze the codebase for security vulnerabilities and generate a fix plan",
  pattern: :pipeline,     # optional — auto-selected by Planner if omitted
  max_agents: 5,
  timeout_ms: 300_000
)
```

### Launching a Custom Pattern via the Orchestrate Tool

From within an agent session, the `orchestrate` tool invokes swarm execution:

```elixir
# Tool call the LLM can make:
%{name: "orchestrate", arguments: %{
  "task" => "Audit and fix all type errors in lib/",
  "pattern" => "pipeline",    # parallel | pipeline | debate | review
  "agents" => [
    %{"role" => "analyzer", "instruction" => "Find all type errors, output JSON list"},
    %{"role" => "fixer", "instruction" => "Fix each error from previous agent's output"}
  ]
}}
```

### Adding a New Pattern

Patterns are selected by `Swarm.Planner.select_pattern/1`. To add a custom pattern:

1. Add a clause to `OptimalSystemAgent.Swarm.Patterns` (or a new module that
   `Swarm.Orchestrator` can dispatch to).
2. Add the pattern atom to `@valid_patterns` in `Swarm.Orchestrator`.
3. Implement the coordination logic that spawns `Swarm.Worker` processes and
   collects results.

Pattern selection heuristics in `Swarm.Planner`:
- `:parallel` — independent subtasks, maximize throughput
- `:pipeline` — sequential subtasks where each depends on the previous
- `:debate` — generate multiple perspectives, synthesize
- `:review` — implement, then critique/improve

---

## 6. Custom Skills (No-Code Extension)

Skills are the simplest extension point — no Elixir code required. Create a
`SKILL.md` file at `~/.osa/skills/<name>/SKILL.md`:

```markdown
---
name: deploy-checker
description: Checks deployment readiness before any deploy action
triggers:
  - deploy
  - deployment
  - release
priority: 2
---

Before executing any deployment:

1. Check that all tests pass with `shell_execute`: `mix test`
2. Verify no uncommitted changes with `git`: `git status --porcelain`
3. Confirm the deployment target environment
4. Only proceed if all checks pass

If any check fails, explain the failure and stop.
```

When a user message contains "deploy", "deployment", or "release", the skill
instructions are injected into the system prompt for that turn. The LLM follows
the instructions without any code change.

Skill files are loaded at boot from `priv/skills/` (bundled) and `~/.osa/skills/`
(user). User skills override bundled skills with the same name.

Skills are reloadable at runtime:

```elixir
OptimalSystemAgent.Tools.Registry.reload_skills()
```

---

## 7. Custom MCP Servers

MCP (Model Context Protocol) servers expose tools to OSA via JSON-RPC over stdio.
No Elixir code is needed — OSA manages server lifecycle and tool registration
automatically.

### Configuration

Add a server entry to `~/.osa/mcp.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "node",
      "args": ["/path/to/my-mcp-server/index.js"],
      "env": {
        "MY_API_KEY": "sk-..."
      }
    }
  }
}
```

### Runtime Registration

OSA calls `Tools.Registry.register_mcp_tools/0` after all MCP servers initialize.
Registered tools appear with the `mcp_` prefix (e.g., `mcp_my_tool`). They are
visible to the LLM and callable through the same tool execution path as built-in
tools.

To reload after changing `mcp.json` at runtime:

```elixir
OptimalSystemAgent.MCP.Client.start_servers()
OptimalSystemAgent.MCP.Client.list_tools()
OptimalSystemAgent.Tools.Registry.register_mcp_tools()
```

---

## 8. Custom Commands

Slash commands run when a user types `/command-name` in any channel.

### Markdown commands (no-code)

Create `~/.osa/commands/<name>.md`:

```markdown
---
name: deploy
description: Deploy the current branch to staging
---

Run the deployment pipeline:
1. Check git status — abort if there are uncommitted changes (`git status --porcelain`)
2. Run `mix test` — abort on failure
3. Run `./scripts/deploy.sh staging`
4. Report the deployment URL
```

The markdown body becomes additional system context for the agent turn triggered by `/deploy`.

### Elixir commands

```elixir
defmodule MyApp.Commands.Status do
  @behaviour OptimalSystemAgent.Commands.Behaviour

  @impl true
  def name, do: "mystatus"

  @impl true
  def description, do: "Show custom app status"

  @impl true
  def execute(_args, _session_id) do
    status = MyApp.get_status()
    {:ok, "App status: #{status}"}
  end
end

# Register at boot or runtime:
OptimalSystemAgent.Commands.register("mystatus", MyApp.Commands.Status)
```

---

## 9. OS Templates (Machines)

OS templates define pre-configured environment shapes the agent can instantiate or connect to.

**Configuration:** `~/.osa/machines/<name>.json`

```json
{
  "name": "python-ml",
  "description": "Python 3.12 with PyTorch and Jupyter",
  "image": "python:3.12-ml",
  "working_dir": "/workspace",
  "env": {
    "PYTHONPATH": "/workspace/src"
  },
  "resources": {
    "cpu": "2",
    "memory": "8Gi"
  }
}
```

Templates are discovered by the `Machines` GenServer at boot and exposed via `Machines.list/0`
and `Machines.get/1`. The `compute_vm` tool uses templates to provision isolated execution
environments. Templates can be hot-reloaded without restart.

---

## 10. Custom Sidecar Processes

Sidecars are OS-level subprocesses managed by `OptimalSystemAgent.Sidecar.Manager`.
They communicate with the Elixir runtime via stdio or TCP sockets.

The built-in sidecars (`Go.Tokenizer`, `Go.Git`, `Go.Sysmon`, `Python.Supervisor`)
follow this pattern:

1. Implement `OptimalSystemAgent.Sidecar.Behaviour`
2. Register with `Sidecar.Manager` at startup
3. Add to the `Extensions` supervisor with the appropriate config flag

The `Sidecar.CircuitBreaker` automatically disables a sidecar after repeated
failures and re-enables it after a recovery period.

---

## Extension Summary

| Extension Type | Files Modified | Elixir Required | Hot-Reload |
|---|---|---|---|
| Custom tool | `.ex` module | Yes | Yes (`Tools.Registry.register/1`) |
| Custom provider | `.ex` module | Yes | Yes (`Providers.Registry.register_provider/2`) |
| Custom channel | `.ex` module | Yes | Yes (`DynamicSupervisor.start_child/2`) |
| Custom hook | None (runtime register) | Yes | Yes (`Hooks.register/4`) |
| Custom command (markdown) | `~/.osa/commands/*.md` | No | Yes (on next invocation) |
| Custom command (Elixir) | `.ex` module | Yes | Yes (`Commands.register/2`) |
| Custom skill (SKILL.md) | `~/.osa/skills/*/SKILL.md` | No | Yes (`Tools.Registry.reload_skills/0`) |
| MCP server | `~/.osa/mcp.json` | No | Yes (`MCP.Client.start_servers/0`) |
| OS template (Machine) | `~/.osa/machines/*.json` | No | Yes (Machines GenServer) |
| Custom sidecar | `.ex` + binary | Yes | Via Sidecar.Manager restart |
| Custom swarm pattern | `.ex` clause | Yes | Requires recompile |

---

## Cross-References

- Tool behaviour source: `lib/miosa/shims.ex` (`MiosaTools.Behaviour`)
- Provider behaviour source: `lib/optimal_system_agent/providers/behaviour.ex`
- Channel behaviour source: `lib/optimal_system_agent/channels/behaviour.ex`
- Hook registration: `lib/optimal_system_agent/agent/hooks.ex`
- Swarm orchestration: `lib/optimal_system_agent/swarm/orchestrator.ex`
- Dependency rules: [dependency-rules.md](../overview/dependency-rules.md)
- Component model: [component-model.md](component-model.md)
