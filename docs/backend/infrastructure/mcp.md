# Infrastructure: MCP (Model Context Protocol)

OSA integrates with external MCP servers — tools, data sources, and services exposed over stdio JSON-RPC — through a two-module client stack: `MCP.Client` (orchestrator) and `MCP.Server` (per-process GenServer).

---

## Architecture

```
~/.osa/mcp.json
    |
MCP.Client.start_servers/0
    |-> DynamicSupervisor (OptimalSystemAgent.MCP.Supervisor)
          |-> MCP.Server "filesystem"   -- Port (npx stdio)
          |-> MCP.Server "github"       -- Port (npx stdio)
          |-> MCP.Server "custom-tool"  -- Port (any executable)

MCP.Client.call_tool/2
    |-> find_server_for_tool/1
    |-> MCP.Server.call_tool/3  -- JSON-RPC tools/call
```

Each MCP server process manages one external subprocess via an Erlang `Port`. All communication uses newline-terminated JSON-RPC over stdio.

---

## Configuration

Configuration lives at `~/.osa/mcp.json` (path configurable via `:mcp_config_path` app env):

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"],
      "allowed_tools": ["read_file", "write_file", "list_directory"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

### Config fields

| Field | Required | Description |
|-------|----------|-------------|
| `command` | Yes | Executable to spawn (resolved via `System.find_executable/1`) |
| `args` | No | List of string arguments |
| `env` | No | Map of environment variable overrides; `${VAR}` is interpolated from the host environment |
| `allowed_tools` | No | Tool name allowlist; omit to expose all tools from the server |

Environment variable interpolation uses the pattern `${VAR_NAME}`. Unknown variables log a warning and expand to `""`.

---

## MCP.Client

`MCP.Client` is a pure module (no GenServer) that orchestrates the `MCP.Supervisor` dynamic supervisor.

### API

```elixir
# Load and start all configured servers
MCP.Client.start_servers()
# => :ok

# Aggregate tools from all running servers
tools = MCP.Client.list_tools()
# => [%{name: "read_file", description: "...", input_schema: %{...}, server: "filesystem"}, ...]

# Route a tool call to the owning server
{:ok, result} = MCP.Client.call_tool("read_file", %{"path" => "/etc/hosts"})
# => {:error, "No MCP server found for tool: unknown_tool"}

# Gracefully terminate all running servers
MCP.Client.stop_servers()
# => :ok
```

`list_tools/0` tags each tool map with a `:server` key identifying which server owns it.

`call_tool/2` searches running servers for a tool matching `tool_name`, then delegates to `MCP.Server.call_tool/3`. Returns `{:error, "No MCP server found for tool: ..."}` when no server owns the tool.

Servers are registered via `OptimalSystemAgent.MCP.Registry` (a standard `Registry`). `start_servers/0` skips servers that fail to start — one broken config does not prevent the others from loading.

---

## MCP.Server

`MCP.Server` is a `GenServer` that owns a single external subprocess and manages the full MCP protocol handshake.

### Lifecycle

```
init/1
  |-> open Port (spawn_executable, :binary, :exit_status, {:line, 1_048_576})
  |-> {:continue, :initialize}

handle_continue(:initialize)
  |-> send JSON-RPC initialize request (protocol version "2024-11-05")
  |-> await_response (10s timeout)
  |-> send notifications/initialized
  |-> send tools/list
  |-> await_response (10s timeout)
  |-> parse and store tool list
  |-> log ready + tool count
```

Tool discovery happens synchronously during `handle_continue` before the GenServer enters its message loop. Init timeout is 10 seconds; tool call timeout is 30 seconds.

### State

```elixir
%MCP.Server{
  name: "github",           # server identifier
  port: #Port<...>,         # Erlang Port to subprocess
  tools: [...],             # list of %{name, description, input_schema}
  allowed_tools: nil,       # nil = all tools; list = filter
  next_id: 42,              # monotonic request ID counter
  pending: %{},             # %{id => {from, timer_ref}}
  buffer: ""                # partial line accumulation
}
```

### Call handling

Calls to `call_tool/3` go through two security gates before the JSON-RPC request is sent:

1. **Allowlist check** — the tool must be in `allowed_tools` (or allowlist must be nil).
2. **Input schema validation** — arguments are validated against the tool's `inputSchema` before dispatch (type, required fields, string length constraints).

Blocked or invalid calls return an error immediately without sending any message to the subprocess.

Accepted calls:
- Assign a monotonic integer request ID.
- Send `tools/call` JSON-RPC request.
- Store `{from, timer_ref}` in `pending` keyed by request ID.
- Return `{:noreply, state}` — the caller is blocked until the response arrives.

Responses arrive as Port data events. `handle_line/2` parses the JSON-RPC response and calls `GenServer.reply/2` to the waiting caller, cancelling the timeout timer.

On Port exit: all pending callers receive `{:error, "MCP server exited (<code>)"}` and the GenServer stops. The `DynamicSupervisor` restart policy governs whether it restarts.

### Timeout handling

Each pending call has a `Process.send_after` timer. On `{:timeout, id}`:
- The waiting caller receives `{:error, "MCP tool call timed out"}`.
- The pending entry is removed.

If the response arrives after the timeout (race), the late response is discarded (pending entry already removed).

---

## Security

### Argument redaction

When logging the command line at server start, arguments following `--token`, `--key`, `--secret`, `--password`, `--api-key`, and `--apikey` are replaced with `[REDACTED]`.

### Input schema validation

Lightweight JSON Schema validation is run before every tool call:
- Type checking: `string`, `number`, `integer`, `boolean`, `array`, `object`, `null`
- Required field presence
- Property-level type checking
- String `maxLength` / `minLength` constraints

### Audit logging

Every tool call attempt emits a structured audit log entry at `:info` level:

```elixir
%{
  timestamp: "2026-03-08T10:00:00Z",
  server: "github",
  tool: "search_repositories",
  args_hash: "a3f4...",   # SHA-256 of :erlang.term_to_binary(arguments)
  status: :calling | :blocked | :rejected,
  reason: "..."           # present on blocked/rejected
}
```

Arguments are hashed rather than logged to prevent secret leakage.

### Log injection prevention

Tool names and reason strings passed to the audit log are sanitized: control characters (`\r`, `\n`, `\t`) are replaced with spaces, and the value is truncated to 128 characters.

---

## Supervision

```
OptimalSystemAgent.MCP.Supervisor  (DynamicSupervisor)
  |-> MCP.Server "filesystem"
  |-> MCP.Server "github"
  ...

OptimalSystemAgent.MCP.Registry  (Registry, keys: :unique)
```

Servers register under `{:via, Registry, {OptimalSystemAgent.MCP.Registry, name}}`.

---

## See Also

- [security.md](security.md) — Shell policy used by sandboxes and schedulers
- [../events/bus.md](../events/bus.md) — Event bus used for tool result events
