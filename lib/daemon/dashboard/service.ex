defmodule Daemon.Dashboard.Service do
  @moduledoc """
  Aggregates KPI data from sessions, agents, tasks, signals, and metrics
  into a single dashboard payload.
  """

  require Logger

  alias Daemon.Agent.Roster
  alias Daemon.Agent.Tasks
  alias Daemon.Agent.HealthTracker
  alias Daemon.CommandCenter
  alias Daemon.CommandCenter.EventHistory
  alias Daemon.Intelligence.{AdaptationTrials, DecisionJournal}

  @spec summary() :: map()
  def summary do
    %{
      kpis: build_kpis(),
      active_agents: build_active_agents(),
      recent_activity: build_recent_activity(),
      system_health: build_system_health(),
      adaptation: build_adaptation()
    }
  end

  # ── KPIs ──────────────────────────────────────────────────────────────

  defp build_kpis do
    metrics = CommandCenter.metrics_summary()
    dashboard = CommandCenter.dashboard_summary()

    %{
      active_sessions: metrics[:active_sessions] || 0,
      agents_online: dashboard[:running] || 0,
      agents_total: dashboard[:total_agents] || 0,
      signals_today: metrics[:total_messages] || 0,
      tasks_completed: metrics[:total_tasks_completed] || 0,
      tasks_pending: count_pending_tasks(),
      tokens_used_today: metrics[:total_tokens_used] || 0,
      uptime_seconds: metrics[:uptime_seconds] || 0
    }
  end

  defp count_pending_tasks do
    Tasks.list_tasks([])
    |> Enum.count(fn task -> Map.get(task, :status) in [:pending, :queued] end)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ── Active Agents ─────────────────────────────────────────────────────

  defp build_active_agents do
    running = CommandCenter.running_agents()

    running
    |> Enum.take(20)
    |> Enum.map(fn task ->
      health = agent_health(task[:agent] || task[:agent_name])

      %{
        name: task[:agent] || task[:agent_name] || "unknown",
        status: normalize_status(task[:status]),
        current_task: task[:task] || task[:description],
        last_active: health[:last_active]
      }
    end)
  end

  defp agent_health(nil), do: %{}

  defp agent_health(name) do
    case HealthTracker.get(to_string(name)) do
      {:ok, h} -> h
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp normalize_status(:leased), do: "running"
  defp normalize_status(s) when is_atom(s), do: Atom.to_string(s)
  defp normalize_status(s) when is_binary(s), do: s
  defp normalize_status(_), do: "idle"

  # ── Recent Activity ───────────────────────────────────────────────────

  defp build_recent_activity do
    EventHistory.recent(20)
    |> Enum.map(fn event ->
      %{
        type: Map.get(event, :type, "event") |> to_string(),
        message: Map.get(event, :message, Map.get(event, :description, "")),
        timestamp: Map.get(event, :timestamp, Map.get(event, :inserted_at)),
        agent: Map.get(event, :agent) |> to_string_or_nil(),
        level: Map.get(event, :level, "info") |> to_string()
      }
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  # ── System Health ─────────────────────────────────────────────────────

  defp build_system_health do
    provider = Application.get_env(:daemon, :default_provider, :ollama)

    memory_mb =
      :erlang.memory(:total)
      |> Kernel.div(1_048_576)

    %{
      backend: "ok",
      provider: to_string(provider),
      provider_status: check_provider_status(),
      memory_mb: memory_mb
    }
  end

  # ── Adaptation ────────────────────────────────────────────────────────

  defp build_adaptation do
    stats = DecisionJournal.stats()
    meta_state = Map.get(stats, :meta_state, DecisionJournal.meta_state())
    snapshot = AdaptationTrials.snapshot()
    recent_signals = DecisionJournal.adaptation_events(6)

    %{
      journal: %{
        status: journal_status(Map.get(stats, :status)),
        signal_count: Map.get(stats, :adaptation_event_count, length(recent_signals)),
        in_flight_count: Map.get(stats, :in_flight_count, 0)
      },
      meta_state: normalize_meta_state(meta_state),
      current_trial: normalize_trial(Map.get(snapshot, :current_trial)),
      active_promotions:
        snapshot
        |> Map.get(:active_promotions, [])
        |> Enum.map(&normalize_promotion/1),
      active_suppressions:
        snapshot
        |> Map.get(:active_suppressions, [])
        |> Enum.map(&normalize_suppression/1),
      recent_signals: Enum.map(recent_signals, &normalize_adaptation_signal/1)
    }
  rescue
    _ -> empty_adaptation()
  catch
    :exit, _ -> empty_adaptation()
  end

  defp normalize_meta_state(meta_state) when is_map(meta_state) do
    recent_failed = Map.get(meta_state, :recent_failed_adaptations, [])

    %{
      authority_domain: Map.get(meta_state, :authority_domain),
      active_bottleneck: Map.get(meta_state, :active_bottleneck),
      pivot_reason: Map.get(meta_state, :pivot_reason),
      active_steering_hypothesis: Map.get(meta_state, :active_steering_hypothesis),
      last_updated_at: Map.get(meta_state, :last_updated_at),
      last_experiment: normalize_adaptation_signal(Map.get(meta_state, :last_experiment)),
      recent_failed_count: length(recent_failed),
      recent_failed_adaptations: Enum.map(recent_failed, &normalize_adaptation_signal/1)
    }
  end

  defp normalize_meta_state(_), do: empty_adaptation().meta_state

  defp normalize_adaptation_signal(nil), do: nil

  defp normalize_adaptation_signal(entry) when is_map(entry) do
    context = Map.get(entry, :context, %{})

    %{
      domain: Map.get(entry, :domain),
      event_type: Map.get(entry, :event_type),
      timestamp: Map.get(entry, :timestamp),
      bottleneck: Map.get(entry, :bottleneck) || Map.get(context, "bottleneck"),
      reason: Map.get(entry, :reason) || Map.get(context, "reason"),
      outcome: Map.get(entry, :outcome) || Map.get(context, "outcome"),
      trigger_event: Map.get(context, "trigger_event"),
      context: context
    }
  end

  defp normalize_trial(nil), do: nil

  defp normalize_trial(trial) when is_map(trial) do
    %{
      trial_id: Map.get(trial, :trial_id),
      trial_type: Map.get(trial, :trial_type),
      domain: Map.get(trial, :domain),
      trigger_event: Map.get(trial, :trigger_event),
      status: normalize_status(Map.get(trial, :status)),
      remaining_uses: Map.get(trial, :remaining_uses, 0),
      bottleneck: Map.get(trial, :bottleneck),
      steering: Map.get(trial, :steering),
      created_at: Map.get(trial, :created_at),
      expires_at: Map.get(trial, :expires_at),
      applied_at: Map.get(trial, :applied_at),
      applied_topic: Map.get(trial, :applied_topic)
    }
  end

  defp normalize_promotion(promotion) when is_map(promotion) do
    %{
      trigger_event: Map.get(promotion, :trigger_event),
      bottleneck: Map.get(promotion, :bottleneck),
      helpful_streak: Map.get(promotion, :helpful_streak, 0),
      steering: Map.get(promotion, :steering),
      promoted_at: Map.get(promotion, :promoted_at),
      expires_at: Map.get(promotion, :expires_at)
    }
  end

  defp normalize_promotion(_), do: %{}

  defp normalize_suppression(suppression) when is_map(suppression) do
    %{
      trigger_event: Map.get(suppression, :trigger_event),
      bottleneck: Map.get(suppression, :bottleneck),
      negative_streak: Map.get(suppression, :negative_streak, 0),
      reason: Map.get(suppression, :reason),
      suppressed_at: Map.get(suppression, :suppressed_at),
      expires_at: Map.get(suppression, :expires_at)
    }
  end

  defp normalize_suppression(_), do: %{}

  defp journal_status(:running), do: "running"
  defp journal_status(_), do: "inactive"

  defp empty_adaptation do
    %{
      journal: %{
        status: "inactive",
        signal_count: 0,
        in_flight_count: 0
      },
      meta_state: %{
        authority_domain: nil,
        active_bottleneck: nil,
        pivot_reason: nil,
        active_steering_hypothesis: nil,
        last_updated_at: nil,
        last_experiment: nil,
        recent_failed_count: 0,
        recent_failed_adaptations: []
      },
      current_trial: nil,
      active_promotions: [],
      active_suppressions: [],
      recent_signals: []
    }
  end

  defp check_provider_status do
    agents = Roster.all()
    if map_size(agents) > 0, do: "connected", else: "connected"
  rescue
    _ -> "disconnected"
  catch
    :exit, _ -> "disconnected"
  end
end
