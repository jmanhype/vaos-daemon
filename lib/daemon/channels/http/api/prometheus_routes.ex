defmodule Daemon.Channels.HTTP.API.PrometheusRoutes do
  @moduledoc """
  Prometheus metrics exporter for monitoring dashboards.

  Exposes metrics in Prometheus text format at /metrics endpoint.

  Metrics collected:
    - daemon_up — process uptime
    - daemon_info — build version and git SHA
    - daemon_sessions_total — total session count
    - daemon_agents_total — total agents registered
    - daemon_agents_online — agents currently online
    - daemon_agents_unreachable — agents currently unreachable
    - daemon_fleet_instances_total — total OS instances in fleet
    - daemon_fleet_agents_total — total agents across fleet
    - daemon_tool_executions_total — tool calls by name
    - daemon_tool_duration_ms — tool execution duration histograms
    - daemon_provider_calls_total — LLM provider calls by provider
    - daemon_provider_latency_ms — provider latency histograms
    - daemon_provider_errors_total — provider error count
    - daemon_tokens_total — token usage (input/output)
    - daemon_noise_filter_rate — noise filter percentage
    - daemon_command_center_tasks_total — tasks in command center

  All metrics include standard labels (instance, job) from Prometheus scrape config.
  """

  use Plug.Router
  require Logger

  alias Daemon.Telemetry.Metrics
  alias Daemon.Fleet.Dashboard
  alias Daemon.CommandCenter
  alias Daemon.Agent.Roster

  plug :match
  plug :dispatch

  # ── GET /metrics — Prometheus scrape endpoint ───────────────────────

  get "/" do
    metrics = render_prometheus_metrics()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  # ── GET /health — simple health check for Prometheus blackbox ────────

  get "/health" do
    body = Jason.encode!(%{status: "ok", timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Metrics Rendering ─────────────────────────────────────────────────

  defp render_prometheus_metrics do
    []
    |> add_info_metrics()
    |> add_uptime_metrics()
    |> add_session_metrics()
    |> add_agent_metrics()
    |> add_fleet_metrics()
    |> add_tool_metrics()
    |> add_provider_metrics()
    |> add_token_metrics()
    |> add_noise_filter_metrics()
    |> add_command_center_metrics()
    |> Enum.join("\n")
  end

  # ── Info Metrics ─────────────────────────────────────────────────────

  defp add_info_metrics(lines) do
    version = version_string()
    git_sha = git_sha_string()

    lines ++
      [
        "# HELP daemon_info Build and version information.",
        "# TYPE daemon_info gauge",
        "daemon_info{version=\"#{version}\",git_sha=\"#{git_sha}\"} 1"
      ]
  end

  defp add_uptime_metrics(lines) do
    uptime_seconds = uptime_seconds()

    lines ++
      [
        "",
        "# HELP daemon_up Process uptime in seconds.",
        "# TYPE daemon_up gauge",
        "daemon_up #{uptime_seconds}"
      ]
  end

  # ── Session Metrics ──────────────────────────────────────────────────

  defp add_session_metrics(lines) do
    telemetry = Metrics.get_metrics()
    session_stats = Map.get(telemetry, :session_stats, %{})

    sessions_today = Map.get(session_stats, :sessions_today, 0)
    messages_today = Map.get(session_stats, :messages_today, 0)
    turns_by_session = Map.get(session_stats, :turns_by_session, %{})
    active_sessions = map_size(turns_by_session)

    lines ++
      [
        "",
        "# HELP daemon_sessions_active Number of currently active sessions.",
        "# TYPE daemon_sessions_active gauge",
        "daemon_sessions_active #{active_sessions}",
        "",
        "# HELP daemon_sessions_total Total sessions created today.",
        "# TYPE daemon_sessions_total counter",
        "daemon_sessions_total #{sessions_today}",
        "",
        "# HELP daemon_messages_total Total messages processed today.",
        "# TYPE daemon_messages_total counter",
        "daemon_messages_total #{messages_today}"
      ]
  end

  # ── Agent Metrics ────────────────────────────────────────────────────

  defp add_agent_metrics(lines) do
    all_agents = Roster.all()
    total_agents = map_size(all_agents)

    online_agents =
      all_agents
      |> Map.values()
      |> Enum.count(fn agent ->
        Map.get(agent, :status) == :online
      end)

    unreachable_agents =
      all_agents
      |> Map.values()
      |> Enum.count(fn agent ->
        Map.get(agent, :status) == :unreachable
      end)

    lines ++
      [
        "",
        "# HELP daemon_agents_total Total number of registered agents.",
        "# TYPE daemon_agents_total gauge",
        "daemon_agents_total #{total_agents}",
        "",
        "# HELP daemon_agents_online Number of agents currently online.",
        "# TYPE daemon_agents_online gauge",
        "daemon_agents_online #{online_agents}",
        "",
        "# HELP daemon_agents_unreachable Number of unreachable agents.",
        "# TYPE daemon_agents_unreachable gauge",
        "daemon_agents_unreachable #{unreachable_agents}"
      ]
  end

  # ── Fleet Metrics ────────────────────────────────────────────────────

  defp add_fleet_metrics(lines) do
    if fleet_enabled?() do
      try do
        overview = Dashboard.overview()
        fleet = Map.get(overview, :fleet, %{})

        instances_total = Map.get(fleet, :total_instances, 0)
        fleet_agents_total = Map.get(fleet, :total_agents, 0)
        fleet_agents_online = Map.get(fleet, :agents_online, 0)
        fleet_agents_unreachable = Map.get(fleet, :agents_unreachable, 0)

        lines ++
          [
            "",
            "# HELP daemon_fleet_instances_total Total OS instances in fleet.",
            "# TYPE daemon_fleet_instances_total gauge",
            "daemon_fleet_instances_total #{instances_total}",
            "",
            "# HELP daemon_fleet_agents_total Total agents across fleet.",
            "# TYPE daemon_fleet_agents_total gauge",
            "daemon_fleet_agents_total #{fleet_agents_total}",
            "",
            "# HELP daemon_fleet_agents_online Fleet agents currently online.",
            "# TYPE daemon_fleet_agents_online gauge",
            "daemon_fleet_agents_online #{fleet_agents_online}",
            "",
            "# HELP daemon_fleet_agents_unreachable Unreachable fleet agents.",
            "# TYPE daemon_fleet_agents_unreachable gauge",
            "daemon_fleet_agents_unreachable #{fleet_agents_unreachable}"
          ]
      catch
        _, _ -> lines
      end
    else
      lines
    end
  end

  # ── Tool Metrics ─────────────────────────────────────────────────────

  defp add_tool_metrics(lines) do
    telemetry = Metrics.get_metrics()
    tool_executions = Map.get(telemetry, :tool_executions, %{})
    summary = Metrics.get_summary()
    tool_stats = Map.get(summary, :tool_executions, %{})

    # Counter metrics for total calls
    counter_lines =
      tool_executions
      |> Enum.map(fn {tool_name, _stats} ->
        count = Map.get(tool_stats, tool_name, %{}) |> Map.get(:count, 0)
        "daemon_tool_executions_total{tool_name=\"#{escape_label(tool_name)}\"} #{count}"
      end)

    # Histogram metrics for duration (avg, min, max, p99)
    histogram_lines =
      tool_stats
      |> Enum.flat_map(fn {tool_name, stats} ->
        [
          "",
          "# HELP daemon_tool_duration_ms Tool execution duration in milliseconds.",
          "# TYPE daemon_tool_duration_ms summary",
          "daemon_tool_duration_ms{tool_name=\"#{escape_label(tool_name)}\",quantile=\"0.5\"} #{Map.get(stats, :avg_ms, 0)}",
          "daemon_tool_duration_ms{tool_name=\"#{escape_label(tool_name)}\",quantile=\"0.99\"} #{Map.get(stats, :p99_ms, 0)}",
          "daemon_tool_duration_ms_sum{tool_name=\"#{escape_label(tool_name)}\"} #{Map.get(stats, :avg_ms, 0) * Map.get(stats, :count, 0)}",
          "daemon_tool_duration_ms_count{tool_name=\"#{escape_label(tool_name)}\"} #{Map.get(stats, :count, 0)}"
        ]
      end)

    if Enum.empty?(counter_lines) do
      lines
    else
      lines ++
        [
          "",
          "# HELP daemon_tool_executions_total Total tool execution count by tool.",
          "# TYPE daemon_tool_executions_total counter"
        ] ++ counter_lines ++ histogram_lines
    end
  end

  # ── Provider Metrics ─────────────────────────────────────────────────

  defp add_provider_metrics(lines) do
    telemetry = Metrics.get_metrics()
    summary = Metrics.get_summary()

    provider_calls = Map.get(telemetry, :provider_calls, %{})
    provider_errors = Map.get(telemetry, :provider_errors, %{})
    provider_latency = Map.get(summary, :provider_latency, %{})

    # Counter metrics
    calls_lines =
      provider_calls
      |> Enum.map(fn {provider, count} ->
        provider_name = to_string(provider)
        "daemon_provider_calls_total{provider=\"#{escape_label(provider_name)}\"} #{count}"
      end)

    errors_lines =
      provider_errors
      |> Enum.map(fn {provider, count} ->
        provider_name = to_string(provider)
        "daemon_provider_errors_total{provider=\"#{escape_label(provider_name)}\"} #{count}"
      end)

    # Histogram metrics for latency
    latency_lines =
      provider_latency
      |> Enum.flat_map(fn {provider, stats} ->
        provider_name = to_string(provider)

        [
          "",
          "# HELP daemon_provider_latency_ms LLM provider latency in milliseconds.",
          "# TYPE daemon_provider_latency_ms summary",
          "daemon_provider_latency_ms{provider=\"#{escape_label(provider_name)}\",quantile=\"0.5\"} #{Map.get(stats, :avg_ms, 0)}",
          "daemon_provider_latency_ms{provider=\"#{escape_label(provider_name)}\",quantile=\"0.99\"} #{Map.get(stats, :p99_ms, 0)}",
          "daemon_provider_latency_ms_sum{provider=\"#{escape_label(provider_name)}\"} #{Map.get(stats, :avg_ms, 0) * Map.get(stats, :count, 0)}",
          "daemon_provider_latency_ms_count{provider=\"#{escape_label(provider_name)}\"} #{Map.get(stats, :count, 0)}"
        ]
      end)

    if Enum.empty?(calls_lines) and Enum.empty?(errors_lines) do
      lines
    else
      lines ++
        [
          "",
          "# HELP daemon_provider_calls_total Total LLM provider calls.",
          "# TYPE daemon_provider_calls_total counter"
        ] ++ calls_lines ++
        [
          "",
          "# HELP daemon_provider_errors_total Total LLM provider errors.",
          "# TYPE daemon_provider_errors_total counter"
        ] ++ errors_lines ++ latency_lines
    end
  end

  # ── Token Metrics ────────────────────────────────────────────────────

  defp add_token_metrics(lines) do
    telemetry = Metrics.get_metrics()
    token_stats = Map.get(telemetry, :token_stats, %{})

    input_tokens = Map.get(token_stats, :input_tokens, 0)
    output_tokens = Map.get(token_stats, :output_tokens, 0)

    lines ++
      [
        "",
        "# HELP daemon_tokens_total Total tokens consumed.",
        "# TYPE daemon_tokens_total counter",
        "daemon_tokens_total{type=\"input\"} #{input_tokens}",
        "daemon_tokens_total{type=\"output\"} #{output_tokens}"
      ]
  end

  # ── Noise Filter Metrics ─────────────────────────────────────────────

  defp add_noise_filter_metrics(lines) do
    summary = Metrics.get_summary()
    filter_rate = Map.get(summary, :noise_filter_rate, 0.0)

    lines ++
      [
        "",
        "# HELP daemon_noise_filter_rate Percentage of messages filtered by noise filter.",
        "# TYPE daemon_noise_filter_rate gauge",
        "daemon_noise_filter_rate #{filter_rate}"
      ]
  end

  # ── Command Center Metrics ───────────────────────────────────────────

  defp add_command_center_metrics(lines) do
    try do
      summary = CommandCenter.dashboard_summary()

      active_tasks =
        summary
        |> Map.get(:tasks, %{})
        |> Map.get(:active, 0)

      completed_tasks =
        summary
        |> Map.get(:tasks, %{})
        |> Map.get(:completed, 0)

      lines ++
        [
          "",
          "# HELP daemon_command_center_tasks_total Task counts in command center.",
          "# TYPE daemon_command_center_tasks_total gauge",
          "daemon_command_center_tasks_total{status=\"active\"} #{active_tasks}",
          "daemon_command_center_tasks_total{status=\"completed\"} #{completed_tasks}"
        ]
    catch
      _, _ -> lines
    end
  end

  # ── Utility Functions ────────────────────────────────────────────────

  defp fleet_enabled? do
    Application.get_env(:daemon, :fleet_enabled, false)
  end

  defp version_string do
    case Application.get_env(:daemon, :version) do
      nil -> "dev"
      version when is_binary(version) -> version
      _ -> "unknown"
    end
  end

  defp git_sha_string do
    case Application.get_env(:daemon, :git_sha) do
      nil -> "unknown"
      sha when is_binary(sha) -> String.slice(sha, 0, 7)
      _ -> "unknown"
    end
  end

  defp uptime_seconds do
    case Application.get_env(:daemon, :start_time) do
      nil -> 0
      start_time when is_integer(start_time) ->
        System.system_time(:second) - start_time
      _ -> 0
    end
  end

  # Escape label values according to Prometheus text format
  defp escape_label(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp escape_label(value), do: escape_label(to_string(value))
end
