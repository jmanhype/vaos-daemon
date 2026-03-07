defmodule OptimalSystemAgent.Tools.Behaviour do
  @moduledoc """
  Behaviour for implementing agent tools.

  Every tool implements four callbacks:
  - `name/0` — unique tool name (string)
  - `description/0` — human-readable description for the LLM
  - `parameters/0` — JSON Schema for tool arguments
  - `execute/1` — runs the tool with validated arguments

  ## Example

      defmodule MyApp.Tools.WordCount do
        @behaviour OptimalSystemAgent.Tools.Behaviour

        @impl true
        def name, do: "word_count"

        @impl true
        def description, do: "Count words in a text string"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "text" => %{"type" => "string", "description" => "Text to count words in"}
            },
            "required" => ["text"]
          }
        end

        @impl true
        def execute(%{"text" => text}) do
          count = text |> String.split(~r/\s+/, trim: true) |> length()
          {:ok, "\#{count} words"}
        end
      end

  > **Security:** NEVER use `Code.eval_string/1` on user-supplied input in tools.
  > All arguments arrive from untrusted sources (LLM output or user messages).

  Register at runtime — goldrush recompiles the dispatcher automatically:

      OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.WordCount)

  ## Hot Code Reload

  Because goldrush recompiles the tool dispatcher module on every `register/1`
  call, new tools become available immediately without restarting the BEAM VM.
  """

  @typedoc """
  Tool safety classification.

  - `:read_only`         — no side effects (file reads, searches, queries)
  - `:write_safe`        — creates/modifies files in user workspace
  - `:write_destructive` — irreversible mutations (git push, delete, reset)
  - `:terminal`          — arbitrary shell execution, highest risk
  """
  @type tool_safety :: :read_only | :write_safe | :write_destructive | :terminal

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Optional callback — return false to hide this tool from the LLM tool list.

  Use for tools that depend on external config (API keys, feature flags).
  When not implemented, the tool is always available.
  """
  @callback available?() :: boolean()

  @doc """
  Optional callback — classify the tool's side-effect risk level.

  Used by the dispatch pipeline to enforce safety policies (e.g., requiring
  confirmation for destructive tools). Defaults to `:write_safe` when not
  implemented.
  """
  @callback safety() :: tool_safety()

  @optional_callbacks [available?: 0, safety: 0]
end
