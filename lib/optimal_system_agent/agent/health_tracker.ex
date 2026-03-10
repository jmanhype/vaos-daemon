defmodule OptimalSystemAgent.Agent.HealthTracker do
  @moduledoc """
  Per-agent health tracking backed by ETS.

  Subscribes to the `"osa:events"` PubSub firehose and records:
    - `last_active`      — unix timestamp of the most recent call
    - `total_calls`      — number of `:llm_response` / `:agent_response` events
    - `error_count`      — number of `:tool_error` events attributed to the agent
    - `total_latency_ms` — sum of `duration_ms` across all calls (for avg)

  ## Public API

      HealthTracker.get("orchestrator")   # {:ok, health_map} | {:error, :not_found}
      HealthTracker.all()                 # [health_map, ...]
      HealthTracker.record_call("orchestrator", 420)
      HealthTracker.record_error("orchestrator")
  """
  use GenServer
  require Logger

  @table :osa_agent_health

  @call_event_types ~w(llm_response agent_response agent_message)a
  @error_event_types ~w(tool_error agent_error)a

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Return health info for a named agent."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(agent_name) do
    case :ets.lookup(@table, agent_name) do
      [] -> {:error, :not_found}
      [{_, entry}] -> {:ok, build_health(agent_name, entry)}
    end
  end

  @doc "Return health info for every tracked agent."
  @spec all() :: [map()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {name, entry} -> build_health(name, entry) end)
    |> Enum.sort_by(& &1.agent)
  end

  @doc "Record a successful call with an optional duration."
  @spec record_call(String.t(), number() | nil) :: :ok
  def record_call(agent_name, duration_ms \\ nil) do
    now = System.os_time(:second)

    default = %{total_calls: 0, error_count: 0, total_latency_ms: 0, last_active: now}

    entry =
      case :ets.lookup(@table, agent_name) do
        [] -> default
        [{_, e}] -> e
      end

    updated =
      entry
      |> Map.update!(:total_calls, &(&1 + 1))
      |> Map.put(:last_active, now)
      |> then(fn e ->
        if is_number(duration_ms),
          do: Map.update!(e, :total_latency_ms, &(&1 + duration_ms)),
          else: e
      end)

    :ets.insert(@table, {agent_name, updated})
    :ok
  end

  @doc "Record an error event for a named agent."
  @spec record_error(String.t()) :: :ok
  def record_error(agent_name) do
    now = System.os_time(:second)

    default = %{total_calls: 0, error_count: 0, total_latency_ms: 0, last_active: now}

    entry =
      case :ets.lookup(@table, agent_name) do
        [] -> default
        [{_, e}] -> e
      end

    :ets.insert(@table, {agent_name, Map.update!(entry, :error_count, &(&1 + 1))})
    :ok
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:events")
    Logger.debug("[Agent.HealthTracker] started")
    {:ok, :no_state}
  end

  @impl true
  def handle_info({:osa_event, event}, state) do
    agent_name = extract_agent_name(event)
    event_type = Map.get(event, :type)

    cond do
      event_type in @call_event_types ->
        record_call(agent_name, Map.get(event, :duration_ms))

      event_type in @error_event_types ->
        record_error(agent_name)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────────

  defp extract_agent_name(event) do
    (Map.get(event, :agent) || Map.get(event, :agent_name) || "unknown")
    |> to_string()
  end

  defp build_health(name, entry) do
    calls = Map.get(entry, :total_calls, 0)
    errors = Map.get(entry, :error_count, 0)
    latency = Map.get(entry, :total_latency_ms, 0)

    avg_latency =
      if calls > 0, do: Float.round(latency / calls, 2), else: nil

    error_rate =
      if calls > 0, do: Float.round(errors / calls * 100, 2), else: 0.0

    %{
      agent: name,
      last_active: Map.get(entry, :last_active),
      total_calls: calls,
      error_count: errors,
      avg_latency_ms: avg_latency,
      error_rate: error_rate
    }
  end
end
