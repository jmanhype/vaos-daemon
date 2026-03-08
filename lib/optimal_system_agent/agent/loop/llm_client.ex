defmodule OptimalSystemAgent.Agent.Loop.LLMClient do
  @moduledoc """
  LLM call abstraction for the agent loop.

  Wraps Providers.chat and Providers.chat_stream with per-session
  provider/model routing, streaming callback setup, and thinking config.
  """
  require Logger

  alias MiosaProviders.Registry, as: Providers
  alias OptimalSystemAgent.Events.Bus

  @doc """
  Synchronous LLM chat — routes through the configured provider/model for this session.
  """
  def llm_chat(%{provider: provider, model: model}, messages, opts) do
    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    Providers.chat(messages, opts)
  end

  @doc """
  Streaming LLM chat — emits per-token SSE events via Bus.
  Returns {:ok, result} | {:error, reason}.

  Uses process dictionary to capture the {:done, result} from the streaming
  callback, since chat_stream/3 returns :ok on success (not the accumulated result).
  """
  def llm_chat_stream(%{session_id: session_id, provider: provider, model: model}, messages, opts) do
    # Stash result from {:done, _} callback into process dictionary
    Process.put(:llm_stream_result, nil)

    callback = fn
      {:text_delta, text} ->
        Logger.debug("[stream] text_delta #{byte_size(text)}B → session:#{session_id}")
        Bus.emit(:system_event, %{
          event: :streaming_token,
          session_id: session_id,
          text: text
        })

      {:done, result} ->
        Logger.info("[stream] done → session:#{session_id}")
        Process.put(:llm_stream_result, result)

      {:thinking_delta, text} ->
        Bus.emit(:system_event, %{
          event: :thinking_delta,
          session_id: session_id,
          text: text
        })

      # Ignore tool_use deltas — these are handled after the full result
      _other ->
        :ok
    end

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts

    case Providers.chat_stream(messages, callback, opts) do
      :ok ->
        case Process.get(:llm_stream_result) do
          nil -> {:error, "Stream completed but no result received"}
          result -> {:ok, result}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Resolve thinking config based on provider, model, and application config."
  def thinking_config(%{provider: provider} = state) do
    enabled = Application.get_env(:optimal_system_agent, :thinking_enabled, false)

    if enabled and provider in [:anthropic, nil] and is_anthropic_provider?() do
      model = state.model || Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")

      if String.contains?(to_string(model), "opus") do
        %{type: "adaptive"}
      else
        budget = Application.get_env(:optimal_system_agent, :thinking_budget_tokens, 5_000)
        %{type: "enabled", budget_tokens: budget}
      end
    else
      nil
    end
  end

  @doc "Returns true when the configured default provider is Anthropic."
  def is_anthropic_provider? do
    default = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    default == :anthropic
  end

  @doc "Returns the configured LLM temperature."
  def temperature, do: Application.get_env(:optimal_system_agent, :temperature, 0.7)
end
