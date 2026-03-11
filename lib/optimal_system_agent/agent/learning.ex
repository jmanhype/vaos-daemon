defmodule OptimalSystemAgent.Agent.Learning do
  @moduledoc """
  Learning engine — tracks patterns, solutions, and corrections in ETS.

  Uses `:osa_learning_patterns` for hot reads. Persists to disk every 50
  observations at `~/.osa/learning/patterns.json` and `solutions.json`.
  """

  use GenServer

  require Logger

  @table :osa_learning_patterns
  @flush_interval 50
  @persist_dir Path.expand("~/.osa/learning")

  # -- Public API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Record an observation (event map). Increments pattern counters."
  def observe(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:observe, event})
  end

  def observe(_), do: :ok

  @doc "Return all tracked patterns as a map of %{key => count}."
  def patterns do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _ ->
        :ets.match_object(@table, {{:pattern, :_}, :_})
        |> Enum.into(%{}, fn {{:pattern, key}, data} -> {key, data.count} end)
    end
  rescue
    _ -> %{}
  end

  @doc "Return all tracked solutions as a map of %{problem => solution_map}."
  def solutions do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _ ->
        :ets.match_object(@table, {{:solution, :_}, :_})
        |> Enum.into(%{}, fn {{:solution, key}, data} -> {key, data} end)
    end
  rescue
    _ -> %{}
  end

  @doc "Record a correction (what went wrong → what is right)."
  def correction(what_was_wrong, what_is_right) do
    GenServer.cast(__MODULE__, {:correction, what_was_wrong, what_is_right})
  end

  @doc "Record a correction with three args (what_was_wrong, what_is_right, _extra)."
  def correction(what_was_wrong, what_is_right, _extra) do
    correction(what_was_wrong, what_is_right)
  end

  @doc "Record a tool error for learning."
  def error(tool_name, error_message, context) do
    observe(%{
      type: :tool_error,
      tool: tool_name,
      error: error_message,
      context: context
    })
  end

  @doc "Return basic metrics."
  def metrics do
    %{
      patterns: map_size(patterns()),
      solutions: map_size(solutions()),
      observations: get_observation_count()
    }
  end

  @doc "Trigger a flush/consolidation to disk."
  def consolidate do
    GenServer.call(__MODULE__, :consolidate)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(:ok) do
    ensure_table()
    load_from_disk()
    {:ok, %{observation_count: 0}}
  end

  @impl true
  def handle_cast({:observe, event}, state) do
    ensure_table()

    key = extract_pattern_key(event)
    now = DateTime.utc_now()

    case :ets.lookup(@table, {:pattern, key}) do
      [{{:pattern, ^key}, data}] ->
        updated = %{data | count: data.count + 1, last_seen: now}
        :ets.insert(@table, {{:pattern, key}, updated})

      [] ->
        data = %{pattern: key, count: 1, first_seen: now, last_seen: now}
        :ets.insert(@table, {{:pattern, key}, data})
    end

    new_count = state.observation_count + 1

    if rem(new_count, @flush_interval) == 0 do
      flush_to_disk()
    end

    {:noreply, %{state | observation_count: new_count}}
  end

  def handle_cast({:correction, what_was_wrong, what_is_right}, state) do
    ensure_table()

    now = DateTime.utc_now()
    key = safe_key(what_was_wrong)

    solution = %{
      problem: what_was_wrong,
      solution: what_is_right,
      correction: what_is_right,
      confidence: 0.8,
      recorded_at: now
    }

    :ets.insert(@table, {{:solution, key}, solution})
    {:noreply, state}
  end

  @impl true
  def handle_call(:consolidate, _from, state) do
    flush_to_disk()
    {:reply, :ok, state}
  end

  # -- Internal helpers ------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public])
      _ -> @table
    end
  rescue
    ArgumentError -> @table
  end

  defp extract_pattern_key(%{type: type} = event) do
    tool = Map.get(event, :tool, "unknown")
    "#{type}:#{tool}"
  end

  defp extract_pattern_key(event) when is_map(event) do
    type = Map.get(event, "type", "unknown")
    tool = Map.get(event, "tool", Map.get(event, :tool, "unknown"))
    "#{type}:#{tool}"
  end

  defp safe_key(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-]/, "_")
    |> String.slice(0, 100)
  end

  defp safe_key(other), do: safe_key(inspect(other))

  defp get_observation_count do
    try do
      GenServer.call(__MODULE__, :consolidate)
      # We don't store the count externally; just return pattern count as proxy
      map_size(patterns())
    rescue
      _ -> 0
    catch
      :exit, _ -> 0
    end
  end

  # -- Persistence -----------------------------------------------------------

  defp flush_to_disk do
    File.mkdir_p!(@persist_dir)

    patterns_data =
      patterns()
      |> Enum.into(%{}, fn {k, v} -> {k, v} end)

    solutions_data =
      solutions()
      |> Enum.into(%{}, fn {k, v} ->
        {k, Map.take(v, [:problem, :solution, :correction, :confidence])}
      end)

    File.write!(
      Path.join(@persist_dir, "patterns.json"),
      Jason.encode!(patterns_data, pretty: true)
    )

    File.write!(
      Path.join(@persist_dir, "solutions.json"),
      Jason.encode!(solutions_data, pretty: true)
    )

    :ok
  rescue
    e ->
      Logger.debug("[Learning] flush failed: #{Exception.message(e)}")
      :ok
  end

  defp load_from_disk do
    load_patterns()
    load_solutions()
  rescue
    _ -> :ok
  end

  defp load_patterns do
    path = Path.join(@persist_dir, "patterns.json")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) ->
              now = DateTime.utc_now()

              Enum.each(map, fn {key, count} ->
                count = if is_integer(count), do: count, else: 1
                data = %{pattern: key, count: count, first_seen: now, last_seen: now}
                :ets.insert(@table, {{:pattern, key}, data})
              end)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp load_solutions do
    path = Path.join(@persist_dir, "solutions.json")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) ->
              now = DateTime.utc_now()

              Enum.each(map, fn {key, val} when is_map(val) ->
                solution = %{
                  problem: Map.get(val, "problem", key),
                  solution: Map.get(val, "solution", ""),
                  correction: Map.get(val, "correction", ""),
                  confidence: Map.get(val, "confidence", 0.5),
                  recorded_at: now
                }
                :ets.insert(@table, {{:solution, key}, solution})
              end)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end
end
