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
  end

  describe "match _ (catch-all)" do
    test "returns 404 for unknown path" do
      conn = json_get("/nonexistent")
      assert conn.status == 404
    end
  end
end
