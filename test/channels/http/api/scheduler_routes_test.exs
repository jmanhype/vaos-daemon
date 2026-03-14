defmodule OptimalSystemAgent.Channels.HTTP.API.SchedulerRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SchedulerRoutes

  @opts SchedulerRoutes.init([])

  defp call_routes(conn) do
    SchedulerRoutes.call(conn, @opts)
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_routes()
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "GET /presets" do
    test "returns 8 cron presets" do
      conn = json_get("/presets")
      assert conn.status == 200

      body = decode_body(conn)
      assert body["status"] == "ok"
      assert length(body["presets"]) == 8

      preset = List.first(body["presets"])
      assert is_binary(preset["id"])
      assert is_binary(preset["cron"])
      assert is_binary(preset["label"])
    end
  end

  describe "match _" do
    test "returns 404 for unknown endpoint" do
      conn = json_get("/nonexistent/path")
      assert conn.status == 404

      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
