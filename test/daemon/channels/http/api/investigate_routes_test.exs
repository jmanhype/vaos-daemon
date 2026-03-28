defmodule Daemon.Channels.HTTP.API.InvestigateRoutesTest do
  @moduledoc """
  Tests for the /api/v1/investigate endpoint with streaming support.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.API.InvestigateRoutes

  @opts InvestigateRoutes.init([])

  describe "POST /investigate" do
    test "requires topic parameter" do
      conn =
        conn(:post, "/", %{})
        |> InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "Missing required field: topic"
    end

    test "rejects empty topic" do
      conn =
        conn(:post, "/", %{"topic" => ""})
        |> InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "topic must be a non-empty string"
    end

    test "validates depth parameter" do
      conn =
        conn(:post, "/", %{"topic" => "test", "depth" => "invalid"})
        |> InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "depth must be 'standard' or 'deep'"
    end

    test "accepts valid standard depth" do
      # This test verifies the connection setup - actual investigation
      # would require mocking the Investigate.execute function
      conn =
        conn(:post, "/", %{"topic" => "test topic", "depth" => "standard"})
        |> assign(:user_id, "test_user")
        |> InvestigateRoutes.call(@opts)

      # Connection should be set up for streaming (200 status with chunked response)
      assert conn.state == :chunked
      assert conn.status == 200
    end

    test "accepts valid deep depth" do
      conn =
        conn(:post, "/", %{"topic" => "test topic", "depth" => "deep"})
        |> assign(:user_id, "test_user")
        |> InvestigateRoutes.call(@opts)

      assert conn.state == :chunked
      assert conn.status == 200
    end

    test "defaults to standard depth" do
      conn =
        conn(:post, "/", %{"topic" => "test topic"})
        |> assign(:user_id, "test_user")
        |> InvestigateRoutes.call(@opts)

      assert conn.state == :chunked
      assert conn.status == 200
    end

    test "sets correct headers for SSE" do
      conn =
        conn(:post, "/", %{"topic" => "test"})
        |> assign(:user_id, "test_user")
        |> InvestigateRoutes.call(@opts)

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "connection") == ["keep-alive"]
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end
  end

  describe "extract_json_metadata/1" do
    test "extracts JSON from investigation result" do
      text = """
      Some text here
      <!-- VAOS_JSON:{"direction":"supporting","verified_for":5} -->
      More text
      """

      metadata = Daemon.Channels.HTTP.API.InvestigateRoutes.extract_json_metadata(text)

      assert metadata["direction"] == "supporting"
      assert metadata["verified_for"] == 5
    end

    test "returns empty map when no JSON found" do
      text = "Just plain text without metadata"

      metadata = Daemon.Channels.HTTP.API.InvestigateRoutes.extract_json_metadata(text)

      assert metadata == %{}
    end
  end
end
