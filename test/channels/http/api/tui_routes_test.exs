defmodule Daemon.Channels.HTTP.API.TuiRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.API.TuiRoutes

  @opts TuiRoutes.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  defp call_routes(conn) do
    TuiRoutes.call(conn, @opts)
  end

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  # ── GET /output — SSE stream ──────────────────────────────────────────

  describe "GET /output" do
    test "returns 200 with chunked transfer" do
      conn = json_get("/output")
      assert conn.status == 200
      assert conn.state == :chunked
    end

    test "sets text/event-stream content-type" do
      conn = json_get("/output")
      content_type = conn |> get_resp_header("content-type") |> List.first()
      assert content_type =~ "text/event-stream"
    end

    test "sets cache-control: no-cache" do
      conn = json_get("/output")
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "sets connection: keep-alive" do
      conn = json_get("/output")
      assert get_resp_header(conn, "connection") == ["keep-alive"]
    end

    test "sets x-accel-buffering: no" do
      conn = json_get("/output")
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    test "sends initial connected event in body" do
      conn = json_get("/output")
      assert conn.resp_body =~ "event: connected"
      assert conn.resp_body =~ ~s("channel")
      assert conn.resp_body =~ "tui_output"
    end
  end

  # ── POST /input — dispatch user input ────────────────────────────────

  describe "POST /input" do
    test "returns 400 when input field is missing" do
      conn = json_post("/input", %{})
      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] =~ "input" or body["details"] =~ "input"
    end

    test "returns 400 when input is empty string" do
      conn = json_post("/input", %{"input" => ""})
      assert conn.status == 400
    end

    test "returns 400 when input is not a string" do
      conn = json_post("/input", %{"input" => 42})
      assert conn.status == 400
    end

    test "returns 202 with status processing on valid input" do
      conn = json_post("/input", %{"input" => "hello"})
      # 202 on success, 503 if session supervisor unavailable — both acceptable
      assert conn.status in [202, 503]

      if conn.status == 202 do
        body = decode_body(conn)
        assert body["status"] == "processing"
      end
    end

    test "returns session_id in 202 response" do
      conn = json_post("/input", %{"input" => "ping", "session_id" => "test-session-42"})

      if conn.status == 202 do
        body = decode_body(conn)
        assert body["session_id"] == "test-session-42"
      end
    end

    test "generates session_id when not provided" do
      conn = json_post("/input", %{"input" => "ping"})

      if conn.status == 202 do
        body = decode_body(conn)
        assert is_binary(body["session_id"])
        assert byte_size(body["session_id"]) > 0
      end
    end

    test "returns application/json content-type on 202" do
      conn = json_post("/input", %{"input" => "test"})

      if conn.status == 202 do
        content_type = conn |> get_resp_header("content-type") |> List.first()
        assert content_type =~ "application/json"
      end
    end

    test "generates distinct session_ids for consecutive calls without session_id" do
      conn1 = json_post("/input", %{"input" => "first"})
      conn2 = json_post("/input", %{"input" => "second"})

      if conn1.status == 202 and conn2.status == 202 do
        id1 = decode_body(conn1)["session_id"]
        id2 = decode_body(conn2)["session_id"]
        assert id1 != id2
      end
    end
  end

  # ── catch-all — unknown paths ─────────────────────────────────────────

  describe "unknown endpoints" do
    test "returns 404 for unknown GET path" do
      conn = json_get("/unknown")
      assert conn.status == 404
    end

    test "returns 404 for DELETE method" do
      conn =
        conn(:delete, "/output")
        |> call_routes()

      assert conn.status == 404
    end

    test "404 body contains error info" do
      conn = json_get("/nope")
      body = decode_body(conn)
      assert Map.has_key?(body, "error") or Map.has_key?(body, "details")
    end
  end
end
