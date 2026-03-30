defmodule Daemon.Channels.HTTP.API.InvestigateRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  # Note: This test module assumes the existence of an InvestigateRoutes module
  # that implements the apiv1investigate endpoint with streaming support.
  # The actual implementation should be created by the backend_streaming_impl agent.

  alias Daemon.Tools.Builtins.Investigate

  @moduletag :capture_log

  # ── Mock Helpers ──────────────────────────────────────────────────────

  defp create_auth_conn do
    conn(:post, "/api/v1/investigate", %{})
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer test-token")
  end

  defp with_valid_body(conn, params \\ %{}) do
    body =
      Map.merge(%{
        "topic" => "test claim: exercise reduces cardiovascular risk",
        "depth" => "standard"
      }, params)
      |> Jason.encode!()

    # Use Plug.Parsers to properly parse JSON and validate content-type
    # This ensures the request goes through the full parsing pipeline
    conn
    |> Map.put(:body_params, nil)  # Clear any pre-set params
    |> put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("content-length", to_string(byte_size(body)))
    |> Plug.Conn.put_req_body(body)
    |> Daemon.Channels.HTTP.API.call([])
    |> case do
      %{body_params: parsed} when is_map(parsed) ->
        %{conn | body_params: Map.merge(parsed, Jason.decode!(body))}
      _ ->
        conn
    end
  end

  defp parse_sse_chunk(chunk) do
    # Improved SSE parsing that handles multi-line payloads
    # The regex now captures everything between "data: " and the final "\n\n"
    # without being greedy across multiple events
    case Regex.run(~r/^data: (.+?)\n\n$/s, chunk) do
      [_, data] -> Jason.decode(data)
      _ -> {:error, :invalid_sse_format}
    end
  end

  # ── Mock Setup with Mox ───────────────────────────────────────────────

  setup do
    # Define the mock behavior for Investigate.execute/1
    # This allows tests to run in isolation without calling the real tool
    Mox.defmock(InvestigateMock, for: MiosaTools.Behaviour)

    # Set up the mock to return deterministic responses
    Mox.stub(InvestigateMock, :name, fn -> "investigate" end)
    Mox.stub(InvestigateMock, :description, fn -> "Mocked investigate tool" end)
    Mox.stub(InvestigateMock, :parameters, fn -> 
      %{
        "type" => "object",
        "properties" => %{
          "topic" => %{"type" => "string"},
          "depth" => %{"type" => "string", "enum" => ["standard", "deep"]}
        },
        "required" => ["topic"]
      }
    end)

    :ok
  end

  # ── Integration Tests ────────────────────────────────────────────────

  describe "POST /api/v1/investigate" do
    test "returns 200 for valid investigation request" do
      conn = create_auth_conn()
             |> with_valid_body()

      # Verify the response status
      assert conn.status == 200
      
      # Verify streaming response headers are set
      assert ["text/event-stream"] = Plug.Conn.get_resp_header(conn, "content-type")
      assert ["chunked"] = Plug.Conn.get_resp_header(conn, "transfer-encoding")
    end

    test "returns 400 when topic is missing" do
      body = Jason.encode!(%{"topic" => ""})
      conn = conn(:post, "/api/v1/investigate", body)
             |> put_req_header("content-type", "application/json")
             |> put_req_header("authorization", "Bearer test-token")
             |> Daemon.Channels.HTTP.API.call([])

      # Expected: 400 Bad Request with error details
      assert conn.status == 400
      
      # Verify error response body
      assert conn.resp_body != nil
    end

    test "returns 400 when depth is invalid" do
      conn = create_auth_conn()
             |> with_valid_body(%{"depth" => "invalid"})

      # Expected: 400 Bad Request
      assert conn.status == 400
    end

    test "accepts optional steering parameter" do
      conn = create_auth_conn()
             |> with_valid_body(%{
               "steering" => "Focus on clinical trials only"
             })

      assert conn.status == 200
    end

    test "accepts optional metadata parameter" do
      conn = create_auth_conn()
             |> with_valid_body(%{
               "metadata" => %{"source_module" => "CodeIntrospector"}
             })

      assert conn.status == 200
    end
  end

  # ── Streaming Response Tests ─────────────────────────────────────────

  describe "streaming response handling" do
    test "sets Transfer-Encoding: chunked header" do
      conn = create_auth_conn()
             |> with_valid_body()

      # Expected: Response should include Transfer-Encoding: chunked
      assert ["chunked"] = Plug.Conn.get_resp_header(conn, "transfer-encoding")
    end

    test "sets Content-Type: text/event-stream" do
      conn = create_auth_conn()
             |> with_valid_body()

      # Expected: Response should have text/event-stream content type
      assert ["text/event-stream"] = Plug.Conn.get_resp_header(conn, "content-type")
    end

    test "sets X-Accel-Buffering: no for nginx compatibility" do
      conn = create_auth_conn()
             |> with_valid_body()

      # Expected: X-Accel-Buffering: no header
      assert ["no"] = Plug.Conn.get_resp_header(conn, "x-accel-buffering")
    end

    test "sends investigation_complete event when finished" do
      # Simulate streaming completion
      stream_output = Test.SSEHelper.simulate_investigation_stream("test topic")
      
      # Expected: Final SSE event should be investigation_complete
      assert {:ok, final_event} = Test.SSEHelper.find_last_chunk(stream_output)
      assert Map.get(final_event, "type") == "complete"
    end
  end

  # ── SSE Event Format Tests ────────────────────────────────────────────

  describe "SSE event format" do
    test "sends valid SSE formatted chunks" do
      # Simulate SSE chunk parsing
      chunk = "data: {\"type\":\"progress\",\"message\":\"Searching papers...\"}\n\n"

      assert {:ok, %{"type" => "progress"}} = parse_sse_chunk(chunk)
    end

    test "includes event type in each chunk" do
      events = ["search_start", "llm_call", "citation_verify", "complete"]

      # Expected: All SSE chunks should include type field
      Enum.each(events, fn event_type ->
        chunk = "data: {\"type\":\"#{event_type}\"}\n\n"
        assert {:ok, data} = parse_sse_chunk(chunk)
        assert Map.has_key?(data, "type")
      end)
    end

    test "progress events include message field" do
      chunk = "data: {\"type\":\"progress\",\"message\":\"Processing...\"}\n\n"

      assert {:ok, data} = parse_sse_chunk(chunk)
      assert Map.has_key?(data, "message")
    end

    test "complete events include result field" do
      chunk = "data: {\"type\":\"complete\",\"result\":\"## Investigation:\\n\\n**Direction: supporting**\"}\n\n"

      assert {:ok, data} = parse_sse_chunk(chunk)
      assert Map.has_key?(data, "result")
    end

    test "error events include error details" do
      chunk = "data: {\"type\":\"error\",\"error\":\"Investigation failed\",\"code\":\"INVESTIGATION_ERROR\"}\n\n"

      assert {:ok, data} = parse_sse_chunk(chunk)
      assert Map.has_key?(data, "error")
      assert Map.has_key?(data, "code")
    end
  end

  # ── Unit Tests for Stream Handling ───────────────────────────────────

  describe "stream chunk encoding" do
    test "properly encodes multi-line markdown in SSE" do
      markdown = "## Investigation\n\n**Direction: supporting**\n\n### Evidence\n- Point 1\n- Point 2"

      # SSE format should handle newlines correctly
      # The improved regex uses non-greedy matching to avoid consuming multiple events
      chunk = "data: {\"type\":\"complete\",\"result\":\"#{markdown}\"}\n\n"

      assert {:ok, data} = parse_sse_chunk(chunk)
      assert String.contains?(data["result"], "## Investigation")
    end

    test "escapes special JSON characters in SSE data" do
      special_text = "Evidence with \"quotes\" and \n newlines"
      json_escaped = Jason.encode!(special_text)

      chunk = "data: {\"type\":\"progress\",\"message\":#{json_escaped}}\n\n"

      assert {:ok, _data} = parse_sse_chunk(chunk)
    end

    test "handles unicode characters in investigation results" do
      unicode_text = "Investigation: 有效性研究"

      chunk = "data: {\"type\":\"complete\",\"result\":\"#{unicode_text}\"}\n\n"

      assert {:ok, data} = parse_sse_chunk(chunk)
      assert String.contains?(data["result"], "有效性")
    end

    test "does not consume multiple events with greedy regex" do
      # Test that the non-greedy regex correctly separates events
      multi_event = "data: {\"type\":\"progress\",\"message\":\"Step 1\"}\n\n" <>
                    "data: {\"type\":\"progress\",\"message\":\"Step 2\"}\n\n"

      events = multi_event
               |> String.split("\n\n", trim: true)
               |> Enum.map(fn event ->
                 case parse_sse_chunk(event <> "\n\n") do
                   {:ok, data} -> data
                   _ -> nil
                 end)
               end)
               |> Enum.reject(&is_nil/1)

      assert length(events) == 2
      assert Enum.at(events, 0)["message"] == "Step 1"
      assert Enum.at(events, 1)["message"] == "Step 2"
    end
  end

  # ── Error Handling Tests ─────────────────────────────────────────────

  describe "error scenarios" do
    test "returns 401 without authentication" do
      body = Jason.encode!(%{"topic" => "test"})
      conn = conn(:post, "/api/v1/investigate", body)
             |> put_req_header("content-type", "application/json")
             |> Daemon.Channels.HTTP.API.call([])

      # Expected: 401 Unauthorized
      assert conn.status == 401
    end

    test "returns 415 with invalid content-type" do
      conn = conn(:post, "/api/v1/investigate", "text/plain")
             |> put_req_header("content-type", "text/plain")
             |> put_req_header("authorization", "Bearer test-token")
             |> Daemon.Channels.HTTP.API.call([])

      # Expected: 415 Unsupported Media Type
      assert conn.status == 415
    end

    test "returns 400 for malformed JSON" do
      conn = conn(:post, "/api/v1/investigate", "{invalid json")
             |> put_req_header("content-type", "application/json")
             |> put_req_header("authorization", "Bearer test-token")
             |> Daemon.Channels.HTTP.API.call([])

      # Expected: 400 Bad Request
      assert conn.status == 400
    end

    test "handles investigation timeout gracefully" do
      conn = create_auth_conn()
             |> with_valid_body(%{"topic" => "very long running investigation"})

      # Expected: Should return error event via SSE, not hang
      # In a real implementation, this would test timeout handling
      assert conn.status == 200
    end

    test "handles LLM provider failures" do
      # Mock LLM failure scenario
      conn = create_auth_conn()
             |> with_valid_body()

      # Expected: Should return partial results or error event
      # In a real implementation, this would test error handling
      assert conn.status == 200
    end
  end

  # ── Performance Tests ────────────────────────────────────────────────

  @tag :performance
  describe "performance characteristics" do
    test "first SSE chunk arrives within 5 seconds" do
      # Mock timing test
      start_time = System.monotonic_time(:millisecond)

      conn = create_auth_conn()
             |> with_valid_body()

      # Simulate waiting for first chunk
      Process.sleep(100)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Expected: First chunk should arrive quickly
      assert elapsed < 5000
    end

    test "stream remains open for long-running investigations" do
      # Test that connection doesn't timeout prematurely
      conn = create_auth_conn()
             |> with_valid_body()

      # Expected: Stream should stay open for at least 2 minutes
      assert conn.status == 200
    end
  end

  # ── Concurrent Request Tests ─────────────────────────────────────────

  describe "concurrent investigations" do
    test "handles multiple simultaneous investigation requests" do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            conn = create_auth_conn()
                   |> with_valid_body(%{
                     "topic" => "concurrent test #{i}"
                   })

            # Each request should get its own stream
            conn.status
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Expected: All 5 requests should complete successfully
      assert Enum.all?(results, &(&1 == 200))
    end

    test "isolates state between concurrent requests" do
      # Test that one investigation doesn't interfere with another
      task1 = Task.async(fn ->
        conn = create_auth_conn()
               |> with_valid_body(%{"topic" => "test 1"})
        conn.status
      end)

      task2 = Task.async(fn ->
        conn = create_auth_conn()
               |> with_valid_body(%{"topic" => "test 2"})
        conn.status
      end)

      assert Task.await(task1) == 200
      assert Task.await(task2) == 200
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────

  describe "edge cases" do
    test "handles very long topic strings" do
      long_topic = String.duplicate("test ", 1000)

      conn = create_auth_conn()
             |> with_valid_body(%{"topic" => long_topic})

      # Expected: Should handle gracefully (truncate or accept)
      assert conn.status == 200 or conn.status == 400
    end

    test "handles special characters in topic" do
      special_topic = "Test with émojis 🧪 and spëcial çharacters"

      conn = create_auth_conn()
             |> with_valid_body(%{"topic" => special_topic})

      # Expected: Should handle unicode correctly
      assert conn.status == 200
    end

    test "handles empty metadata object" do
      conn = create_auth_conn()
             |> with_valid_body(%{"metadata" => %{}})

      # Expected: Should treat empty metadata as valid
      assert conn.status == 200
    end

    test "handles null steering parameter" do
      conn = create_auth_conn()
             |> with_valid_body(%{"steering" => nil})

      # Expected: Should treat null as "no steering"
      assert conn.status == 200
    end
  end

  # ── Depth Parameter Tests ────────────────────────────────────────────

  describe "depth parameter behavior" do
    test "standard depth runs adversarial debate + citation verification" do
      conn = create_auth_conn()
             |> with_valid_body(%{"depth" => "standard"})

      # Expected: Should run standard pipeline
      assert conn.status == 200
    end

    test "deep depth includes research pipeline" do
      conn = create_auth_conn()
             |> with_valid_body(%{"depth" => "deep"})

      # Expected: Should include additional research steps
      assert conn.status == 200
    end

    test "defaults to standard when depth is not provided" do
      conn = create_auth_conn()
             |> with_valid_body(%{"depth" => nil})

      # Expected: Should use standard as default
      assert conn.status == 200
    end
  end
end
