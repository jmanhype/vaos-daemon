defmodule Daemon.Tools.Cache do
  @moduledoc """
  ETS-backed tool result cache with per-entry TTL.

  Each cache entry stores `{key, value, expires_at_monotonic_ms}`.
  Expired entries are lazily evicted on `get/1`.

  Tracks hit/miss counts in GenServer state for `stats/0`.
  """
  use GenServer

  @table :tool_result_cache
  @default_ttl_ms 60_000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch a cached value. Returns `{:ok, value}`, `:miss`, or `{:miss, :expired}`."
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc "Store a value with the default TTL."
  def put(key, value) do
    put(key, value, @default_ttl_ms)
  end

  @doc "Store a value with a custom TTL in milliseconds."
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    GenServer.cast(__MODULE__, :put)
    :ok
  end

  @doc "Remove a specific entry."
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Remove all entries."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Return cache statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{hits: 0, misses: 0}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [] ->
        {:reply, :miss, %{state | misses: state.misses + 1}}

      [{^key, _value, expires_at}] when expires_at <= now ->
        :ets.delete(@table, key)
        {:reply, {:miss, :expired}, %{state | misses: state.misses + 1}}

      [{^key, value, _expires_at}] ->
        {:reply, {:ok, value}, %{state | hits: state.hits + 1}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(@table, :size)
    {:reply, Map.put(state, :size, size), state}
  end

  @impl true
  def handle_cast(:put, state) do
    {:noreply, state}
  end
end
