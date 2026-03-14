# Extending OSA Services

How to add new LLM providers, new tools, and new channel adapters. Each follows a
behaviour contract. The system discovers and routes to your implementation automatically.

## Audience

Elixir developers adding integrations to a running OSA instance.

---

## Adding a New LLM Provider

All providers implement `OptimalSystemAgent.Providers.Behaviour`:

```elixir
@callback chat(messages :: list(message()), opts :: keyword()) :: chat_result()
@callback chat_stream(messages :: list(message()), callback :: function(), opts :: keyword()) ::
            :ok | {:error, String.t()}
@callback name() :: atom()
@callback default_model() :: String.t()
@callback available_models() :: list(String.t())  # optional
```

### Option A: OpenAI-Compatible Provider

If your provider speaks the OpenAI `/chat/completions` wire format, add it to
`OpenAICompatProvider` rather than creating a full module. This is how the 13 existing
compat providers (groq, deepseek, mistral, etc.) work.

Add a config entry to `@provider_configs` in
`lib/optimal_system_agent/providers/openai_compat_provider.ex`:

```elixir
my_provider: %{
  default_url: "https://api.myprovider.com/v1",
  default_model: "my-model-v1",
  available_models: ["my-model-v1", "my-model-mini"],
  # Optional: add extra HTTP headers (see :openrouter for example)
  extra_headers: [{"X-Custom-Header", "value"}]
}
```

Then register the atom in `Providers.Registry` in the `@providers` map:

```elixir
my_provider: {:compat, :my_provider},
```

Set the environment variable at runtime:

```
MY_PROVIDER_API_KEY=sk-...
```

OSA reads `Application.get_env(:optimal_system_agent, :my_provider_api_key)` automatically
via the `:"#{provider}_api_key"` pattern in `OpenAICompatProvider.chat/3`.

### Option B: Native Protocol Provider

When the provider has a non-OpenAI wire format (like Anthropic or Google), create a module:

```elixir
defmodule OptimalSystemAgent.Providers.MyProvider do
  @moduledoc "MyProvider native API integration."
  @behaviour OptimalSystemAgent.Providers.Behaviour
  require Logger

  @impl true
  def name, do: :my_provider

  @impl true
  def default_model, do: "my-model-v1"

  @impl true
  def available_models, do: ["my-model-v1", "my-model-mini"]

  @impl true
  def chat(messages, opts) do
    api_key = Application.get_env(:optimal_system_agent, :my_provider_api_key)

    unless api_key do
      {:error, "MY_PROVIDER_API_KEY not configured"}
    else
      model = Keyword.get(opts, :model, default_model())
      body = build_request_body(messages, model, opts)

      case Req.post("https://api.myprovider.com/v1/chat",
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: response}} ->
          {:ok, parse_response(response)}

        {:ok, %{status: 429}} ->
          {:error, {:rate_limited, nil}}

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def chat_stream(messages, callback, opts) do
    # Implement SSE streaming — see openai_compat.ex for a full example.
    # Callback receives: {:text_delta, text} | {:done, result}
    :ok
  end

  defp parse_response(response) do
    # Return the canonical shape:
    %{
      content: get_in(response, ["choices", Access.at(0), "message", "content"]) || "",
      tool_calls: [],
      usage: %{}
    }
  end
end
```

Register in `Providers.Registry`:

```elixir
my_provider: OptimalSystemAgent.Providers.MyProvider,
```

### Registering a Provider at Runtime

For dynamic registration (e.g., in tests or plugins):

```elixir
OptimalSystemAgent.Providers.Registry.register_provider(:my_provider, MyModule)
```

The module must export `chat/2`, `name/0`, and `default_model/0` or registration is rejected.

---

## Adding a New Tool

Tools implement `MiosaTools.Behaviour` (or `OptimalSystemAgent.Tools.Behaviour` in older paths).
The registry discovers tools by name and exposes them to the LLM via function calling.

### Tool Behaviour

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()           # JSON Schema object
@callback execute(arguments :: map()) :: {:ok, String.t()} | {:error, String.t()}
@callback safety() :: :read_only | :read_write | :destructive  # optional
@callback available?() :: boolean()  # optional — gates the tool based on env
```

### Minimal Tool Example

```elixir
defmodule OptimalSystemAgent.Tools.Builtins.MyTool do
  @moduledoc "Brief description for tool registry docs."
  @behaviour MiosaTools.Behaviour

  @impl true
  def name, do: "my_tool"

  @impl true
  def description do
    "One or two sentences explaining what this tool does and when to use it. " <>
    "The LLM uses this description to decide when to call the tool."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The input to process"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of results (default: 10)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)

    case do_work(query, limit) do
      {:ok, results} ->
        # Always return a plain string — the LLM reads this as the tool result.
        formatted = Enum.join(results, "\n")
        {:ok, formatted}

      {:error, reason} ->
        {:error, "my_tool failed: #{reason}"}
    end
  end

  # Optional: return false to hide the tool from the LLM when dependencies are missing.
  @impl true
  def available? do
    System.find_executable("some_binary") != nil
  end

  defp do_work(query, limit) do
    {:ok, ["result 1", "result 2"] |> Enum.take(limit)}
  end
end
```

Register the tool in `Tools.Registry.load_builtin_tools/0` in
`lib/optimal_system_agent/tools/registry.ex`:

```elixir
defp load_builtin_tools do
  %{
    # ... existing tools ...
    "my_tool" => OptimalSystemAgent.Tools.Builtins.MyTool,
  }
end
```

The tool becomes immediately available after the next app start. To register at runtime
without a restart:

```elixir
OptimalSystemAgent.Tools.Registry.register(OptimalSystemAgent.Tools.Builtins.MyTool)
```

### SKILL.md Tools (No Elixir Required)

For prompt-only tools (workflows, not code execution), create a SKILL.md file:

```
~/.osa/skills/my-skill/SKILL.md
```

```markdown
---
name: my_skill
description: Briefly explain what this skill does
triggers:
  - keyword one
  - keyword two
priority: 5
---

## Instructions

When this skill is active, follow these steps:
1. First step
2. Second step
```

OSA loads user skills from `~/.osa/skills/` at boot. Built-in skills live in `priv/skills/`.
Skills trigger by keyword match against the user's message and inject instructions into the
system prompt for that turn.

---

## Adding a New Channel Adapter

Channel adapters implement `OptimalSystemAgent.Channels.Behaviour`:

```elixir
@callback channel_name() :: atom()
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(chat_id :: String.t(), message :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}
@callback connected?() :: boolean()
```

### Minimal Channel Example

The pattern from `Channels.Telegram` and `Channels.Discord` is consistent across all adapters:

```elixir
defmodule OptimalSystemAgent.Channels.MyChannel do
  @moduledoc """
  MyPlatform channel adapter.

  Operates in webhook mode. MyPlatform POSTs updates to:
    POST /api/v1/channels/my_channel/webhook

  Configuration:
    MY_CHANNEL_TOKEN — bot token for authentication
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session

  @api_base "https://api.myplatform.com/v1"
  @send_timeout 10_000

  defstruct [:token, connected: false]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :my_channel

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, chat_id, message, opts}, @send_timeout)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :my_channel_token)

    unless token do
      Logger.info("[MyChannel] MY_CHANNEL_TOKEN not set — adapter inactive")
      :ignore
    else
      Logger.info("[MyChannel] started")
      {:ok, %__MODULE__{token: token, connected: true}}
    end
  end

  @impl true
  def handle_call({:send, chat_id, message, _opts}, _from, state) do
    result = send_to_platform(state.token, chat_id, message)
    {:reply, result, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  # Called by the HTTP router when the platform POSTs a webhook event.
  def handle_webhook(body) do
    # Extract user message and chat ID from platform-specific payload.
    chat_id = body["chat_id"]
    text = body["message"]["text"]
    session_id = "my_channel_#{chat_id}"

    # Start or find existing session.
    Session.ensure_started(session_id, :my_channel)

    # Route the message through the agent loop.
    Loop.process_message(session_id, text)
  end

  defp send_to_platform(token, chat_id, message) do
    case Req.post("#{@api_base}/send",
           json: %{chat_id: chat_id, text: message},
           headers: [{"Authorization", "Bearer #{token}"}]
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Add the adapter to `Channels.Starter` so it starts with the configured channels:

```elixir
# In lib/optimal_system_agent/channels/starter.ex, add to the channel list:
{OptimalSystemAgent.Channels.MyChannel, []}
```

Add a webhook route in `Channels.HTTP` following the pattern of existing channel routes.
