defmodule OptimalSystemAgent.Agent.Directive do
  @moduledoc """
  Typed directives for agent returns.

  Instead of returning raw strings, agents can return structured directives
  that the runtime (Loop) interprets. This separates agent intent from
  runtime execution — the agent says WHAT it wants, the runtime decides HOW.

  ## Directive Types

  - `Emit` — produce output (text, data, signal)
  - `Spawn` — request spawning a sub-agent
  - `Schedule` — schedule a future action
  - `Stop` — terminate the current agent
  - `Delegate` — hand off to another agent
  - `Batch` — multiple directives in sequence
  """

  @type t ::
          {:emit, emit_opts()}
          | {:spawn, spawn_opts()}
          | {:schedule, schedule_opts()}
          | {:stop, stop_opts()}
          | {:delegate, delegate_opts()}
          | {:batch, [t()]}

  @type emit_opts :: %{
          content: String.t(),
          signal_mode: atom() | nil,
          signal_genre: atom() | nil,
          channel: atom() | nil
        }

  @type spawn_opts :: %{
          agent: atom() | String.t(),
          task: String.t(),
          opts: keyword()
        }

  @type schedule_opts :: %{
          action: String.t(),
          delay_ms: non_neg_integer() | nil,
          cron: String.t() | nil
        }

  @type stop_opts :: %{
          reason: atom(),
          message: String.t() | nil
        }

  @type delegate_opts :: %{
          to: atom() | String.t(),
          message: String.t(),
          context: map()
        }

  # Constructors

  @doc "Create an emit directive (produce output)."
  def emit(content, opts \\ %{}) when is_binary(content) do
    {:emit, Map.merge(%{content: content, signal_mode: nil, signal_genre: nil, channel: nil}, opts)}
  end

  @doc "Create a spawn directive (request sub-agent)."
  def spawn(agent, task, opts \\ []) do
    {:spawn, %{agent: agent, task: task, opts: opts}}
  end

  @doc "Create a schedule directive (future action)."
  def schedule(action, opts \\ %{}) when is_binary(action) do
    {:schedule, Map.merge(%{action: action, delay_ms: nil, cron: nil}, opts)}
  end

  @doc "Create a stop directive."
  def stop(reason \\ :normal, message \\ nil) do
    {:stop, %{reason: reason, message: message}}
  end

  @doc "Create a delegate directive (hand off to another agent)."
  def delegate(to, message, context \\ %{}) do
    {:delegate, %{to: to, message: message, context: context}}
  end

  @doc "Create a batch of directives."
  def batch(directives) when is_list(directives) do
    {:batch, directives}
  end

  # Interpretation

  @doc """
  Extract the text content from a directive for backward compatibility.
  Used by channels that only understand strings.
  """
  def to_text({:emit, %{content: content}}), do: content
  def to_text({:stop, %{message: msg}}) when is_binary(msg), do: msg
  def to_text({:stop, _}), do: "Agent stopped."
  def to_text({:delegate, %{message: msg}}), do: "Delegating: #{msg}"
  def to_text({:spawn, %{agent: agent, task: task}}), do: "Spawning #{agent}: #{task}"
  def to_text({:schedule, %{action: action}}), do: "Scheduled: #{action}"
  def to_text({:batch, directives}), do: directives |> Enum.map(&to_text/1) |> Enum.join("\n")
  def to_text(text) when is_binary(text), do: text

  @doc "Check if a value is a valid directive."
  def directive?({tag, _}) when tag in [:emit, :spawn, :schedule, :stop, :delegate, :batch],
    do: true

  def directive?(_), do: false

  @doc """
  Wrap a raw string as an emit directive.
  Provides backward compatibility — existing code that returns strings
  can be gradually migrated to use directives.
  """
  def wrap(text) when is_binary(text), do: emit(text)
  def wrap({_, _} = directive), do: directive
end
