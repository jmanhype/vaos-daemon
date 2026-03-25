defmodule Daemon.Channels.HTTP.API.AgentStateRoutesTest do
  @moduledoc """
  Tests for AgentStateRoutes.

  Covers:
    1. GET /state         — existing full snapshot still works
    2. GET /state/summary — new compact summary endpoint
       a. returns 200 with application/json content-type
       b. response contains all required top-level keys
       c. active_sessions and tools_count are non-negative integers
       d. status is "active" or "idle"
       e. last_messages is a list
       f. memory_mb is a non-negative number
       g. uptime_seconds is a non-negative integer
    3. Unknown path returns 404
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.API.AgentStateRoutes

  @opts AgentStateRoutes.init([])

  # ── Helpers ─────────────────────────────────────────────────────────

  defp call(conn), do: AgentStateRoutes.call(conn, @opts)

  defp json_get(path) do
    conn(:get, path)
    |> call()
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> nil
    end
  end

  # ── GET /state (existing endpoint regression) ────────────────────────

  describe "GET /state" do
    test "returns 200" do
      conn = json_get("/state")
      assert conn.status == 200
    end

    test "returns application/json" do
      conn = json_get("/state")
      assert content_type(conn) =~ "application/json"
    end

    test "response body is a JSON object" do
      conn = json_get("/state")
      body = decode(conn)
      assert is_map(body)
    end
  end

  # ── GET /state/summary ───────────────────────────────────────────────

  describe "GET /state/summary status and content-type" do
    test "returns 200" do
      conn = json_get("/state/summary")
      assert conn.status == 200
    end

    test "returns application/json content-type" do
      conn = json_get("/state/summary")
      assert content_type(conn) =~ "application/json"
    end
  end

  describe "GET /state/summary response shape" do
    setup do
      conn = json_get("/state/summary")
      {:ok, body: Jason.decode!(conn.resp_body)}
    end

    test "contains active_sessions key", %{body: body} do
      assert Map.has_key?(body, "active_sessions")
    end

    test "contains tools_count key", %{body: body} do
      assert Map.has_key?(body, "tools_count")
    end

    test "contains current_provider key", %{body: body} do
      assert Map.has_key?(body, "current_provider")
    end

    test "contains current_model key", %{body: body} do
      assert Map.has_key?(body, "current_model")
    end

    test "contains memory_mb key", %{body: body} do
      assert Map.has_key?(body, "memory_mb")
    end

    test "contains uptime_seconds key", %{body: body} do
      assert Map.has_key?(body, "uptime_seconds")
    end

    test "contains last_messages key", %{body: body} do
      assert Map.has_key?(body, "last_messages")
    end

    test "contains status key", %{body: body} do
      assert Map.has_key?(body, "status")
    end

    test "contains timestamp key", %{body: body} do
      assert Map.has_key?(body, "timestamp")
    end
  end

  describe "GET /state/summary value types" do
    setup do
      conn = json_get("/state/summary")
      {:ok, body: Jason.decode!(conn.resp_body)}
    end

    test "active_sessions is a non-negative integer", %{body: body} do
      val = body["active_sessions"]
      assert is_integer(val)
      assert val >= 0
    end

    test "tools_count is a non-negative integer", %{body: body} do
      val = body["tools_count"]
      assert is_integer(val)
      assert val >= 0
    end

    test "current_provider is a non-empty string", %{body: body} do
      val = body["current_provider"]
      assert is_binary(val)
      assert val != ""
    end

    test "current_model is a non-empty string", %{body: body} do
      val = body["current_model"]
      assert is_binary(val)
      assert val != ""
    end

    test "memory_mb is a non-negative number", %{body: body} do
      val = body["memory_mb"]
      assert is_number(val)
      assert val >= 0
    end

    test "uptime_seconds is a non-negative integer", %{body: body} do
      val = body["uptime_seconds"]
      assert is_integer(val)
      assert val >= 0
    end

    test "last_messages is a list", %{body: body} do
      assert is_list(body["last_messages"])
    end

    test "status is 'active' or 'idle'", %{body: body} do
      assert body["status"] in ["active", "idle"]
    end
  end

  describe "GET /state/summary status reflects session count" do
    test "status is idle when no active sessions" do
      # In the test environment the SessionRegistry is not running,
      # so count_sessions/0 returns 0 and status must be 'idle'.
      conn = json_get("/state/summary")
      body = decode(conn)
      sessions = body["active_sessions"]

      if sessions == 0 do
        assert body["status"] == "idle"
      else
        assert body["status"] == "active"
      end
    end
  end

  # ── Unknown path ─────────────────────────────────────────────────────

  describe "unknown path" do
    test "returns 404" do
      conn = json_get("/nonexistent")
      assert conn.status == 404
    end

    test "returns application/json on 404" do
      conn = json_get("/nonexistent")
      assert content_type(conn) =~ "application/json"
    end

    test "error body contains not_found" do
      conn = json_get("/nonexistent")
      body = decode(conn)
      assert body["error"] == "not_found"
    end
  end
end
