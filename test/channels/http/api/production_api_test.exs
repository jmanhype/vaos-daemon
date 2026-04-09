defmodule Daemon.Channels.HTTP.API.ProductionAPITest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Production.API
  alias Daemon.Production.ComfyUISceneRunner

  @opts API.init([])

  setup do
    pid = Process.whereis(ComfyUISceneRunner) || start_supervised!(ComfyUISceneRunner)
    %{runner: pid}
  end

  defp call(conn), do: API.call(conn, @opts)

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call()
  end

  defp json_get(path) do
    conn(:get, path)
    |> call()
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /comfyui/run" do
    test "returns 400 for invalid brief" do
      conn = json_post("/comfyui/run", %{})

      assert conn.status == 400
      assert decode(conn)["error"] =~ "non-empty scenes list"
    end
  end

  describe "POST /comfyui/benchmark/run" do
    test "returns 400 for invalid benchmark brief" do
      conn = json_post("/comfyui/benchmark/run", %{})

      assert conn.status == 400
      assert decode(conn)["error"] =~ "workflow_path"
    end
  end

  describe "GET /comfyui/status" do
    test "returns idle status when nothing is running" do
      conn = json_get("/comfyui/status")

      assert conn.status == 200
      body = decode(conn)
      assert body["state"] == "idle"
      assert body["outputs"] == []
    end
  end

  describe "POST /comfyui/abort" do
    test "returns aborted response even when idle" do
      conn = json_post("/comfyui/abort", %{})

      assert conn.status == 200
      assert decode(conn)["status"] == "aborted"
    end
  end
end
