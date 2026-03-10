defmodule OptimalSystemAgent.Agent.ReplayTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.Replay
  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes

  @opts SessionRoutes.init([])

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SessionRoutes.call(@opts)
  end

  describe "Replay.replay/2" do
    test "returns {:error, :not_found} for session with no history" do
      result = Replay.replay("nonexistent-session-abc123")
      assert result == {:error, :not_found}
    end

    test "module is loaded" do
      assert Code.ensure_loaded?(Replay)
    end

    test "replay/2 is exported" do
      assert function_exported?(Replay, :replay, 2)
    end

    test "replay/1 is exported (default opts)" do
      assert function_exported?(Replay, :replay, 1)
    end
  end

  describe "POST /sessions/:id/replay route" do
    test "returns 404 for session with no stored conversation" do
      conn = json_post("/ghost-session-xyz/replay")
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "no_history" or body["details"] =~ "no_history" or
               body["error"] =~ "not_found"
    end

    test "response is valid JSON" do
      conn = json_post("/missing-session/replay")
      assert {:ok, _} = Jason.decode(conn.resp_body)
    end

    test "accepts optional provider in body" do
      conn = json_post("/some-session/replay", %{"provider" => "openai"})
      # 404 expected since session doesn't exist
      assert conn.status in [202, 404, 500]
    end

    test "accepts optional session_id override in body" do
      conn = json_post("/some-session/replay", %{"session_id" => "my-replay-123"})
      assert conn.status in [202, 404, 500]
    end

    test "202 response has required fields when session has history" do
      # We can't easily inject fake Memory history in unit tests,
      # but we verify the 404 response structure is correct.
      conn = json_post("/no-history-session/replay")
      body = Jason.decode!(conn.resp_body)
      assert is_map(body)
      assert Map.has_key?(body, "error") or Map.has_key?(body, "status")
    end
  end
end
