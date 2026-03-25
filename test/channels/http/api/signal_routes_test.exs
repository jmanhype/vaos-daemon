defmodule Daemon.Channels.HTTP.API.SignalRoutesTest do
  use ExUnit.Case, async: true

  alias Daemon.Signal.Persistence
  alias Daemon.Channels.HTTP.API.SignalRoutes

  @signal_attrs %{
    channel: "http",
    mode: "execute",
    genre: "direct",
    type: "request",
    format: "command",
    weight: 0.7,
    session_id: "route_test_#{:erlang.unique_integer([:positive])}",
    input_preview: "test route signal",
    confidence: "high"
  }

  setup do
    Persistence.persist_signal(@signal_attrs)
    :ok
  end

  describe "GET /" do
    test "returns 200 with JSON array" do
      conn = call_route(:get, "/")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
    end

    test "supports mode filter" do
      conn = call_route(:get, "/?mode=execute")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
      assert Enum.all?(body, &(&1["mode"] == "execute"))
    end

    test "supports limit and offset" do
      conn = call_route(:get, "/?limit=1&offset=0")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body) <= 1
    end
  end

  describe "GET /stats" do
    test "returns stats object" do
      conn = call_route(:get, "/stats")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "total")
      assert Map.has_key?(body, "avg_weight")
      assert Map.has_key?(body, "by_mode")
      assert Map.has_key?(body, "by_channel")
      assert Map.has_key?(body, "by_tier")
    end
  end

  describe "GET /patterns" do
    test "returns patterns object" do
      conn = call_route(:get, "/patterns")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "avg_weight")
      assert Map.has_key?(body, "top_agents")
      assert Map.has_key?(body, "peak_hours")
      assert Map.has_key?(body, "daily_counts")
    end
  end

  describe "GET /unknown" do
    test "returns 404" do
      conn = call_route(:get, "/unknown")
      assert conn.status == 404
    end
  end

  defp call_route(method, path) do
    conn = Plug.Test.conn(method, path)
    SignalRoutes.call(conn, SignalRoutes.init([]))
  end
end
