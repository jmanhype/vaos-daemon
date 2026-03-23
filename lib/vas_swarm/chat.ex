defmodule VAS.Swarm.Chat do
  @moduledoc """
  GenServer for managing VAS chat sessions.

  Each chat session maintains conversation history and handles
  streaming responses from VAS models.
  """

  use GenServer
  require Logger

  @timeout 30_000

  defstruct [
    :id,
    :model,
    :messages,
    :temperature,
    :max_tokens,
    :retry_attempts,
    :retry_delay,
    :status
  ]

  #
  # Client API
  #

  @doc """
  Starts a new chat session.
  """
  def start_link(opts) do
    {init_opts, gen_opts} = Keyword.split(opts, [:id, :model, :temperature, :max_tokens, :retry_attempts, :retry_delay])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Sends a message to the chat session.
  """
  def send_message(chat_pid, message) when is_pid(chat_pid) do
    GenServer.call(chat_pid, {:send_message, message}, @timeout)
  end

  @doc """
  Streams a message response.
  """
  def stream_message(chat_pid, message) when is_pid(chat_pid) do
    GenServer.call(chat_pid, {:stream_message, message}, @timeout)
  end

  @doc """
  Gets the current chat history.
  """
  def get_history(chat_pid) when is_pid(chat_pid) do
    GenServer.call(chat_pid, :get_history)
  end

  @doc """
  Resets the chat session.
  """
  def reset(chat_pid) when is_pid(chat_pid) do
    GenServer.call(chat_pid, :reset)
  end

  @doc """
  Stops the chat session.
  """
  def stop(chat_pid) when is_pid(chat_pid) do
    GenServer.stop(chat_pid, :normal)
  end

  #
  # Server Callbacks
  #

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, generate_id())
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    retry_attempts = Keyword.get(opts, :retry_attempts, 3)
    retry_delay = Keyword.get(opts, :retry_delay, 1000)

    state = %__MODULE__{
      id: id,
      model: model,
      messages: [],
      temperature: temperature,
      max_tokens: max_tokens,
      retry_attempts: retry_attempts,
      retry_delay: retry_delay,
      status: :ready
    }

    Logger.info("Chat session started: #{id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, state) do
    Logger.debug("Sending message to chat #{state.id}: #{String.slice(message, 0, 50)}...")

    # Add user message to history
    updated_messages = state.messages ++ [%{role: "user", content: message}]

    # Simulate VAS API call
    case call_vas_api(state.model, updated_messages, state.temperature, state.max_tokens) do
      {:ok, response} ->
        # Add assistant response to history
        new_messages = updated_messages ++ [%{role: "assistant", content: response}]
        new_state = %{state | messages: new_messages, status: :ready}

        {:reply, {:ok, response}, new_state}

      {:error, reason} ->
        Logger.error("VAS API error: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stream_message, message}, _from, state) do
    Logger.debug("Streaming message to chat #{state.id}")

    # Add user message to history
    updated_messages = state.messages ++ [%{role: "user", content: message}]

    # Simulate streaming (in real implementation, this would stream from VAS API)
    case stream_vas_api(state.model, updated_messages, state.temperature, state.max_tokens) do
      {:ok, response_stream} ->
        # Add assistant response to history
        new_messages = updated_messages ++ [%{role: "assistant", content: response_stream}]
        new_state = %{state | messages: new_messages, status: :ready}

        {:reply, {:ok, response_stream}, new_state}

      {:error, reason} ->
        Logger.error("VAS API stream error: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    Logger.info("Resetting chat #{state.id}")
    new_state = %{state | messages: [], status: :ready}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("Chat #{state.id} timed out")
    {:noreply, state}
  end

  #
  # Private Functions
  #

  defp generate_id do
    "chat_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp call_vas_api(model, messages, temperature, max_tokens) do
    # In real implementation, this would make an HTTP call to VAS API
    # For now, return a mock response
    mock_response = """
    This is a mock response from #{model}.
    Temperature: #{temperature}
    Max Tokens: #{max_tokens}
    Messages: #{length(messages)}
    """

    {:ok, mock_response}
  end

  defp stream_vas_api(model, messages, temperature, max_tokens) do
    # In real implementation, this would stream from VAS API
    mock_response = "Streaming response from #{model}..."
    {:ok, mock_response}
  end
end
