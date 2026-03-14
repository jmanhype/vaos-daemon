# Extending the Runtime

Audience: developers implementing new tools, skills, channels, or hooks for OSA.

This guide covers the behaviour contracts you must implement and the patterns
that make extensions work correctly in the OTP runtime.

---

## Adding a Tool

A tool is an Elixir module that the LLM can invoke during the ReAct loop. The
LLM sees the tool's name, description, and parameter schema; it generates a
call; `Agent.Loop` executes the call and returns the result.

### Implement the Tools.Behaviour

```elixir
defmodule MyApp.Tools.WeatherTool do
  @moduledoc "Fetches current weather for a location."

  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def name, do: "get_weather"

  @impl true
  def description do
    "Get the current weather conditions and temperature for a city or location."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "location" => %{
          "type" => "string",
          "description" => "City name or address (e.g. 'San Francisco, CA')"
        },
        "units" => %{
          "type" => "string",
          "enum" => ["celsius", "fahrenheit"],
          "description" => "Temperature unit. Default: celsius."
        }
      },
      "required" => ["location"]
    }
  end

  @impl true
  def execute(%{"location" => location} = args) do
    units = Map.get(args, "units", "celsius")
    case fetch_weather(location, units) do
      {:ok, data} ->
        {:ok, format_weather(data)}
      {:error, reason} ->
        {:error, "Could not fetch weather for #{location}: #{reason}"}
    end
  end

  # Private ─────────────────────────────────────────────────────────

  defp fetch_weather(location, _units) do
    # HTTP call to weather API
    {:ok, %{temp: 22, condition: "Sunny", location: location}}
  end

  defp format_weather(%{temp: temp, condition: condition, location: location}) do
    "#{location}: #{condition}, #{temp}°C"
  end
end
```

### Contract

| Callback | Return type | Notes |
|----------|-------------|-------|
| `name/0` | `String.t()` | Unique. Snake_case. No spaces. |
| `description/0` | `String.t()` | Shown to the LLM. Be specific about when to use this tool. |
| `parameters/0` | `map()` | JSON Schema object. Must include `"type": "object"`. |
| `execute/1` | `{:ok, String.t()}` or `{:error, String.t()}` | Receives a `map()` of validated arguments. Return a string the LLM can read. |

The `parameters` map is validated against incoming LLM arguments using
`ex_json_schema`. Invalid arguments are rejected before `execute/1` is called.

### Availability guard (optional)

If your tool requires configuration that may not be present:

```elixir
@impl true
def available? do
  Application.get_env(:my_app, :weather_api_key) != nil
end
```

Implement `available?/0` from `Tools.Behaviour` (defaults to `true`). Tools
where `available?/0` returns `false` are filtered out of the tool list sent
to the LLM.

### Register the tool

```elixir
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.WeatherTool)
```

---

## Adding a Skill

A skill is a prompt-only definition. It does not execute code; it injects
instructions into the agent's reasoning context.

### SKILL.md format

```markdown
---
name: code_review
description: Perform a thorough code review following OSA standards
tools:
  - file_read
  - file_glob
  - web_search
---

# Code Review Skill

You are performing a code review. Apply the following checklist to every file
you examine:

## Correctness
- Logic is correct and handles edge cases
- Error handling is present for all failure modes

## Security
- No hardcoded secrets or credentials
- Input is validated before use
- SQL queries use parameterized statements

## Performance
- No N+1 query patterns
- No unnecessary blocking operations

Report findings grouped by severity: CRITICAL, MAJOR, MINOR.
```

Place the file in `~/.osa/skills/code_review.md`. It is loaded at boot and
on `/reload`.

---

## Adding a Channel

A channel adapter connects an external messaging platform (Telegram, Discord,
Slack, a custom webhook, etc.) to the OSA agent pipeline.

### Implement Channels.Behaviour

```elixir
defmodule MyApp.Channels.MyAdapter do
  @moduledoc "Channel adapter for MyPlatform."

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  # ── Behaviour ────────────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :my_platform

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    token = Keyword.get(opts, :token) ||
      Application.get_env(:optimal_system_agent, :my_platform_token)

    if is_nil(token) do
      Logger.info("[MyAdapter] No token configured — skipping")
      :ignore
    else
      GenServer.start_link(__MODULE__, %{token: token}, name: __MODULE__)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, _opts \\ []) do
    GenServer.call(__MODULE__, {:send, chat_id, message})
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(%{token: token}) do
    Logger.info("[MyAdapter] Connected")
    # Start polling, open WebSocket, or register webhook here
    {:ok, %{token: token}}
  end

  @impl true
  def handle_call({:send, chat_id, message}, _from, state) do
    result = post_message(state.token, chat_id, message)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:inbound, chat_id, user_id, text}, state) do
    # Route inbound message to the agent loop
    session_id = "my_platform:#{chat_id}"
    Loop.process_message(session_id, %{
      content: text,
      user_id: user_id,
      channel: :my_platform,
      chat_id: chat_id
    })
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────

  defp post_message(_token, _chat_id, _message) do
    # HTTP call to platform API
    :ok
  end
end
```

### Contract

| Callback | Notes |
|----------|-------|
| `channel_name/0` | Unique atom. Used for logging and routing. |
| `start_link/1` | Return `:ignore` if required config is absent. Do not crash. |
| `send_message/3` | Called by the agent loop to deliver responses. Must be synchronous. |
| `connected?/0` | Returns `true` if the adapter is ready to send and receive. |

### Start the channel

```elixir
DynamicSupervisor.start_child(
  OptimalSystemAgent.Channels.Supervisor,
  {MyApp.Channels.MyAdapter, token: "my-token"}
)
```

---

## Adding a Hook

Hooks are closures registered against a lifecycle event. They can observe,
transform, or block the payload.

```elixir
alias OptimalSystemAgent.Agent.Hooks

Hooks.register(%{
  name: "rate_limiter",
  event: :pre_tool_use,
  priority: 12,
  handler: fn payload ->
    session_id = payload[:session_id]
    case RateLimiter.check(session_id) do
      :allow  -> {:ok, payload}
      :deny   -> {:block, "Rate limit exceeded for session #{session_id}"}
    end
  end
})
```

For `:post_tool_use` hooks, the return value is ignored by the chain (the
hook runs asynchronously). Use `{:ok, payload}` or `:skip` as the return.

See [Registering Components](./registering-components.md) for priority ranges
and event types.

---

## Related

- [Registering Components](./registering-components.md) — how to register after implementing
- [Integrating a Subsystem](../integration/integrating-a-subsystem.md) — connect to Events.Bus and Memory
