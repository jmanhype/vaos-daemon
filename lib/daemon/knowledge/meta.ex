defmodule Daemon.Knowledge.Meta do
  @moduledoc """
  ETS+DETS overlay for knowledge triple metadata (helpful/harmful counters).

  Stores feedback counters per triple without modifying vaos-knowledge itself.
  Keys are `:erlang.phash2({s, p, o})` for fast lookup.
  """
  use GenServer
  require Logger

  @ets_table :daemon_knowledge_meta
  @dets_file "priv/data/knowledge_meta.dets"
  @flush_interval :timer.seconds(60)

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ensure a meta entry exists for the given triple."
  @spec ensure_meta({String.t(), String.t(), String.t()}) :: :ok
  def ensure_meta({_s, _p, _o} = triple) do
    key = :erlang.phash2(triple)

    case :ets.lookup(@ets_table, key) do
      [_] -> :ok
      [] ->
        now = System.system_time(:second)
        :ets.insert_new(@ets_table, {key, 0, 0, now})
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Increment the helpful counter for a triple."
  @spec increment_helpful({String.t(), String.t(), String.t()}) :: :ok
  def increment_helpful({_s, _p, _o} = triple) do
    key = :erlang.phash2(triple)
    ensure_meta(triple)

    try do
      :ets.update_counter(@ets_table, key, {2, 1})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc "Increment the harmful counter for a triple."
  @spec increment_harmful({String.t(), String.t(), String.t()}) :: :ok
  def increment_harmful({_s, _p, _o} = triple) do
    key = :erlang.phash2(triple)
    ensure_meta(triple)

    try do
      :ets.update_counter(@ets_table, key, {3, 1})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc "Net helpfulness score: helpful - harmful."
  @spec net_score({String.t(), String.t(), String.t()}) :: integer()
  def net_score({_s, _p, _o} = triple) do
    key = :erlang.phash2(triple)

    case :ets.lookup(@ets_table, key) do
      [{^key, helpful, harmful, _ts}] -> helpful - harmful
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # ── GenServer callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])

    dets_path = Application.app_dir(:daemon, @dets_file)
    File.mkdir_p!(Path.dirname(dets_path))
    {:ok, _} = :dets.open_file(@ets_table, file: String.to_charlist(dets_path), type: :set)

    # Load DETS into ETS
    :dets.to_ets(@ets_table, @ets_table)

    schedule_flush()
    {:ok, %{dets_path: dets_path}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_to_dets()
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    flush_to_dets()
    :dets.close(@ets_table)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────

  defp flush_to_dets do
    :ets.to_dets(@ets_table, @ets_table)
  rescue
    _ -> :ok
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end
end
