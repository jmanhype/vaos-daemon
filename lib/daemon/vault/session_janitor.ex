defmodule Daemon.Vault.SessionJanitor do
  @moduledoc """
  Periodic cleanup of expired sessions.

  Runs on a timer to:
  - Mark sessions as expired based on timeout
  - Remove dirty flags for expired sessions
  - Trigger :session_expire hooks for each expired session
  - Clean up orphaned dirty flags

  Session timeout is configurable via:
    Application.get_env(:daemon, :session_timeout_seconds, 1800)

  Default: 30 minutes of inactivity before expiration.
  """
  use GenServer
  require Logger

  alias Daemon.Vault.Store
  alias Daemon.Agent.Hooks
  alias Daemon.Events.Bus

  @default_interval_seconds 300  # 5 minutes
  @default_timeout_seconds 1800  # 30 minutes

  defstruct interval: nil,
            timeout: nil,
            timer: nil,
            cleaned_count: 0,
            error_count: 0

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger cleanup of expired sessions.
  Returns {cleaned_count, error_count}.
  """
  @spec cleanup_expired_sessions() :: {integer(), integer()}
  def cleanup_expired_sessions do
    GenServer.call(__MODULE__, :cleanup_expired_sessions, 30_000)
  end

  @doc """
  Get cleanup statistics.
  """
  @spec stats() :: %{cleaned: integer(), errors: integer(), last_cleanup: DateTime.t() | nil}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Update the cleanup interval (in seconds).
  """
  @spec set_interval(integer()) :: :ok
  def set_interval(seconds) when is_integer(seconds) and seconds > 0 do
    GenServer.cast(__MODULE__, {:set_interval, seconds})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    interval = Application.get_env(:daemon, :session_cleanup_interval_seconds, @default_interval_seconds)
    timeout = Application.get_env(:daemon, :session_timeout_seconds, @default_timeout_seconds)

    # Schedule first cleanup
    timer = schedule_cleanup(interval)

    Logger.info("[SessionJanitor] Started with #{interval}s interval, #{timeout}s timeout")

    {:ok, %__MODULE__{
      interval: interval,
      timeout: timeout,
      timer: timer
    }}
  end

  @impl true
  def handle_call(:cleanup_expired_sessions, _from, state) do
    {cleaned, errors} = do_cleanup(state.timeout)

    # Emit telemetry event
    Bus.emit(:system_event, %{
      event: :session_cleanup,
      cleaned: cleaned,
      errors: errors,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    new_state = %{state | cleaned_count: state.cleaned_count + cleaned, error_count: state.error_count + errors}

    {:reply, {cleaned, errors}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      cleaned: state.cleaned_count,
      errors: state.error_count,
      last_cleanup: DateTime.utc_now()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:set_interval, seconds}, state) do
    # Cancel existing timer
    if state.timer, do: Process.cancel_timer(state.timer)

    # Schedule new cleanup
    timer = schedule_cleanup(seconds)

    Logger.info("[SessionJanitor] Interval updated to #{seconds}s")

    {:noreply, %{state | interval: seconds, timer: timer}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    {cleaned, errors} = do_cleanup(state.timeout)

    # Emit telemetry event
    Bus.emit(:system_event, %{
      event: :session_cleanup,
      cleaned: cleaned,
      errors: errors,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    # Reschedule next cleanup
    timer = schedule_cleanup(state.interval)

    new_state = %{
      state
      | timer: timer,
        cleaned_count: state.cleaned_count + cleaned,
        error_count: state.error_count + errors
    }

    Logger.debug("[SessionJanitor] Cleaned #{cleaned} sessions, #{errors} errors")

    {:noreply, new_state}
  end

  # --- Private Helpers ---

  defp schedule_cleanup(seconds) do
    Process.send_after(self(), :cleanup, seconds * 1000)
  end

  defp do_cleanup(timeout_seconds) do
    sessions_dir = Path.join([Store.vault_root(), "sessions"])
    dirty_dir = Path.join([Store.vault_root(), ".vault", "dirty"])

    # Get cutoff time
    cutoff = DateTime.utc_now() |> DateTime.add(-timeout_seconds, :second)

    # Clean up expired sessions
    {cleaned, errors} = cleanup_sessions(sessions_dir, cutoff)

    # Clean up orphaned dirty flags
    orphaned = cleanup_orphaned_dirty_flags(dirty_dir, sessions_dir)

    total_cleaned = cleaned + orphaned

    Logger.info(
      "[SessionJanitor] Cleanup complete: #{total_cleaned} sessions, #{errors} errors"
    )

    {total_cleaned, errors}
  end

  defp cleanup_sessions(sessions_dir, cutoff) do
    unless File.dir?(sessions_dir) do
      Logger.debug("[SessionJanitor] Sessions directory does not exist: #{sessions_dir}")
      {0, 0}
    else
      sessions_dir
      |> File.ls!()
      |> Enum.reduce({0, 0}, fn filename, {cleaned, errors} ->
        session_path = Path.join(sessions_dir, filename)

        case process_session(session_path, cutoff) do
          {:ok, :expired} ->
            {cleaned + 1, errors}

          {:ok, :active} ->
            {cleaned, errors}

          {:error, _reason} ->
            {cleaned, errors + 1}
        end
      end)
    end
  rescue
    _e ->
      Logger.error("[SessionJanitor] Error accessing sessions directory")
      {0, 0}
  end

  defp process_session(session_path, cutoff) do
    with {:ok, content} <- File.read(session_path),
         {:ok, data} <- Jason.decode(content),
         {:ok, last_activity} <- parse_last_activity(data),
         true <- DateTime.compare(last_activity, cutoff) == :lt do
      # Session is expired
      session_id = Map.get(data, "id")

      # Trigger hook
      Hooks.run_async(:session_expire, %{
        session_id: session_id,
        expired_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        last_activity: DateTime.to_iso8601(last_activity)
      })

      # Clean up dirty flag
      cleanup_dirty_flag(session_id)

      # Remove session file
      File.rm!(session_path)

      Logger.debug("[SessionJanitor] Session expired: #{session_id}")

      {:ok, :expired}
    else
      {:error, _} = error ->
        error

      _ ->
        # Session is still active
        {:ok, :active}
    end
  rescue
    e ->
      Logger.warning("[SessionJanitor] Error processing session: #{Exception.message(e)}")
      {:error, :processing_error}
  end

  defp parse_last_activity(data) do
    # Try last_activity first, then woke_at
    timestamp_str =
      Map.get(data, "last_activity") || Map.get(data, "woke_at") || Map.get(data, "created_at")

    case timestamp_str do
      nil -> {:error, :no_timestamp}
      ts -> DateTime.from_iso8601(ts)
    end
  end

  defp cleanup_dirty_flag(session_id) do
    dirty_dir = Path.join([Store.vault_root(), ".vault", "dirty"])
    dirty_path = Path.join(dirty_dir, session_id)

    if File.exists?(dirty_path) do
      File.rm!(dirty_path)
      Logger.debug("[SessionJanitor] Cleaned dirty flag for: #{session_id}")
    end
  end

  defp cleanup_orphaned_dirty_flags(dirty_dir, sessions_dir) do
    unless File.dir?(dirty_dir) do
      0
    else
      dirty_dir
      |> File.ls!()
      |> Enum.reduce(0, fn session_id, count ->
        session_path = Path.join(sessions_dir, "#{session_id}.json")

        unless File.exists?(session_path) do
          # Orphaned dirty flag - no corresponding session file
          dirty_path = Path.join(dirty_dir, session_id)
          File.rm!(dirty_path)
          Logger.debug("[SessionJanitor] Removed orphaned dirty flag: #{session_id}")
          count + 1
        else
          count
        end
      end)
    end
  rescue
    _e ->
      0
  end
end
