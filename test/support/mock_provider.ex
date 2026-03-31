defmodule Daemon.Test.MockProvider do
  @moduledoc """
  Deterministic LLM provider for E2E tests.

  Returns a canned tool_call on the first invocation per process, then a
  plain-text response on every subsequent call.  State is kept in the
  calling process's dictionary so it is automatically isolated per test
  (each test spawns its own Loop GenServer which has its own dictionary).

  To use:
    1. In setup, call `MockProvider.reset/0` to clear any prior state.
    2. Configure the application to use the :mock provider atom:
         Application.put_env(:daemon, :default_provider, :mock)
    3. Register the module under the :mock atom so the registry resolves it:
         Application.put_env(:daemon, :mock_provider_module, __MODULE__)

  ## Advanced Usage

  Set a custom sequence of responses:

      MockProvider.set_responses([
        {:ok, %{content: "", tool_calls: [%{id: "1", name: "bash", arguments: %{"command" => "ls"}}]}},
        {:ok, %{content: "Done", tool_calls: []}},
        {:error, "API timeout"}
      ])

  Enable call logging:

      MockProvider.reset()
      MockProvider.enable_logging()
      # ... make calls ...
      log = MockProvider.call_log()
  """

  @behaviour MiosaProviders.Behaviour

  # ── Behaviour callbacks ──────────────────────────────────────────────

  @impl true
  def name, do: :mock

  @impl true
  def default_model, do: "mock-model-1.0"

  @impl true
  def available_models, do: ["mock-model-1.0"]

  @doc """
  Synchronous chat.

  First call (per process): returns a tool_call response.
  Subsequent calls: returns a plain-text final answer.

  Can be customized with `set_responses/1`.
  """
  @impl true
  def chat(messages, opts) do
    log_call(:chat, messages, opts)

    case get_next_response() do
      {:ok, response} ->
        {:ok, response}

      {:error, _reason} = error ->
        error

      :default ->
        # Default behavior for backward compatibility
        case Process.get(:mock_provider_call_count, 0) do
          0 ->
            Process.put(:mock_provider_call_count, 1)

            {:ok,
             %{
               content: "",
               tool_calls: [
                 %{
                   id: "call_mock_001",
                   name: "memory_recall",
                   arguments: %{"query" => "smoke test context"}
                 }
               ]
             }}

          _ ->
            Process.put(:mock_provider_call_count, :done)
            {:ok, %{content: "Mock final answer from OSA.", tool_calls: []}}
        end
    end
  end

  @doc """
  Streaming chat — simulates the three-phase callback sequence and then
  invokes `{:done, result}` so the Loop's process-dictionary capture works.

  Can be customized with `set_responses/1`.
  """
  @impl true
  def chat_stream(messages, callback, opts) do
    log_call(:chat_stream, messages, opts)

    case get_next_response() do
      {:ok, response} ->
        callback.({:done, response})
        :ok

      {:error, _reason} = error ->
        # For errors in streaming, we still invoke the callback
        callback.({:error, error})
        error

      :default ->
        # Default behavior for backward compatibility
        case Process.get(:mock_provider_call_count, 0) do
          0 ->
            Process.put(:mock_provider_call_count, 1)
            result = %{content: "", tool_calls: [%{id: "call_mock_001", name: "memory_recall", arguments: %{"query" => "smoke test context"}}]}
            callback.({:done, result})
            :ok

          _ ->
            Process.put(:mock_provider_call_count, :done)
            text = "Mock final answer from OSA."
            callback.({:text_delta, text})
            result = %{content: text, tool_calls: []}
            callback.({:done, result})
            :ok
        end
    end
  end

  # ── Configuration API ───────────────────────────────────────────────────

  @doc """
  Set a list of responses to be returned in sequence.

  Each response should be either:
    - `{:ok, response_map}` where response_map has :content and :tool_calls
    - `{:error, reason_string}` to simulate an error

  Example:
      MockProvider.set_responses([
        {:ok, %{content: "", tool_calls: [%{id: "1", name: "bash", arguments: %{}}]}},
        {:ok, %{content: "Complete", tool_calls: []}}
      ])
  """
  def set_responses(responses) when is_list(responses) do
    Process.put(:mock_responses, responses)
    Process.put(:mock_response_index, 0)
    :ok
  end

  @doc """
  Reset the per-process call counter and custom responses.

  Call this in test setup to ensure a clean state.
  """
  def reset do
    Process.delete(:mock_provider_call_count)
    Process.delete(:mock_responses)
    Process.delete(:mock_response_index)
    Process.delete(:mock_call_log)
    Process.delete(:mock_logging_enabled)
    :ok
  end

  @doc """
  Enable call logging.

  After enabling, all chat/chat_stream calls will be logged.
  Retrieve the log with `call_log/0`.
  """
  def enable_logging do
    Process.put(:mock_logging_enabled, true)
    Process.put(:mock_call_log, [])
    :ok
  end

  @doc """
  Disable call logging.
  """
  def disable_logging do
    Process.delete(:mock_logging_enabled)
    :ok
  end

  @doc """
  Retrieve the call log.

  Returns a list of maps with keys: :type, :messages, :opts, :timestamp.
  Returns `nil` if logging was not enabled.
  """
  def call_log do
    Process.get(:mock_call_log)
  end

  @doc """
  Get the number of calls made since logging was enabled.

  Returns 0 if logging was not enabled.
  """
  def call_count do
    case Process.get(:mock_call_log) do
      nil -> 0
      log when is_list(log) -> length(log)
    end
  end

  # ── Internal helpers ─────────────────────────────────────────────────────

  defp get_next_response do
    case Process.get(:mock_responses) do
      nil -> :default
      [] -> :default
      responses when is_list(responses) ->
        index = Process.get(:mock_response_index, 0)
        if index < length(responses) do
          Process.put(:mock_response_index, index + 1)
          Enum.at(responses, index)
        else
          # Cycle back to the start or fall back to default
          :default
        end
    end
  end

  defp log_call(type, messages, opts) do
    case Process.get(:mock_logging_enabled, false) do
      true ->
        log_entry = %{
          type: type,
          messages: messages,
          opts: opts,
          timestamp: System.monotonic_time(:millisecond)
        }
        current_log = Process.get(:mock_call_log, [])
        Process.put(:mock_call_log, [log_entry | current_log])

      false ->
        :ok
    end
  end
end
