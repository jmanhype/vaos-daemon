defmodule Daemon.Production.FlowRateLimiter do
  @moduledoc """
  Production rate limiter for Google Flow and Gemini API calls.

  Enforces minimum cooldowns between operations to avoid triggering
  rate limits on external services:

    - `:flow_submit`  — 5 seconds between Flow video submissions
    - `:flow_extend`  — 5 seconds between Flow extend operations
    - `:gemini_image` — 4 seconds between Gemini image API calls

  Uses ETS for lock-free timestamp reads. The GenServer owns the table
  and handles serialized check-and-wait logic.

  ## Usage

      FlowRateLimiter.check_and_wait(:flow_submit)
      # blocks until cooldown has passed, then returns :ok
  """
  use GenServer

  require Logger

  @table :daemon_flow_rate_limits

  @cooldowns %{
    flow_submit: 5_000,
    flow_extend: 5_000,
    gemini_image: 4_000
  }

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Blocks until the cooldown for `operation` has elapsed, then records
  the current time and returns `:ok`.

  Valid operations: `:flow_submit`, `:flow_extend`, `:gemini_image`.
  """
  @spec check_and_wait(atom()) :: :ok
  def check_and_wait(operation) when is_map_key(@cooldowns, operation) do
    GenServer.call(__MODULE__, {:check_and_wait, operation}, :timer.seconds(30))
  end

  @doc "Returns milliseconds remaining before `operation` can fire, or 0."
  @spec cooldown_remaining(atom()) :: non_neg_integer()
  def cooldown_remaining(operation) when is_map_key(@cooldowns, operation) do
    case :ets.lookup(@table, operation) do
      [{^operation, last_ts}] ->
        elapsed = System.monotonic_time(:millisecond) - last_ts
        max(@cooldowns[operation] - elapsed, 0)

      [] ->
        0
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_and_wait, operation}, _from, state) do
    cooldown = @cooldowns[operation]
    now = System.monotonic_time(:millisecond)

    wait_ms =
      case :ets.lookup(@table, operation) do
        [{^operation, last_ts}] ->
          elapsed = now - last_ts
          max(cooldown - elapsed, 0)

        [] ->
          0
      end

    if wait_ms > 0 do
      Logger.debug("[FlowRateLimiter] #{operation} — waiting #{wait_ms}ms")
      Process.sleep(wait_ms)
    end

    :ets.insert(@table, {operation, System.monotonic_time(:millisecond)})
    {:reply, :ok, state}
  end
end
