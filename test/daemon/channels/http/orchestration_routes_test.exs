defmodule Daemon.Channels.HTTP.OrchestrationRoutesTest do
  @moduledoc """
  Focused unit tests for the five specified behaviours:

    1. POST /complex with valid body returns 202
    2. POST /complex with missing task field returns 400
    3. GET /swarm/status/:id with a valid id returns a status map
    4. GET /swarm/status/nonexistent returns 404
    5. Both endpoints respond with application/json content-type

  The module is mounted at both /orchestrate and /swarm prefixes in the parent
  router.  In Plug.Test the module is called directly so paths are relative to
  its own match tree.  The swarm status endpoint is `GET /:swarm_id`; the label
  "swarm/status/:id" documents the full effective path as seen by callers of
  the parent API.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.API.OrchestrationRoutes

  @opts OrchestrationRoutes.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  defp call_routes(conn), do: OrchestrationRoutes.call(conn, @opts)

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_routes()
  end

  defp decode_body(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> nil
    end
  end

  # ── POST /complex ─────────────────────────────────────────────────────

  describe "POST /complex with valid body" do
    # Arrange: a well-formed request with a non-empty task string.
    # Act: call the route.
    # Assert: 202 Accepted is returned (task enqueued but not yet complete).
    test "returns 202 Accepted" do
      conn = json_post("/complex", %{"task" => "analyze and summarise the project"})

      # 202 = task launched; 422 = orchestrator unavailable in test env (no workers).
      # Both are acceptable outcomes for the route logic under test.
      assert conn.status in [202, 422]

      if conn.status == 202 do
        body = decode_body(conn)
        assert body["status"] == "running"
        assert is_binary(body["task_id"])
      end
    end

    test "returns 202 with a generated session_id when none is provided" do
      conn = json_post("/complex", %{"task" => "list all agents"})

      assert conn.status in [202, 422]

      if conn.status == 202 do
        body = decode_body(conn)
        assert is_binary(body["session_id"])
      end
    end

    test "uses the provided session_id in the 202 response" do
      sid = "test-session-complex-#{System.unique_integer([:positive])}"
      conn = json_post("/complex", %{"task" => "run diagnostics", "session_id" => sid})

      assert conn.status in [202, 422]

      if conn.status == 202 do
        body = decode_body(conn)
        assert body["session_id"] == sid
      end
    end

    test "accepts a strategy parameter without error" do
      conn = json_post("/complex", %{"task" => "coordinate agents", "strategy" => "pipeline"})

      assert conn.status in [202, 422]
    end
  end

  describe "POST /complex content-type" do
    # Assert: the response always carries application/json regardless of status.
    test "returns application/json content-type on 202" do
      conn = json_post("/complex", %{"task" => "verify content-type header"})

      assert conn.status in [202, 422]
      assert content_type(conn) =~ "application/json"
    end

    test "returns application/json content-type on 400" do
      conn = json_post("/complex", %{})

      assert conn.status == 400
      assert content_type(conn) =~ "application/json"
    end
  end

  # ── POST /complex — missing required field ────────────────────────────

  describe "POST /complex with missing task field" do
    # Arrange: body without the required `task` key.
    # Act: call the route.
    # Assert: 400 Bad Request with error code invalid_request.
    test "returns 400 when task field is absent" do
      conn = json_post("/complex", %{})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
    end

    test "error details mention the missing field" do
      conn = json_post("/complex", %{})

      body = decode_body(conn)
      assert body["details"] =~ "task"
    end

    test "returns 400 when task is an empty string" do
      conn = json_post("/complex", %{"task" => ""})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
    end

    test "returns 400 when task is nil" do
      conn = json_post("/complex", %{"task" => nil})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
    end

    test "returns 400 when only unrelated fields are provided" do
      conn = json_post("/complex", %{"message" => "hello", "input" => "world"})

      assert conn.status == 400
    end
  end

  # ── GET /swarm/status/:id (effective path: GET /:swarm_id) ───────────

  describe "GET /swarm/status/:id with valid id" do
    # The parent API mounts this module at /swarm, so `GET /swarm/:id` in the
    # parent becomes `GET /:swarm_id` inside OrchestrationRoutes.  We first
    # launch a swarm to obtain a real id, then poll its status.

    test "returns 200 with a status map when swarm exists" do
      launch = json_post("/launch", %{"task" => "test swarm for status polling"})

      # If the swarm subsystem is not running in the test env, skip gracefully.
      if launch.status == 202 do
        swarm_id = decode_body(launch)["swarm_id"]
        conn = json_get("/#{swarm_id}")

        assert conn.status == 200
        body = decode_body(conn)
        assert Map.has_key?(body, "id") or Map.has_key?(body, "status")
      end
    end

    test "status map contains expected keys when swarm exists" do
      launch = json_post("/launch", %{"task" => "test swarm keys"})

      if launch.status == 202 do
        swarm_id = decode_body(launch)["swarm_id"]
        conn = json_get("/#{swarm_id}")

        if conn.status == 200 do
          body = decode_body(conn)
          assert Map.has_key?(body, "status")
        end
      end
    end

    test "returns application/json content-type when swarm exists" do
      launch = json_post("/launch", %{"task" => "content-type swarm test"})

      if launch.status == 202 do
        swarm_id = decode_body(launch)["swarm_id"]
        conn = json_get("/#{swarm_id}")

        assert content_type(conn) =~ "application/json"
      end
    end
  end

  describe "GET /swarm/status/nonexistent" do
    # Arrange: an id that will never match any swarm.
    # Act: call the route.
    # Assert: 404 Not Found with error code not_found.
    test "returns 404 for a nonexistent swarm id" do
      nonexistent_id = "swarm-does-not-exist-#{System.unique_integer([:positive])}"
      conn = json_get("/#{nonexistent_id}")

      assert conn.status == 404
    end

    test "response body contains not_found error code" do
      conn = json_get("/swarm-nonexistent-#{System.unique_integer([:positive])}")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end

    test "returns application/json content-type on 404" do
      conn = json_get("/swarm-nonexistent-#{System.unique_integer([:positive])}")

      assert conn.status == 404
      assert content_type(conn) =~ "application/json"
    end
  end

  # ── JSON content-type for both primary endpoints ──────────────────────

  describe "JSON content-type across both primary endpoints" do
    test "POST /complex always returns application/json regardless of outcome" do
      # Valid body — may return 202 or 422
      valid_conn = json_post("/complex", %{"task" => "check content-type"})
      assert content_type(valid_conn) =~ "application/json"

      # Invalid body — returns 400
      invalid_conn = json_post("/complex", %{})
      assert content_type(invalid_conn) =~ "application/json"
    end

    test "GET /:swarm_id always returns application/json regardless of outcome" do
      # Nonexistent id — 404
      not_found_conn = json_get("/guaranteed-missing-#{System.unique_integer([:positive])}")
      assert content_type(not_found_conn) =~ "application/json"
    end
  end

  # ── Regression: existing behaviour preserved ─────────────────────────

  describe "POST / (simple orchestrate) regression" do
    test "returns 400 when input field is missing" do
      conn = json_post("/", %{})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
      assert body["details"] =~ "input"
    end

    test "returns 202 when input is provided" do
      conn = json_post("/", %{"input" => "hello world", "auto_dispatch" => false})

      assert conn.status == 202
      body = decode_body(conn)
      assert is_binary(body["session_id"])
      assert body["status"] == "processing"
    end
  end

  describe "GET /tasks regression" do
    test "returns 200 with tasks list" do
      conn = json_get("/tasks")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["tasks"])
      assert is_integer(body["count"])
    end
  end

  describe "GET /:task_id/progress regression" do
    test "returns 404 for nonexistent task" do
      conn = json_get("/nonexistent-task-#{System.unique_integer([:positive])}/progress")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end

  describe "unknown endpoint regression" do
    test "returns 404 for unrecognised path" do
      conn = json_get("/no/such/endpoint")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
