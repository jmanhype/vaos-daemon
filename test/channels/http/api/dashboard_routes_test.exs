defmodule Daemon.Channels.HTTP.API.DashboardRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.API.DashboardRoutes

  @opts DashboardRoutes.init([])

  defp json_get(path) do
    conn(:get, path)
    |> DashboardRoutes.call(@opts)
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "GET / (dashboard summary)" do
    test "returns 200 with expected shape" do
      conn = json_get("/")
      assert conn.status == 200

      body = decode_body(conn)
      assert is_map(body["kpis"])
      assert is_list(body["active_agents"])
      assert is_list(body["recent_activity"])
      assert is_map(body["system_health"])
      assert is_map(body["adaptation"])
    end

    test "kpis contains expected keys" do
      conn = json_get("/")
      body = decode_body(conn)
      kpis = body["kpis"]

      assert Map.has_key?(kpis, "active_sessions")
      assert Map.has_key?(kpis, "agents_online")
      assert Map.has_key?(kpis, "agents_total")
      assert Map.has_key?(kpis, "tokens_used_today")
      assert Map.has_key?(kpis, "uptime_seconds")
    end

    test "system_health contains backend status" do
      conn = json_get("/")
      body = decode_body(conn)
      health = body["system_health"]

      assert health["backend"] in ["ok", "degraded", "error"]
      assert Map.has_key?(health, "memory_mb")
    end

    test "adaptation contains dashboard-facing journal and signal state" do
      conn = json_get("/")
      body = decode_body(conn)
      adaptation = body["adaptation"]

      assert adaptation["journal"]["status"] in ["running", "inactive"]
      assert is_number(adaptation["journal"]["signal_count"])
      assert is_number(adaptation["journal"]["in_flight_count"])

      assert is_map(adaptation["meta_state"])
      assert Map.has_key?(adaptation["meta_state"], "authority_domain")
      assert Map.has_key?(adaptation["meta_state"], "active_bottleneck")
      assert Map.has_key?(adaptation["meta_state"], "pivot_reason")
      assert Map.has_key?(adaptation["meta_state"], "active_steering_hypothesis")
      assert Map.has_key?(adaptation["meta_state"], "recent_failed_count")

      assert is_list(adaptation["recent_signals"])
      assert Map.has_key?(adaptation, "current_trial")
      assert is_list(adaptation["active_promotions"])
      assert is_list(adaptation["active_suppressions"])
    end
  end

  describe "match _ (catch-all)" do
    test "returns 404 for unknown path" do
      conn = json_get("/nonexistent")
      assert conn.status == 404
    end
  end
end
