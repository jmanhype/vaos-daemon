defmodule Daemon.Production.ChromeHealth do
  @moduledoc """
  Health checks and auto-recovery for Chrome and the OSA companion app.

  Provides three capabilities:
    - `ensure_chrome!/0`       — starts Chrome if not running
    - `ensure_osa_app!/0`      — starts the OSA.app HTTP companion if not running
    - `verify_flow_project/1`  — confirms Chrome is on the expected Flow project URL
  """
  use GenServer

  require Logger

  @osa_app_health_url "http://localhost:8089/api/v1/health"
  @health_check_interval :timer.minutes(2)

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if Google Chrome is running."
  @spec chrome_running?() :: boolean()
  def chrome_running? do
    case System.cmd("pgrep", ["-x", "Google Chrome"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  @doc "Returns true if the OSA companion app is healthy."
  @spec osa_app_running?() :: boolean()
  def osa_app_running? do
    case System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", @osa_app_health_url],
           stderr_to_stdout: true
         ) do
      {"200", 0} -> true
      _ -> false
    end
  end

  @doc """
  Ensures Chrome is running. Starts it if not.
  Raises on failure.
  """
  @spec ensure_chrome!() :: :ok
  def ensure_chrome! do
    if chrome_running?() do
      :ok
    else
      Logger.warning("[ChromeHealth] Chrome not running — starting")
      System.cmd("open", ["-a", "Google Chrome"], stderr_to_stdout: true)
      # Give Chrome a moment to start
      Process.sleep(3_000)

      if chrome_running?() do
        Logger.info("[ChromeHealth] Chrome started successfully")
        :ok
      else
        raise "Failed to start Google Chrome"
      end
    end
  end

  @doc """
  Ensures the OSA companion app is running. Starts it if not.
  Raises on failure.
  """
  @spec ensure_osa_app!() :: :ok
  def ensure_osa_app! do
    if osa_app_running?() do
      :ok
    else
      Logger.warning("[ChromeHealth] OSA.app not running — starting")
      System.cmd("open", ["-a", "Daemon"], stderr_to_stdout: true)
      Process.sleep(5_000)

      if osa_app_running?() do
        Logger.info("[ChromeHealth] OSA.app started successfully")
        :ok
      else
        raise "Failed to start OSA.app"
      end
    end
  end

  @doc """
  Checks that Chrome is on the expected Flow project URL.
  Returns `:ok` if confirmed, `{:error, reason}` otherwise.

  Requires OSA.app to be running (uses its API to query active tab).
  """
  @spec verify_flow_project(String.t()) :: :ok | {:error, term()}
  def verify_flow_project(project_id) do
    expected_fragment = "project/#{project_id}"

    case System.cmd("curl", ["-s", "http://localhost:8089/api/v1/chrome/active-tab"],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        if String.contains?(body, expected_fragment) do
          :ok
        else
          {:error, {:wrong_project, body}}
        end

      {err, _code} ->
        {:error, {:daemon_app_unreachable, err}}
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:periodic_check, state) do
    if chrome_running?() do
      Logger.debug("[ChromeHealth] Chrome is running")
    else
      Logger.warning("[ChromeHealth] Chrome is NOT running")
    end

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :periodic_check, @health_check_interval)
  end
end
