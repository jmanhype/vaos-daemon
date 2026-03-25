defmodule Daemon.Vault.Observer do
  @moduledoc """
  Observation buffer that collects messages and periodically flushes them
  as scored observations to the vault store.

  Subscribes to the Events.Bus for tool results and agent responses,
  classifies them, and stores notable ones as observations.
  """
  use GenServer
  require Logger

  alias Daemon.Vault.{Observation, Store}
  alias Daemon.Events.Bus

  @flush_interval 60_000
  @buffer_limit 50
  @min_score 0.4

  defstruct buffer: [], flush_timer: nil

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a message to the observation buffer."
  @spec observe(String.t(), keyword()) :: :ok
  def observe(content, opts \\ []) do
    GenServer.cast(__MODULE__, {:observe, content, opts})
  end

  @doc "Force flush the buffer immediately."
  @spec flush() :: :ok
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  @doc "Get current buffer size."
  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    GenServer.call(__MODULE__, :buffer_size)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # Subscribe to relevant events
    safe_subscribe()
    timer = Process.send_after(self(), :flush_tick, @flush_interval)
    {:ok, %__MODULE__{flush_timer: timer}}
  end

  @impl true
  def handle_cast({:observe, content, opts}, state) do
    entry = %{content: content, opts: opts, timestamp: DateTime.utc_now()}
    new_buffer = [entry | state.buffer]

    if length(new_buffer) >= @buffer_limit do
      do_flush(new_buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_cast(:flush, state) do
    do_flush(state.buffer)
    {:noreply, %{state | buffer: []}}
  end

  @impl true
  def handle_call(:buffer_size, _from, state) do
    {:reply, length(state.buffer), state}
  end

  @impl true
  def handle_info(:flush_tick, state) do
    do_flush(state.buffer)
    timer = Process.send_after(self(), :flush_tick, @flush_interval)
    {:noreply, %{state | buffer: [], flush_timer: timer}}
  end

  # Handle Bus events
  def handle_info({:bus_event, _topic, %{content: content}}, state) when is_binary(content) do
    handle_cast({:observe, content, []}, state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Flush remaining on shutdown
    if state.buffer != [], do: do_flush(state.buffer)
    :ok
  end

  # --- Private ---

  defp do_flush([]), do: :ok

  defp do_flush(buffer) do
    observations =
      buffer
      |> Enum.map(fn %{content: content, opts: opts} ->
        {score, tags} = Observation.classify(content)

        if score >= @min_score do
          Observation.new(content,
            score: score,
            tags: tags,
            session_id: Keyword.get(opts, :session_id),
            source: Keyword.get(opts, :source)
          )
        end
      end)
      |> Enum.reject(&is_nil/1)

    Enum.each(observations, fn obs ->
      md = Observation.to_markdown(obs)
      Store.write(:observation, obs.id, md)
    end)

    if observations != [] do
      Logger.debug("[vault/observer] Flushed #{length(observations)} observations")
    end
  end

  defp safe_subscribe do
    try do
      Bus.register_handler(:tool_result, fn event ->
        if content = Map.get(event, :content) do
          GenServer.cast(__MODULE__, {:observe, content, []})
        end
      end)
    rescue
      _ -> Logger.debug("[vault/observer] Events.Bus not available for subscription")
    catch
      :exit, _ -> Logger.debug("[vault/observer] Events.Bus not started")
    end
  end
end
