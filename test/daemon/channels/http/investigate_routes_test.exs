defmodule Daemon.Channels.HTTP.API.InvestigateRoutesTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts Daemon.Channels.HTTP.API.InvestigateRoutes.init([])

  describe "POST /" do
    test "requires topic parameter" do
      conn =
        conn(:post, "/", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "Missing required field: topic"
    end

    test "rejects empty topic" do
      conn =
        conn(:post, "/", Jason.encode!(%{"topic" => ""}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "Missing required field: topic"
    end

    test "returns investigation_id for valid request" do
      conn =
        conn(:post, "/", Jason.encode!(%{"topic" => "test claim"}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 202

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "started"
      assert response["topic"] == "test claim"
      assert response["investigation_id"] =~ ~r/^inv_[a-f0-9]{16}$/
      assert Map.has_key?(response, "depth")
    end

    test "accepts optional depth parameter" do
      conn =
        conn(:post, "/", Jason.encode!(%{"topic" => "test claim", "depth" => "deep"}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 202

      response = Jason.decode!(conn.resp_body)
      assert response["depth"] == "deep"
    end

    test "defaults to standard depth when not provided" do
      conn =
        conn(:post, "/", Jason.encode!(%{"topic" => "test claim"}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 202

      response = Jason.decode!(conn.resp_body)
      assert response["depth"] == "standard"
    end
  end

  describe "GET /stream/:investigation_id" do
    test "returns SSE connection" do
      investigation_id = "inv_test1234567890"

      # Note: This test will start the SSE loop but won't receive events
      # since no investigation is actually running. We're just testing
      # that the endpoint sets up the SSE connection correctly.
      conn =
        conn(:get, "/stream/#{investigation_id}")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      # The connection should be chunked (SSE)
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  describe "catch-all route" do
    test "returns 404 for unknown routes" do
      conn =
        conn(:get, "/unknown")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 404
      assert conn.resp_body =~ "not_found"
    end
  end
end
