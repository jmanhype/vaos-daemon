defmodule Daemon.Channels.HTTP.API.HealthRoutesTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts Daemon.Channels.HTTP.API.HealthRoutes.init([])

  describe "GET /api/v1/health" do
    test "returns health status with dependencies" do
      conn =
        conn(:get, "/")
        |> Daemon.Channels.HTTP.API.HealthRoutes.call(@opts)

      assert conn.state == :sent
      assert conn.status == 200

      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

      body = Jason.decode!(conn.resp_body)

      # Check top-level fields
      assert body["status"] in ["ok", "degraded"]
      assert is_binary(body["timestamp"])
      assert is_binary(body["version"])
      assert is_integer(body["uptime"])
      assert is_map(body["system"])
      assert is_map(body["dependencies"])
      assert is_map(body["resources"])

      # Check system info
      system = body["system"]
      assert is_binary(system["elixir"])
      assert is_binary(system["otp_release"])
      assert is_binary(system["provider"])
      assert is_binary(system["model"])

      # Check dependencies
      deps = body["dependencies"]
      assert is_map(deps["channels"])
      assert is_map(deps["services"])
      assert is_map(deps["external_apis"])

      # Check channels
      channels = deps["channels"]
      assert Map.has_key?(channels, "email")
      assert Map.has_key?(channels, "feishu")
      assert Map.has_key?(channels, "cli")
      assert Map.has_key?(channels, "http")

      # Check services
      services = deps["services"]
      assert Map.has_key?(services, "events_bus")
      assert Map.has_key?(services, "agent_loop")

      # Check resources
      resources = body["resources"]
      assert is_map(resources["memory"])
      assert is_map(resources["processes"])
      assert is_map(resources["ports"])

      memory = resources["memory"]
      assert is_integer(memory["total_mb"])
      assert is_integer(memory["process_mb"])

      processes = resources["processes"]
      assert is_integer(processes["count"])
      assert is_integer(processes["limit"])
    end
  end
end
