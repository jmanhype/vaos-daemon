# Extension Interfaces

Audience: developers who want to extend OSA with custom tools, skills, channels,
hooks, commands, or MCP servers without modifying OSA's core code.

All extension mechanisms are hot-reloadable or file-drop — no recompilation or
restart required for most extension types.

---

## Custom Tools

A custom tool makes a capability available to the LLM as a callable function.
Tools are the primary way to give the agent access to external services, APIs,
or system operations.

### Step 1: Implement the Behaviour

```elixir
defmodule MyApp.Tools.PagerDutyAlert do
  @behaviour MiosaTools.Behaviour

  @impl true
  def name, do: "pagerduty_alert"

  @impl true
  def description do
    "Trigger a PagerDuty incident alert. Use this when a critical system " <>
    "failure requires immediate on-call notification."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type"        => "string",
          "description" => "Short incident title (max 255 chars)"
        },
        "severity" => %{
          "type"        => "string",
          "enum"        => ["critical", "error", "warning", "info"],
          "description" => "Incident severity level"
        },
        "details" => %{
          "type"        => "string",
          "description" => "Additional context for the responder"
        }
      },
      "required" => ["title", "severity"]
    }
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def available? do
    System.get_env("PAGERDUTY_ROUTING_KEY") != nil
  end

  @impl true
  def execute(%{"title" => title, "severity" => severity} = params) do
    key     = System.get_env("PAGERDUTY_ROUTING_KEY")
    details = Map.get(params, "details", "")

    body = %{
      routing_key: key,
      event_action: "trigger",
      payload: %{
        summary:  title,
        severity: severity,
        source:   "osa-agent",
        custom_details: %{details: details}
      }
    }

    case HTTPoison.post("https://events.pagerduty.com/v2/enqueue",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}]) do
      {:ok, %{status_code: 202}} ->
        {:ok, "Incident created: #{title}"}
      {:ok, %{status_code: code, body: body}} ->
        {:error, "PagerDuty error #{code}: #{body}"}
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end
end
```

### Step 2: Register the Tool

Register at application start or after boot. The tool is immediately available
to all active sessions:

```elixir
# In your application.ex or an initializer:
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.PagerDutyAlert)
```

### Safety Levels

| Level | Description | Triggers permission dialog |
|---|---|---|
| `:read_only` | Does not modify state (file reads, API GETs) | No |
| `:write_safe` | Modifiable but reversible (API POSTs, file writes) | In standard mode |
| `:write_destructive` | Irreversible changes (deletions, database drops) | Always |
| `:terminal` | Shell execution | Always |

In YOLO mode, permission dialogs are bypassed for all safety levels.
See [security/permission-model.md](../security/permission-model.md).

---

## Custom Skills

Skills are higher-level workflows expressed as markdown. The agent injects
the skill's instructions into the system prompt when a user message matches
the skill's trigger keywords.

### Directory Structure

```
~/.osa/skills/
└── incident-response/
    └── SKILL.md
```

### SKILL.md Format

```markdown
---
name: incident-response
description: Structured incident response workflow with timeline and RCA template
triggers:
  - incident
  - outage
  - "production down"
  - p0
  - p1
priority: 1
tools:
  - shell_execute
  - web_fetch
  - memory_save
---

## Incident Response Protocol

When an incident is declared, follow this workflow:

### 1. Acknowledge
- Confirm the incident is real (not a false alarm).
- Record the start time.
- Use `memory_save` to log: "Incident started: <description> at <time>".

### 2. Assess
- Run `shell_execute` with `kubectl get pods --all-namespaces | grep -v Running`
  to identify unhealthy workloads.
- Check recent deployments: `kubectl rollout history deployment/<app>`.

### 3. Communicate
- Draft a status update in plain language: what is affected, what is known,
  what action is being taken, next update time.

### 4. Resolve
- If cause is identified, apply fix and confirm with health checks.
- If cause unknown, roll back the last deployment.

### 5. Post-mortem
- Record timeline, root cause, impact, and remediation in a markdown file
  at `~/incidents/<date>-<title>.md`.
```

### Trigger Matching

Triggers are case-insensitive substring matches against the incoming message.
Multi-word triggers should be quoted in YAML. The wildcard `"*"` is supported
but avoided — it injects the skill on every message.

Skills are disabled (not deleted) by creating a `.disabled` file in the skill
directory: `~/.osa/skills/incident-response/.disabled`.

### Reloading Skills

```elixir
OptimalSystemAgent.Tools.Registry.reload_skills()
```

Or from the CLI:

```
/reload-skills
```

---

## Custom Channels

A channel adapter integrates a new messaging platform.

### Implement the Behaviour

```elixir
defmodule MyApp.Channels.MattermostChannel do
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :mattermost

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, _opts) do
    token    = Application.get_env(:my_app, :mattermost_token)
    base_url = Application.get_env(:my_app, :mattermost_url)

    body = Jason.encode!(%{channel_id: chat_id, message: message})
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post("#{base_url}/api/v4/posts", body, headers) do
      {:ok, %{status_code: 201}} -> :ok
      {:error, reason}           -> {:error, reason}
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    token = Application.get_env(:my_app, :mattermost_token)
    if is_nil(token) do
      Logger.warning("MattermostChannel: MATTERMOST_TOKEN not set, channel inactive")
      {:ok, %{active: false}}
    else
      schedule_poll()
      {:ok, %{active: true, opts: opts}}
    end
  end

  @impl true
  def handle_info(:poll, %{active: true} = state) do
    # Poll for new messages and forward to agent loop
    messages = Mattermost.get_new_messages()
    Enum.each(messages, fn msg ->
      session_id = "mattermost-#{msg.channel_id}"
      OptimalSystemAgent.Agent.Loop.process_message(session_id, msg.text)
    end)
    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, 5_000)
end
```

### Register the Channel

Add to your application supervisor or call at runtime:

```elixir
{MyApp.Channels.MattermostChannel, []}
```

---

## Custom Hooks

Hooks are middleware that run before and after tool calls. They can inspect,
modify, or block actions in the agent loop.

### Hook Events

| Event | When it fires | Can block |
|---|---|---|
| `:pre_tool_use` | Before a tool is called | Yes |
| `:post_tool_use` | After a tool returns | No |
| `:pre_compact` | Before context compaction | No |
| `:session_start` | When a new session initialises | No |
| `:session_end` | When a session terminates | No |
| `:pre_response` | Before the final response is sent | No |
| `:post_response` | After the final response is sent | No |

### Register a Hook

```elixir
OptimalSystemAgent.Agent.Hooks.register(
  :pre_tool_use,
  "audit-log",
  fn payload ->
    AuditLog.record(%{
      session_id: payload.session_id,
      tool:       payload.tool_name,
      args:       payload.arguments,
      timestamp:  DateTime.utc_now()
    })
    {:ok, payload}  # continue
  end,
  priority: 30
)
```

### Hook Return Values

```elixir
{:ok, payload}        # Continue with (possibly modified) payload
{:block, "reason"}    # Block the tool call; returns error to LLM
:skip                 # Skip this hook; pass payload unchanged
```

### Priority and Execution Order

Built-in hooks and their priorities:

| Hook | Event | Priority | Purpose |
|---|---|---|---|
| `security_check` | `:pre_tool_use` | 10 | Block dangerous shell commands |
| `spend_guard` | `:pre_tool_use` | 8 | Block when budget exceeded |
| `mcp_cache` | `:pre_tool_use` | 15 | Inject cached MCP schemas |
| `cost_tracker` | `:post_tool_use` | 25 | Record actual API spend |
| `mcp_cache_post` | `:post_tool_use` | 15 | Populate MCP schema cache |
| `telemetry` | `:post_tool_use` | 90 | Emit tool timing telemetry |

Custom hooks should use priorities above 30 (after built-in security checks)
unless there is a deliberate reason to run before them.

---

## Custom Commands

Commands are slash-command shortcuts available in the CLI and desktop app.
They are markdown files with YAML frontmatter in `~/.osa/commands/`.

### Command File Format

```
~/.osa/commands/
└── standup.md
```

```markdown
---
name: standup
description: Generate today's standup update from recent git activity
aliases:
  - daily
  - morning
arguments:
  - name: project
    description: Project name filter (optional)
    required: false
---

Review the git log from the past 24 hours for the {{project}} project.
Summarise completed work, in-progress items, and any blockers.
Format as a concise standup update.

Use `git log --since="24 hours ago" --oneline` to get the activity.
```

### Frontmatter Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Command name (invoked as `/name`). |
| `description` | string | Shown in `/help` listings. |
| `aliases` | list of strings | Alternative invocation names. |
| `arguments` | list of objects | Named template variables (`{{name}}`). |

### Invoking a Command

```
/standup
/standup project=my-service
/daily
```

The command center substitutes template variables and sends the rendered prompt
to the agent loop as a user message.

---

## MCP Servers

OSA integrates with Model Context Protocol (MCP) servers. MCP tools are
auto-discovered and registered with the prefix `mcp_`.

### Configuration File

```json
// ~/.osa/mcp.json
{
  "servers": [
    {
      "name": "filesystem",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"],
      "env": {}
    },
    {
      "name": "github",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    {
      "name": "postgres",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"],
      "env": {
        "POSTGRES_CONNECTION_STRING": "postgresql://localhost/mydb"
      }
    }
  ]
}
```

### Discovery and Prefixing

At startup, `Tools.Registry.register_mcp_tools/0` calls each server's
`tools/list` endpoint and registers the results. A tool named `read_file`
from the `filesystem` server becomes `mcp_read_file` in the LLM schema.

If two MCP servers expose a tool with the same name, the last registered
server wins. Use distinct server-level tool naming to avoid conflicts.

### Reloading MCP Tools

```elixir
OptimalSystemAgent.Tools.Registry.register_mcp_tools()
```

### Environment Variable Interpolation

Values of the form `${VAR_NAME}` in the `env` map are resolved from the
process environment at startup. Secrets are never written to disk — the
config file holds only the variable reference, not the value.
