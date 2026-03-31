defmodule Daemon.Fitness.Evaluator do
  @moduledoc """
  Async fitness evaluator — runs fitness modules on a timer and caches results.

  WorkDirector.Source.Fitness calls `get_results/0` which returns immediately
  from the cache (< 1ms) instead of blocking on `Daemon.Fitness.evaluate_all/1`
  which can take 60–300s when running mix test/compile.

  ## Design

  - Runs evaluation every 10 minutes (configurable via `:fitness_interval_ms`)
  - First evaluation fires 30s after boot (let the app stabilize)
  - Results stored in GenServer state as `%{name => {status, score, detail}}`
  - Returns `:pending` if no evaluation has completed yet
  """

  use GenServer

  require Logger

  @default_interval_ms 10 * 60 * 1_000
  @initial_delay_ms 30_000

  # ── Client API ──

  @doc "Get cached fitness results. Returns {:ok, map} | :pending | {:error, term}."
  @spec get_results() :: {:ok, map()} | :pending | {:error, term()}
  def get_results do
    GenServer.call(__MODULE__, :get_results, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # ── Server ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Application.get_env(:daemon, :fitness_interval_ms, @default_interval_ms)
    workspace = Application.get_env(:daemon, :workspace, File.cwd!())

    # Schedule first evaluation after initial delay
    Process.send_after(self(), :evaluate, @initial_delay_ms)

    {:ok, %{results: nil, interval: interval, workspace: workspace, evaluating: false}}
  end

  @impl true
  def handle_call(:get_results, _from, %{results: nil} = state) do
    {:reply, :pending, state}
  end

  def handle_call(:get_results, _from, %{results: results} = state) do
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_info(:evaluate, %{evaluating: true} = state) do
    # Skip if already running
    {:noreply, state}
  end

  def handle_info(:evaluate, state) do
    # Run evaluation in a spawned task to avoid blocking the GenServer
    parent = self()
    workspace = state.workspace

    Task.Supervisor.start_child(Daemon.TaskSupervisor, fn ->
      Logger.info("[Fitness.Evaluator] Starting evaluation cycle")

      results =
        try do
          Daemon.Fitness.evaluate_all(workspace)
          |> Map.new()
        rescue
          e ->
            Logger.error("[Fitness.Evaluator] Evaluation crashed: #{Exception.message(e)}")
            %{}
        catch
          :exit, reason ->
            Logger.error("[Fitness.Evaluator] Evaluation exited: #{inspect(reason)}")
            %{}
        end

      send(parent, {:evaluation_complete, results})
    end)

    {:noreply, %{state | evaluating: true}}
  end

  def handle_info({:evaluation_complete, results}, state) do
    count = map_size(results)
    Logger.info("[Fitness.Evaluator] Evaluation complete: #{count} fitness checks cached")

    # Schedule next evaluation
    Process.send_after(self(), :evaluate, state.interval)

    {:noreply, %{state | results: results, evaluating: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
