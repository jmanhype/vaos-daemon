# Service Contracts

Audience: developers integrating with OSA or extending it with custom adapters.

This document defines the four primary behaviour contracts OSA uses internally.
Every channel adapter, skill, tool, and LLM provider must satisfy one of these
contracts. The BEAM enforces each `@callback` at compile time when `@behaviour`
is declared.

---

## Channels.Behaviour

**Module:** `OptimalSystemAgent.Channels.Behaviour`
**File:** `lib/optimal_system_agent/channels/behaviour.ex`

A channel adapter bridges an external messaging platform (Telegram, Slack,
Discord, CLI, HTTP, etc.) to the OSA agent loop. Every adapter is a GenServer
that registers under its channel atom and routes inbound messages through
`Agent.Loop.process_message/2`.

### Callbacks

| Callback | Signature | Description |
|---|---|---|
| `channel_name/0` | `() :: atom()` | Unique atom identifier for this channel (e.g. `:telegram`, `:slack`). Used for registration and routing. |
| `start_link/1` | `(opts :: keyword()) :: GenServer.on_start()` | Start the adapter process. Must return a standard GenServer start result. |
| `send_message/3` | `(chat_id :: String.t(), message :: String.t(), opts :: keyword()) :: :ok \| {:error, term()}` | Deliver a message to a user or chat on the platform. `chat_id` is platform-specific. Returns `:ok` or `{:error, reason}`. |
| `connected?/0` | `() :: boolean()` | Report whether the adapter is live and able to send or receive. |

### Implementation Example

```elixir
defmodule MyApp.Channels.WebhookChannel do
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :webhook

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, _opts) do
    case HTTPClient.post("https://hooks.example.com/#{chat_id}", %{text: message}) do
      {:ok, %{status: 200}} -> :ok
      {:error, reason}      -> {:error, reason}
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{config: opts}}
  end
end
```

### Notes

- Inbound messages must be forwarded to `Agent.Loop.process_message(session_id, message)`.
- The `connected?/0` check is used by the health system and channel manager.
- Adapters that require API credentials should check their environment at boot and
  refuse to start (returning `{:error, :missing_config}`) if required vars are absent.

---

## Skills.Behaviour

Skills are SKILL.md markdown files loaded from `~/.osa/skills/` or `priv/skills/`.
The registry parses YAML frontmatter and injects the skill's instructions into
the system prompt when trigger keywords match an incoming message.

### SKILL.md File Format

A skill is a directory under `~/.osa/skills/<name>/` containing a `SKILL.md` file.

```
~/.osa/skills/
└── code-review/
    └── SKILL.md
```

### SKILL.md Structure

```markdown
---
name: code-review
description: Perform a structured code review with OWASP checklist
triggers:
  - review
  - "code review"
  - LGTM
priority: 3
tools:
  - file_read
  - file_grep
---

## Code Review Protocol

When asked to review code:

1. Read the target files with `file_read`.
2. Check for security issues (injection, IDOR, missing auth).
3. Flag performance anti-patterns (N+1, missing indexes).
4. Comment on maintainability and naming clarity.
5. Output a structured review: APPROVED | NEEDS CHANGES | BLOCKED.
```

### Frontmatter Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Skill identifier. Used for lookup and display. |
| `description` | string | yes | One-line description shown in skill listings. |
| `triggers` | list of strings | no | Keywords that activate this skill. Case-insensitive substring match. |
| `priority` | integer or label | no | Lower = higher priority. Labels: `critical`=0, `high`=1, `medium`=3, `low`=7. Default: 5. |
| `tools` | list of strings | no | Hints for which tools this skill typically uses. Informational only. |

### Elixir Module Skills

Skills can also be implemented as Elixir modules. This is the path deps pattern
(via extracted `miosa_*` packages). The module must satisfy the behaviour contract:

```elixir
defmodule MyApp.Skills.DeploymentChecklist do
  @behaviour Skills.Behaviour

  @impl true
  def name, do: "deployment-checklist"

  @impl true
  def description, do: "Step-by-step deployment verification protocol"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "environment" => %{
          "type" => "string",
          "enum" => ["staging", "production"],
          "description" => "Target deployment environment"
        }
      },
      "required" => ["environment"]
    }
  end

  @impl true
  def execute(%{"environment" => env}) do
    checklist = build_checklist(env)
    {:ok, checklist}
  end
end
```

---

## MiosaTools.Behaviour

**Module:** `MiosaTools.Behaviour`
**File:** `lib/miosa/shims.ex`

The tool behaviour contract is the primary extension point. Any module
implementing this behaviour is callable by the LLM as a function.

### Callbacks

| Callback | Signature | Required | Description |
|---|---|---|---|
| `name/0` | `() :: String.t()` | yes | Tool name as the LLM will call it (e.g. `"file_read"`). Must be unique across all registered tools. |
| `description/0` | `() :: String.t()` | yes | One-paragraph description sent to the LLM in the tool schema. Be precise — this determines when the LLM chooses this tool. |
| `parameters/0` | `() :: map()` | yes | JSON Schema object describing accepted parameters. Validated against before `execute/1` is called. |
| `execute/1` | `(params :: map()) :: {:ok, any()} \| {:error, String.t()}` | yes | Run the tool with validated parameters. Must return `{:ok, result}` or `{:error, message}`. |
| `safety/0` | `() :: :read_only \| :write_safe \| :write_destructive \| :terminal` | no (optional) | Safety classification. Drives permission dialogs and YOLO-mode bypass. Defaults to `:write_safe`. |
| `available?/0` | `() :: boolean()` | no (optional) | Runtime availability check. Tools returning `false` are excluded from the LLM schema. Use for tools requiring env vars or external services. |

### Implementation Example

```elixir
defmodule MyApp.Tools.SlackPost do
  @behaviour MiosaTools.Behaviour

  @impl true
  def name, do: "slack_post"

  @impl true
  def description do
    "Post a message to a Slack channel. Use this when the user wants to notify " <>
    "a team or send a status update to Slack."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "channel" => %{
          "type" => "string",
          "description" => "Slack channel name (e.g. #deployments)"
        },
        "message" => %{
          "type" => "string",
          "description" => "Message text to post"
        }
      },
      "required" => ["channel", "message"]
    }
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def available? do
    System.get_env("SLACK_BOT_TOKEN") != nil
  end

  @impl true
  def execute(%{"channel" => channel, "message" => message}) do
    token = System.get_env("SLACK_BOT_TOKEN")
    case Slack.API.chat_postMessage(token, channel, message) do
      {:ok, _}         -> {:ok, "Message posted to #{channel}"}
      {:error, reason} -> {:error, "Slack error: #{reason}"}
    end
  end
end
```

### Registering a Custom Tool

```elixir
# At application start or after boot:
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.SlackPost)
```

The registry recompiles the goldrush dispatcher automatically — the new tool
is available to the LLM within the same BEAM session without a restart.

---

## Providers.Behaviour

**Module:** `OptimalSystemAgent.Providers.Behaviour`
**File:** `lib/optimal_system_agent/providers/behaviour.ex`

Every LLM provider implements this contract. The provider is responsible for
translating OSA's canonical message format into provider-specific API calls and
parsing responses back into the canonical shape.

### Canonical Types

```elixir
@type message :: %{role: String.t(), content: String.t()}

@type tool_call :: %{
  id:        String.t(),
  name:      String.t(),
  arguments: map()
}

@type chat_result ::
  {:ok, %{content: String.t(), tool_calls: list(tool_call())}}
  | {:error, String.t()}
```

### Callbacks

| Callback | Arity | Required | Description |
|---|---|---|---|
| `chat/2` | `(messages, opts)` | yes | Synchronous chat completion. Returns `{:ok, %{content, tool_calls}}`. |
| `chat_stream/3` | `(messages, callback, opts)` | optional | Streaming chat completion. Calls `callback` with delta tuples (see below). |
| `name/0` | `()` | yes | Canonical atom for this provider (e.g. `:anthropic`, `:groq`). |
| `default_model/0` | `()` | yes | Default model string (e.g. `"claude-opus-4-5"`). |
| `available_models/0` | `()` | optional | List of all supported model strings. |

### Streaming Callback Contract

The `callback` function passed to `chat_stream/3` receives one of four tuples:

| Tuple | Description |
|---|---|
| `{:text_delta, text}` | Incremental text content chunk. Append to build the final response. |
| `{:tool_use_start, %{id: String.t(), name: String.t()}}` | A tool call is beginning. Buffer subsequent deltas under this `id`. |
| `{:tool_use_delta, json_chunk}` | Incremental JSON for a tool call's `arguments`. Concatenate per-`id`. |
| `{:done, %{content: String.t(), tool_calls: list(tool_call())}}` | Stream complete. Full assembled result. |

### Implementation Example

```elixir
defmodule MyApp.Providers.Bedrock do
  @behaviour OptimalSystemAgent.Providers.Behaviour

  @impl true
  def name, do: :bedrock

  @impl true
  def default_model, do: "anthropic.claude-opus-4-5-20251101-v1:0"

  @impl true
  def available_models do
    ["anthropic.claude-3-5-haiku-20241022-v1:0",
     "anthropic.claude-opus-4-5-20251101-v1:0"]
  end

  @impl true
  def chat(messages, opts) do
    model = Keyword.get(opts, :model, default_model())
    body  = format_request(messages, model, opts)

    case Bedrock.invoke_model(model, body) do
      {:ok, response}  -> {:ok, parse_response(response)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl true
  def chat_stream(messages, callback, opts) do
    model = Keyword.get(opts, :model, default_model())
    body  = format_request(messages, model, opts)

    Bedrock.invoke_model_stream(model, body, fn chunk ->
      delta = parse_chunk(chunk)
      callback.(delta)
    end)
  end

  # ... private helpers
end
```

### Registering a Custom Provider

```elixir
OptimalSystemAgent.Providers.Registry.register_provider(:bedrock, MyApp.Providers.Bedrock)
```

---

## Summary

| Contract | Module | Extension Point |
|---|---|---|
| `Channels.Behaviour` | `OptimalSystemAgent.Channels.Behaviour` | Messaging platform adapters |
| Skills (SKILL.md) | `Tools.Registry` parser | Custom workflows via markdown |
| `MiosaTools.Behaviour` | `MiosaTools.Behaviour` | Custom callable tools |
| `Providers.Behaviour` | `OptimalSystemAgent.Providers.Behaviour` | LLM provider integrations |
