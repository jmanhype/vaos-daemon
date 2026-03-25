defmodule Daemon.Agent.ProactiveMode do
  @moduledoc """
  Central coordinator for proactive behaviour — the primary orchestrator of
  autonomous work in OSA.

  ProactiveMode is the single gateway between background systems (Scheduler,
  ProactiveMonitor, Event Bus) and the user. When enabled, OSA can:

  - Greet the user on session start with context-aware messages
  - Execute autonomous work via ProactiveMonitor alerts
  - Create/manage cron jobs, heartbeat tasks, and triggers
  - Notify the user of completed work through CLI/TUI
  - Maintain an activity log visible via `/activity`
  - Show "while you were away" summaries on reconnect

  All autonomous LLM calls route through here for:
  - Rate limiting (max 5 messages/hour, 30s minimum interval)
  - Budget enforcement (checks MiosaBudget before LLM calls)
  - Permission tier enforcement (`:workspace` by default)
  - Activity logging (persisted to `~/.daemon/data/proactive_log.jsonl`)

  Disabled by default. Toggle with `/proactive on|off`.
  """
  use GenServer
  require Logger

  alias Daemon.Events.Bus
  alias Daemon.Agent.Scheduler

  @max_messages_per_hour 5
  @min_message_interval_ms 30_000
  @max_activity_log 100
  @log_file "proactive_log.jsonl"

  defstruct enabled: false,
            greeting_enabled: true,
            autonomous_work: true,
            active_session: nil,
            max_messages_per_hour: @max_messages_per_hour,
            last_message_at: nil,
            message_count_this_hour: 0,
            activity_log: [],
            pending_notifications: [],
            autonomous_permission_tier: :workspace

  # ── Public API ──────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Enable proactive mode and persist to config."
  def enable, do: GenServer.call(__MODULE__, :enable)

  @doc "Disable proactive mode and persist to config."
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Check if proactive mode is enabled."
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "Toggle proactive mode."
  def toggle do
    if enabled?(), do: disable(), else: enable()
  end

  @doc "Set the active CLI/TUI session for message delivery."
  def set_active_session(session_id) do
    GenServer.cast(__MODULE__, {:set_active_session, session_id})
  end

  @doc "Clear the active session (user disconnected)."
  def clear_active_session do
    GenServer.cast(__MODULE__, :clear_active_session)
  end

  @doc "Queue a proactive notification for delivery to the active session."
  def notify(message, type \\ :info) when is_binary(message) do
    GenServer.cast(__MODULE__, {:notify, message, type})
  end

  @doc """
  Handle an alert from ProactiveMonitor.

  When proactive mode is enabled:
  - Logs the alert to the activity log
  - For critical alerts: queues notification + optionally dispatches autonomous agent work
  - For non-critical: queues notification only

  When disabled: alert is silently dropped.
  """
  def handle_alert(alert) when is_map(alert) do
    GenServer.cast(__MODULE__, {:handle_alert, alert})
  end

  @doc """
  Schedule autonomous work via the Scheduler.

  Creates a cron job that runs through ProactiveMode's pipeline:
  - Budget check before execution
  - Activity logging of results
  - User notification on completion

  Returns `{:ok, job}` or `{:error, reason}`.
  """
  def schedule_work(opts) when is_map(opts) do
    GenServer.call(__MODULE__, {:schedule_work, opts})
  end

  @doc """
  Add a heartbeat task that ProactiveMode will track.
  Delegates to Scheduler.add_heartbeat_task/1 and logs the creation.
  """
  def add_heartbeat_task(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:add_heartbeat_task, text})
  end

  @doc """
  Create an event trigger routed through ProactiveMode.
  Delegates to Scheduler.add_trigger/1 and logs.
  """
  def add_trigger(trigger_map) when is_map(trigger_map) do
    GenServer.call(__MODULE__, {:add_trigger, trigger_map})
  end

  @doc "Get activity log entries since a given datetime."
  def activity_since(datetime) do
    GenServer.call(__MODULE__, {:activity_since, datetime})
  end

  @doc "Get all activity log entries."
  def activity_log do
    GenServer.call(__MODULE__, :activity_log)
  end

  @doc "Clear the activity log."
  def clear_activity_log do
    GenServer.cast(__MODULE__, :clear_activity_log)
  end

  @doc "Get current proactive mode status summary."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Generate a greeting for the given session.
  Returns `{:ok, greeting_text}` or `:skip`.
  """
  def greeting(session_id) do
    GenServer.call(__MODULE__, {:greeting, session_id}, 15_000)
  rescue
    _ -> :skip
  catch
    :exit, _ -> :skip
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    enabled = read_config_enabled()
    state = %__MODULE__{enabled: enabled, activity_log: load_activity_log()}

    # Listen for scheduler job completions to log them
    register_scheduler_handlers()

    # Reset hourly message count
    schedule_hourly_reset()

    # Schedule delivery check
    schedule_delivery_check()

    Logger.info("[ProactiveMode] initialized (enabled: #{enabled})")
    {:ok, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    persist_config(true)
    Bus.emit(:system_event, %{event: :proactive_mode_changed, enabled: true})
    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    persist_config(false)
    Bus.emit(:system_event, %{event: :proactive_mode_changed, enabled: false})
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def handle_call({:schedule_work, opts}, _from, state) do
    if state.enabled do
      job_map = %{
        "name" => Map.get(opts, :name, "proactive_work"),
        "schedule" => Map.get(opts, :schedule, "0 */6 * * *"),
        "type" => "agent",
        "task" => Map.get(opts, :task, ""),
        "enabled" => true,
        "source" => "proactive_mode"
      }

      result = Scheduler.add_job(job_map)

      case result do
        {:ok, job} ->
          log_activity(state, "scheduled", "Created scheduled job: #{job["name"]}")
          {:reply, {:ok, job}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Proactive mode is disabled"}, state}
    end
  end

  @impl true
  def handle_call({:add_heartbeat_task, text}, _from, state) do
    if state.enabled do
      result = Scheduler.add_heartbeat_task(text)

      case result do
        :ok ->
          state = log_activity(state, "heartbeat", "Added heartbeat task: #{text}")
          {:reply, :ok, state}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, "Proactive mode is disabled"}, state}
    end
  end

  @impl true
  def handle_call({:add_trigger, trigger_map}, _from, state) do
    if state.enabled do
      enriched = Map.put(trigger_map, "source", "proactive_mode")
      result = Scheduler.add_trigger(enriched)

      case result do
        {:ok, trigger} ->
          state = log_activity(state, "trigger", "Created trigger: #{trigger["name"] || trigger["id"]}")
          {:reply, {:ok, trigger}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Proactive mode is disabled"}, state}
    end
  end

  @impl true
  def handle_call({:activity_since, datetime}, _from, state) do
    entries =
      Enum.filter(state.activity_log, fn entry ->
        case DateTime.from_iso8601(entry["ts"] || "") do
          {:ok, ts, _} -> DateTime.compare(ts, datetime) in [:gt, :eq]
          _ -> false
        end
      end)

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:activity_log, _from, state) do
    {:reply, state.activity_log, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    scheduler_status =
      try do
        Scheduler.status()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    result = %{
      enabled: state.enabled,
      greeting_enabled: state.greeting_enabled,
      autonomous_work: state.autonomous_work,
      active_session: state.active_session,
      messages_this_hour: state.message_count_this_hour,
      max_messages_per_hour: state.max_messages_per_hour,
      activity_log_count: length(state.activity_log),
      pending_notifications: length(state.pending_notifications),
      permission_tier: state.autonomous_permission_tier,
      scheduler: scheduler_status
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:greeting, session_id}, _from, state) do
    if state.enabled and state.greeting_enabled and
         not Daemon.Onboarding.first_run?() do
      greeting_text = build_greeting(session_id, state)
      {:reply, {:ok, greeting_text}, state}
    else
      {:reply, :skip, state}
    end
  end

  @impl true
  def handle_cast({:set_active_session, session_id}, state) do
    {:noreply, %{state | active_session: session_id}}
  end

  @impl true
  def handle_cast(:clear_active_session, state) do
    {:noreply, %{state | active_session: nil}}
  end

  @impl true
  def handle_cast({:notify, message, type}, state) do
    if state.enabled do
      state = log_activity(state, to_string(type), message)
      new_pending = state.pending_notifications ++ [{message, type}]
      {:noreply, %{state | pending_notifications: new_pending}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:handle_alert, alert}, state) do
    if state.enabled and state.autonomous_work do
      state = log_activity(state, "alert:#{alert.severity}", alert.message)

      # For critical alerts: dispatch autonomous agent work if budget allows
      state =
        if alert.severity == :critical do
          maybe_dispatch_autonomous(alert, state)
        else
          state
        end

      # Queue notification for user
      summary = "[#{alert.severity}] #{alert.message}"
      new_pending = state.pending_notifications ++ [{summary, :alert}]
      {:noreply, %{state | pending_notifications: new_pending}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:clear_activity_log, state) do
    clear_log_file()
    {:noreply, %{state | activity_log: []}}
  end

  @impl true
  def handle_info(:hourly_reset, state) do
    schedule_hourly_reset()
    {:noreply, %{state | message_count_this_hour: 0}}
  end

  @impl true
  def handle_info(:delivery_check, state) do
    schedule_delivery_check()
    state = deliver_pending(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:autonomous_result, alert_message, result}, state) do
    case result do
      {:ok, _response} ->
        summary = "Autonomous fix for: #{String.slice(alert_message, 0, 60)}"
        state = log_activity(state, "autonomous_complete", summary)
        new_pending = state.pending_notifications ++ [{summary, :work_complete}]
        {:noreply, %{state | pending_notifications: new_pending}}

      {:error, reason} ->
        summary = "Autonomous fix failed: #{String.slice(to_string(reason), 0, 60)}"
        state = log_activity(state, "autonomous_failed", summary)
        new_pending = state.pending_notifications ++ [{summary, :work_failed}]
        {:noreply, %{state | pending_notifications: new_pending}}
    end
  end

  # ── Autonomous Dispatch ─────────────────────────────────────────

  defp maybe_dispatch_autonomous(alert, state) do
    # Budget check
    budget_ok =
      try do
        case MiosaBudget.Budget.check_budget() do
          :ok -> true
          _ -> false
        end
      rescue
        _ -> true
      catch
        :exit, _ -> true
      end

    if budget_ok do
      parent = self()

      Task.Supervisor.start_child(Daemon.Events.TaskSupervisor, fn ->
        try do
          session_id = "proactive_#{System.system_time(:second)}"

          result =
            Daemon.Agent.Loop.process_message(
              session_id,
              "PROACTIVE ALERT (#{alert.severity}): #{alert.message}\n\nInvestigate and take corrective action.",
              permission_tier: state.autonomous_permission_tier
            )

          send(parent, {:autonomous_result, alert.message, result})
        rescue
          e ->
            send(parent, {:autonomous_result, alert.message, {:error, Exception.message(e)}})
        end
      end)

      log_activity(state, "autonomous_started", "Dispatching autonomous fix for: #{alert.message}")
    else
      log_activity(state, "autonomous_skipped", "Budget exceeded — skipped: #{alert.message}")
    end
  end

  # ── Scheduler Event Handlers ────────────────────────────────────

  defp register_scheduler_handlers do
    Bus.register_handler(:system_event, fn payload ->
      # Bus wraps payloads in CloudEvent envelope — data is in payload.data
      data = Map.get(payload, :data, payload)

      case data do
        %{event: :cron_job_completed, job_name: name} ->
          notify("Cron job completed: #{name}", :work_complete)

        %{event: :cron_job_failed, job_name: name, reason: reason} ->
          notify("Cron job failed: #{name} — #{reason}", :work_failed)

        %{event: :heartbeat_task_completed, task: task} ->
          notify("Heartbeat task done: #{String.slice(task, 0, 60)}", :work_complete)

        %{event: :trigger_fired, trigger_name: name} ->
          notify("Trigger fired: #{name}", :info)

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  # ── Delivery ────────────────────────────────────────────────────

  defp deliver_pending(%{pending_notifications: []} = state), do: state

  defp deliver_pending(%{active_session: nil} = state), do: state

  defp deliver_pending(state) do
    if can_send?(state) do
      case state.pending_notifications do
        [{message, type} | rest] ->
          Bus.emit(:system_event, %{
            event: :proactive_message,
            session_id: state.active_session,
            message: message,
            message_type: type
          })

          now = System.monotonic_time(:millisecond)

          %{
            state
            | pending_notifications: rest,
              message_count_this_hour: state.message_count_this_hour + 1,
              last_message_at: now
          }

        [] ->
          state
      end
    else
      state
    end
  end

  defp can_send?(state) do
    count_ok = state.message_count_this_hour < state.max_messages_per_hour

    interval_ok =
      case state.last_message_at do
        nil -> true
        last -> System.monotonic_time(:millisecond) - last >= @min_message_interval_ms
      end

    count_ok and interval_ok
  end

  # ── Greeting ────────────────────────────────────────────────────

  defp build_greeting(_session_id, state) do
    hour = DateTime.utc_now().hour

    time_greeting =
      cond do
        hour < 12 -> "Good morning"
        hour < 18 -> "Good afternoon"
        true -> "Good evening"
      end

    # "While you were away" summary
    recent = last_session_activity(state)
    recent_count = length(recent)

    activity_note =
      if recent_count > 0 do
        types =
          recent
          |> Enum.frequencies_by(fn e -> e["type"] end)
          |> Enum.map(fn {type, count} -> "#{count} #{type}" end)
          |> Enum.join(", ")

        " While you were away: #{types}. Type /activity to review."
      else
        ""
      end

    # Scheduler status hint
    scheduler_hint =
      try do
        status = Scheduler.status()

        parts =
          [
            if(status.cron_active > 0, do: "#{status.cron_active} cron jobs"),
            if(status.heartbeat_pending > 0, do: "#{status.heartbeat_pending} pending heartbeat tasks"),
            if(status.trigger_active > 0, do: "#{status.trigger_active} triggers")
          ]
          |> Enum.reject(&is_nil/1)

        if parts != [], do: " Active: #{Enum.join(parts, ", ")}.", else: ""
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end

    "#{time_greeting}.#{activity_note}#{scheduler_hint}"
  end

  defp last_session_activity(state) do
    # Get activity since last session file was modified
    sessions_dir =
      Application.get_env(:daemon, :sessions_dir, "~/.daemon/sessions")
      |> Path.expand()

    last_session_time =
      if File.dir?(sessions_dir) do
        sessions_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn f ->
          case File.stat(Path.join(sessions_dir, f), time: :posix) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> 0
          end
        end)
        |> Enum.max(fn -> 0 end)
        |> then(fn
          0 -> DateTime.add(DateTime.utc_now(), -86400, :second)
          ts -> DateTime.from_unix!(ts)
        end)
      else
        DateTime.add(DateTime.utc_now(), -86400, :second)
      end

    Enum.filter(state.activity_log, fn entry ->
      case DateTime.from_iso8601(entry["ts"] || "") do
        {:ok, ts, _} -> DateTime.compare(ts, last_session_time) == :gt
        _ -> false
      end
    end)
  rescue
    _ -> []
  end

  # ── Activity Logging ────────────────────────────────────────────

  defp log_activity(state, type, message) do
    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => type,
      "message" => message
    }

    new_log = [entry | state.activity_log] |> Enum.take(@max_activity_log)
    append_to_log_file(entry)
    %{state | activity_log: new_log}
  end

  # ── Config Persistence ──────────────────────────────────────────

  defp read_config_enabled do
    config_path = config_file_path()

    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} -> Map.get(config, "proactive_mode", false)
          _ -> false
        end

      _ ->
        Application.get_env(:daemon, :proactive_mode, false)
    end
  end

  defp persist_config(enabled) do
    config_path = config_file_path()

    config =
      case File.read(config_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, existing} -> existing
            _ -> %{}
          end

        _ ->
          %{}
      end

    updated = Map.put(config, "proactive_mode", enabled)
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode!(updated, pretty: true))
  rescue
    e -> Logger.warning("[ProactiveMode] Failed to persist config: #{Exception.message(e)}")
  end

  defp config_file_path do
    config_dir = Application.get_env(:daemon, :config_dir, "~/.daemon")
    Path.expand(Path.join(config_dir, "config.json"))
  end

  # ── Activity Log Persistence ────────────────────────────────────

  defp log_file_path do
    data_dir = Application.get_env(:daemon, :data_dir, "~/.daemon/data")
    Path.expand(Path.join(data_dir, @log_file))
  end

  defp load_activity_log do
    path = log_file_path()

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, entry} -> [entry | acc]
          _ -> acc
        end
      end)
      |> Enum.take(@max_activity_log)
    else
      []
    end
  rescue
    _ -> []
  end

  defp append_to_log_file(entry) do
    path = log_file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
  rescue
    e -> Logger.debug("[ProactiveMode] Log write failed: #{Exception.message(e)}")
  end

  defp clear_log_file do
    File.rm(log_file_path())
  rescue
    _ -> :ok
  end

  # ── Scheduling ──────────────────────────────────────────────────

  defp schedule_hourly_reset do
    Process.send_after(self(), :hourly_reset, :timer.hours(1))
  end

  defp schedule_delivery_check do
    Process.send_after(self(), :delivery_check, 5_000)
  end
end
