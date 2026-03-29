defmodule Daemon.Agent.MemoryTracker do
  @moduledoc """
  Per-session memory usage tracking with automatic cleanup above threshold.

  Tracks memory consumption for each agent session and automatically triggers
  cleanup when usage exceeds configured thresholds. Prevents memory leaks from
  long-running sessions.

  ## Configuration

      config :daemon,
        memory_tracker_enabled: true,
        memory_check_interval_ms: 30_000,  # Check every 30 seconds
        memory_warning_threshold_mb: 500,  # Warn at 500MB
        memory_critical_threshold_mb: 1000, # Critical at 1GB
        memory_cleanup_trigger_mb: 800     # Trigger cleanup at 800MB

  ## ETS Tables

    * `:daemon_memory_sessions` - Per-session tracking data
      * `{session_id, pid, started_at, last_check_mb, peak_mb, message_count}`

    * `:daemon_memory_stats` - Aggregate statistics
      * `{:total_sessions, count}`
      * `{:total_memory_mb, total}`
      * `{:peak_memory_mb, peak}`

  ## Usage

      # Start tracking a session
      MemoryTracker.track_session(session_id, pid)

      # Record memory usage (called automatically by periodic check)
      MemoryTracker.record_usage(session_id, memory_mb)

      # Get session stats
      MemoryTracker.session_stats(session_id)
      # => %{memory_mb: 234, message_count: 42, peak_mb: 256, ...}

      # Trigger manual cleanup
      MemoryTracker.cleanup_session(session_id)

  """

  use GenServer
  require Logger

  @check_interval_ms Application.compile_env(:daemon, :memory_check_interval_ms, 30_000)
  @warning_threshold_mb Application.compile_env(:daemon, :memory_warning_threshold_mb, 500)
  @critical_threshold_mb Application.compile_env(:daemon, :memory_critical_threshold_mb, 1000)
  @cleanup_trigger_mb Application.compile_env(:daemon, :memory_cleanup_trigger_mb, 800)

  # ETS table names
  @sessions_table :daemon_memory_sessions
  @stats_table :daemon_memory_stats

  defstruct [
    check_interval: @check_interval_ms,
    warning_threshold: @warning_threshold_mb,
    critical_threshold: @critical_threshold_mb,
    cleanup_trigger: @cleanup_trigger_mb,
    timer_ref: nil
  ]

  # --- Client API ---

  @doc "Start the memory tracker server."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Track a new session. Called when a Loop process starts."
  def track_session(session_id, pid \\ nil) do
    try do
      :ets.insert(@sessions_table, {
        session_id,
        pid || self(),
        System.monotonic_time(:millisecond),
        0,      # last_check_mb
        0,      # peak_mb
        0       # message_count
      })

      :ets.update_counter(@stats_table, :total_sessions, 1)

      Logger.debug("[MemoryTracker] Tracking session: #{session_id}")
      :ok
    rescue
      _ ->
        Logger.warning("[MemoryTracker] Failed to track session: #{session_id}")
        {:error, :tracking_failed}
    end
  end

  @doc "Remove a session from tracking. Called when a Loop process terminates."
  def untrack_session(session_id) do
    try do
      case :ets.lookup(@sessions_table, session_id) do
        [{_sid, _pid, _started, _last_check, peak_mb, _msg_count}] ->
          :ets.delete(@sessions_table, session_id)
          :ets.update_counter(@stats_table, :total_sessions, -1)
          Logger.debug("[MemoryTracker] Untracked session: #{session_id} (peak: #{peak_mb}MB)")
          :ok

        [] ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  @doc "Record current memory usage for a session."
  def record_usage(session_id, memory_mb) when is_number(memory_mb) and memory_mb > 0 do
    try do
      case :ets.lookup(@sessions_table, session_id) do
        [{_sid, pid, started_at, _last_check, peak_mb, msg_count}] ->
          # Update peak if current is higher
          new_peak = max(peak_mb, memory_mb)

          :ets.insert(@sessions_table, {
            session_id,
            pid,
            started_at,
            memory_mb,
            new_peak,
            msg_count
          })

          # Update aggregate stats
          :ets.update_counter(@stats_table, :total_memory_mb, memory_mb)
          current_peak = :ets.update_counter(@stats_table, :peak_memory_mb, {2, 0}, {1, 0})
          if memory_mb > current_peak do
            :ets.insert(@stats_table, {:peak_memory_mb, memory_mb})
          end

          # Check thresholds and emit events
          check_thresholds(session_id, memory_mb, new_peak)

          :ok

        [] ->
          {:error, :session_not_found}
      end
    rescue
      _ -> {:error, :recording_failed}
    end
  end

  @doc "Increment message count for a session."
  def increment_message_count(session_id) do
    try do
      :ets.update_counter(@sessions_table, session_id, {6, 1}, {
        session_id, nil, 0, 0, 0, 0
      })
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc "Get statistics for a specific session."
  def session_stats(session_id) do
    try do
      case :ets.lookup(@sessions_table, session_id) do
        [{_sid, _pid, started_at, last_check_mb, peak_mb, msg_count}] ->
          duration_ms = System.monotonic_time(:millisecond) - started_at
          duration_sec = div(duration_ms, 1000)

          %{
            session_id: session_id,
            memory_mb: last_check_mb,
            peak_mb: peak_mb,
            message_count: msg_count,
            duration_seconds: duration_sec,
            started_at: DateTime.from_unix!(div(started_at, 1000), :millisecond)
          }

        [] ->
          {:error, :session_not_found}
      end
    rescue
      _ -> {:error, :stats_failed}
    end
  end

  @doc "Get aggregate statistics across all sessions."
  def aggregate_stats do
    try do
      total_sessions = :ets.lookup_element(@stats_table, :total_sessions, 2)
      total_memory = :ets.lookup_element(@stats_table, :total_memory_mb, 2)
      peak_memory = :ets.lookup_element(@stats_table, :peak_memory_mb, 2)

      %{
        total_sessions: total_sessions,
        total_memory_mb: total_memory,
        peak_memory_mb: peak_memory,
        average_memory_mb: if(total_sessions > 0, do: div(total_memory, total_sessions), else: 0)
      }
    rescue
      _ -> %{total_sessions: 0, total_memory_mb: 0, peak_memory_mb: 0, average_memory_mb: 0}
    end
  end

  @doc "List all tracked sessions with their stats."
  def list_sessions do
    try do
      :ets.tab2list(@sessions_table)
      |> Enum.map(fn {sid, _pid, started_at, last_check_mb, peak_mb, msg_count} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        %{
          session_id: sid,
          memory_mb: last_check_mb,
          peak_mb: peak_mb,
          message_count: msg_count,
          duration_seconds: div(duration_ms, 1000)
        }
      end)
    rescue
      _ -> []
    end
  end

  @doc "Manually trigger cleanup for a session."
  def cleanup_session(session_id) do
    Logger.info("[MemoryTracker] Manual cleanup requested for session: #{session_id}")

    case Registry.lookup(Daemon.SessionRegistry, session_id) do
      [{pid, _}] when is_pid(pid) ->
        # Trigger memory cleanup in the Loop process
        try do
          GenServer.call(pid, :cleanup_memory)
        catch
          :exit, _ -> {:error, :process_terminated}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  @doc "Force cleanup of all sessions above threshold."
  def cleanup_all_above_threshold(threshold_mb \\ @cleanup_trigger_mb) do
    Logger.info("[MemoryTracker] Forcing cleanup for sessions above #{threshold_mb}MB")

    sessions_to_cleanup =
      try do
        :ets.tab2list(@sessions_table)
        |> Enum.filter(fn {_sid, _pid, _started, last_check_mb, _peak, _msg_count} ->
          last_check_mb >= threshold_mb
        end)
      rescue
        _ -> []
      end

    Enum.each(sessions_to_cleanup, fn {session_id, _pid, _started, _last_check, _peak, _msg_count} ->
      cleanup_session(session_id)
    end)

    {:ok, length(sessions_to_cleanup)}
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    # Create ETS tables
    try do
      :ets.new(@sessions_table, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.new(@stats_table, [:named_table, :public, :set])
      :ets.insert(@stats_table, {:total_sessions, 0})
      :ets.insert(@stats_table, {:total_memory_mb, 0})
      :ets.insert(@stats_table, {:peak_memory_mb, 0})
    rescue
      ArgumentError -> :ok
    end

    check_interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    # Schedule periodic memory check
    timer_ref = Process.send_after(self(), :check_memory, check_interval)

    state = %__MODULE__{
      check_interval: check_interval,
      timer_ref: timer_ref
    }

    Logger.info("[MemoryTracker] Started (check interval: #{check_interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_info(:check_memory, state) do
    # Reschedule next check
    timer_ref = Process.send_after(self(), :check_memory, state.check_interval)

    # Check memory for all tracked sessions
    check_all_sessions()

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp check_all_sessions do
    try do
      sessions = :ets.tab2list(@sessions_table)

      Enum.each(sessions, fn {session_id, _pid, _started, _last_check, _peak, _msg_count} ->
        # Get memory for the session's Loop process
        case Registry.lookup(Daemon.SessionRegistry, session_id) do
          [{pid, _}] when is_pid(pid) ->
            memory_mb = get_process_memory_mb(pid)
            if memory_mb > 0 do
              record_usage(session_id, memory_mb)
            end

          [] ->
            # Session no longer exists, untrack it
            untrack_session(session_id)
        end
      end)
    rescue
      e ->
        Logger.warning("[MemoryTracker] Check failed: #{inspect(e)}")
    end
  end

  defp get_process_memory_mb(pid) do
    try do
      # Get process info in bytes
      case :erlang.process_info(pid, :memory) do
        {:memory, bytes} when is_number(bytes) ->
          # Convert to MB
          div(bytes, 1_048_576)

        _ ->
          0
      end
    catch
      _, _ -> 0
    end
  end

  defp check_thresholds(session_id, current_mb, peak_mb) do
    cond do
      current_mb >= @critical_threshold_mb ->
        Logger.error("[MemoryTracker] CRITICAL: Session #{session_id} using #{current_mb}MB (peak: #{peak_mb}MB)")

        Daemon.Events.Bus.emit(:system_event, %{
          event: :memory_critical,
          session_id: session_id,
          memory_mb: current_mb,
          peak_mb: peak_mb
        })

        # Trigger automatic cleanup
        trigger_cleanup(session_id, current_mb)

      current_mb >= @cleanup_trigger_mb ->
        Logger.warning("[MemoryTracker] Cleanup threshold exceeded: Session #{session_id} using #{current_mb}MB (peak: #{peak_mb}MB)")

        Daemon.Events.Bus.emit(:system_event, %{
          event: :memory_cleanup_triggered,
          session_id: session_id,
          memory_mb: current_mb,
          peak_mb: peak_mb
        })

        trigger_cleanup(session_id, current_mb)

      current_mb >= @warning_threshold_mb ->
        Logger.warning("[MemoryTracker] WARNING: Session #{session_id} using #{current_mb}MB (peak: #{peak_mb}MB)")

        Daemon.Events.Bus.emit(:system_event, %{
          event: :memory_warning,
          session_id: session_id,
          memory_mb: current_mb,
          peak_mb: peak_mb
        })

      true ->
        :ok
    end
  end

  defp trigger_cleanup(session_id, memory_mb) do
    case Registry.lookup(Daemon.SessionRegistry, session_id) do
      [{pid, _}] when is_pid(pid) ->
        # Request cleanup in the Loop process
        try do
          GenServer.cast(pid, :cleanup_memory)
          Logger.info("[MemoryTracker] Triggered cleanup for session #{session_id} (#{memory_mb}MB)")
        catch
          :exit, _ ->
            Logger.warning("[MemoryTracker] Could not trigger cleanup for session #{session_id}: process terminated")
        end

      [] ->
        Logger.warning("[MemoryTracker] Session #{session_id} not found for cleanup")
    end
  end
end
