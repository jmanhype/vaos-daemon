defmodule OptimalSystemAgent.CommandCenter.EventHistory do
  @moduledoc """
  In-memory ring-buffer of recent OSA events for the command-center /events/history API.

  Subscribes to the `"osa:events"` Phoenix.PubSub firehose on start and keeps
  the last `@max_events` entries in an ETS table keyed by monotonic sequence number.

  Exposes `recent/1` to return the last N events in chronological order.
  """
  use GenServer
  require Logger

  @max_events 100
  @table :cc_event_history

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Return the last `n` events (default 50, capped at #{@max_events}) in
  chronological order (oldest first).
  """
  @spec recent(pos_integer()) :: [map()]
  def recent(n \\ 50) do
    n = min(n, @max_events)

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.take(-n)
    |> Enum.map(fn {_seq, event} -> event end)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:events")
    Logger.debug("[CommandCenter.EventHistory] started — buffering last #{@max_events} events")
    {:ok, %{seq: 0}}
  end

  @impl true
  def handle_info({:osa_event, event}, %{seq: seq} = state) do
    next_seq = seq + 1
    :ets.insert(@table, {next_seq, event})
    prune_if_needed(next_seq)
    {:noreply, %{state | seq: next_seq}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ───────────────────────────────────────────────────────────

  # Drop oldest entry once the buffer exceeds @max_events.
  defp prune_if_needed(current_seq) do
    if current_seq > @max_events do
      oldest = current_seq - @max_events
      :ets.delete(@table, oldest)
    end
  end
end
