defmodule Test.SSEHelper do
  @moduledoc """
  Helper functions for testing Server-Sent Events (SSE) streams.

  Provides utilities to:
  - Parse SSE formatted chunks
  - Validate SSE event format
  - Simulate streaming responses
  - Assert on stream characteristics
  """

  @doc """
  Parse a single SSE chunk into its components.

  ## Examples

      iex> Test.SSEHelper.parse_sse_chunk("data: {\"type\":\"test\"}\\n\\n")
      {:ok, %{"type" => "test"}, "data"}

      iex> Test.SSEHelper.parse_sse_chunk("event: update\\ndata: {\"msg\":\"hi\"}\\n\\n")
      {:ok, %{"msg" => "hi"}, "update"}
  """
  def parse_sse_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn
      "", acc ->
        acc

      line, {data, event_type} ->
        cond do
          String.starts_with?(line, "data: ") ->
            json_data = String.replace_prefix(line, "data: "", "")
            case Jason.decode(json_data) do
              {:ok, parsed} -> {parsed, event_type}
              {:error, _} -> {data, event_type}
            end

          String.starts_with?(line, "event: ") ->
            event_name = String.replace_prefix(line, "event: "", "")
            {data, event_name}

          true ->
            {data, event_type}
        end
    end)
    |> case do
      {data, _event} when map_size(data) > 0 -> {:ok, data}
      _ -> {:error, :no_valid_data}
    end
  end

  @doc """
  Parse multiple SSE chunks from a stream.

  Returns a list of parsed events in order.
  """
  def parse_sse_stream(stream_string) when is_binary(stream_string) do
    stream_string
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_sse_chunk/1)
    |> Enum.filter(fn
      {:ok, _data} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, data} -> data end)
  end

  @doc """
  Assert that an SSE chunk includes required fields.
  """
  def assert_sse_fields(chunk, required_fields) when is_list(required_fields) do
    assert {:ok, data} = parse_sse_chunk(chunk)

    Enum.each(required_fields, fn field ->
      assert Map.has_key?(data, field),
             "SSE chunk missing required field: #{field}\nChunk: #{inspect(chunk)}"
    end)

    :ok
  end

  @doc """
  Assert that SSE chunk has specific event type.
  """
  def assert_sse_type(chunk, expected_type) when is_binary(expected_type) do
    assert {:ok, data} = parse_sse_chunk(chunk)

    actual_type = Map.get(data, "type")
    assert actual_type == expected_type,
           "Expected SSE type '#{expected_type}', got '#{actual_type}'\nChunk: #{inspect(chunk)}"

    :ok
  end

  @doc """
  Validate SSE format compliance.

  Checks that:
  - Each chunk ends with \n\n
  - data lines are prefixed with "data: "
  - Optional event lines are prefixed with "event: "
  """
  def validate_sse_format(chunk) when is_binary(chunk) do
    cond do
      not String.ends_with?(chunk, "\n\n") ->
        {:error, :missing_double_newline}

      not (String.contains?(chunk, "data: ") or chunk == "") ->
        {:error, :missing_data_prefix}

      true ->
        :ok
    end
  end

  @doc """
  Extract all chunks of a specific type from an SSE stream.
  """
  def filter_chunks_by_type(stream_string, type) when is_binary(type) do
    stream_string
    |> parse_sse_stream()
    |> Enum.filter(fn
      %{"type" => ^type} -> true
      _ -> false
    end)
  end

  @doc """
  Count chunks of a specific type in an SSE stream.
  """
  def count_chunks_by_type(stream_string, type) when is_binary(type) do
    stream_string
    |> filter_chunks_by_type(type)
    |> length()
  end

  @doc """
  Find the last (final) chunk in an SSE stream.

  Useful for asserting completion events.
  """
  def find_last_chunk(stream_string) do
    stream_string
    |> parse_sse_stream()
    |> List.last()
  end

  @doc """
  Simulate a streaming response for testing.

  Generates a mock SSE stream with the provided events.
  """
  def simulate_sse_stream(events) when is_list(events) do
    events
    |> Enum.map(fn event ->
      event_type = Map.get(event, :type, "message")
      data = Map.get(event, :data, %{})

      json = Jason.encode!(data)

      if event_type == "message" do
        "data: #{json}\n\n"
      else
        "event: #{event_type}\ndata: #{json}\n\n"
      end
    end)
    |> Enum.join()
  end

  @doc """
  Assert chunked transfer encoding headers are present.

  Validates that a Plug.Conn has the correct headers for SSE streaming.
  """
  def assert_chunked_headers(conn) do
    # Check for Transfer-Encoding: chunked
    transfer_encoding = Plug.Conn.get_resp_header(conn, "transfer-encoding")
    assert ["chunked"] = transfer_encoding,
           "Expected Transfer-Encoding: chunked, got: #{inspect(transfer_encoding)}"

    # Check for Content-Type: text/event-stream
    content_type = Plug.Conn.get_resp_header(conn, "content-type")
    assert ["text/event-stream"] = content_type,
           "Expected Content-Type: text/event-stream, got: #{inspect(content_type)}"

    # Check for X-Accel-Buffering: no (nginx compatibility)
    accel_buffering = Plug.Conn.get_resp_header(conn, "x-accel-buffering")
    assert ["no"] = accel_buffering,
           "Expected X-Accel-Buffering: no, got: #{inspect(accel_buffering)}"

    :ok
  end

  @doc """
  Measure time to first chunk in a stream.

  Useful for performance testing to ensure first chunk arrives quickly.
  """
  def time_to_first_chunk(stream_fun) when is_function(stream_fun, 0) do
    start = System.monotonic_time(:millisecond)

    # Start the stream
    stream_fun.()

    # In a real test, you'd need to await the first chunk
    # This is a placeholder for the timing logic
    System.monotonic_time(:millisecond) - start
  end

  @doc """
  Assert that stream completes within timeout.

  Takes a function that returns a stream and a timeout in milliseconds.
  """
  def assert_stream_completes_within(stream_fun, timeout_ms) when is_function(stream_fun, 0) do
    task = Task.async(stream_fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task)
        flunk("Stream did not complete within #{timeout_ms}ms")
    end
  end

  @doc """
  Parse investigation result from complete event.

  Extracts the investigation markdown result from an investigation_complete SSE event.
  """
  def extract_investigation_result(complete_event) when is_binary(complete_event) do
    case parse_sse_chunk(complete_event) do
      {:ok, %{"type" => "complete", "result" => result}} ->
        {:ok, result}

      {:ok, %{"type" => type}} ->
        {:error, {:unexpected_type, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Assert investigation result has required sections.

  Validates that an investigation result includes expected markdown sections.
  """
  def assert_investigation_sections(result, required_sections \\ []) do
    Enum.each(required_sections, fn section ->
      assert String.contains?(result, section),
             "Investigation result missing section: #{section}"
    end)

    :ok
  end

  @doc """
  Count evidence items in investigation result.

  Parses the markdown to count how many evidence items are listed.
  """
  def count_evidence_items(result) when is_binary(result) do
    # Count lines starting with "- [", which are evidence items
    result
    |> String.split("\n")
    |> Enum.count(fn line ->
      String.match?(line, ~r/^\s*-\s*\[.*?\]/)
    end)
  end

  @doc """
  Extract direction from investigation result.

  Parses the "Direction: X" line from the investigation markdown.
  """
  def extract_direction(result) when is_binary(result) do
    case Regex.run(~r/\*\*Direction: (.*?)\*\*/, result) do
      [_, direction] -> {:ok, String.trim(direction)}
      _ -> {:error, :direction_not_found}
    end
  end

  @doc """
  Validate VAOS_JSON metadata in investigation result.

  Ensures the result includes the embedded JSON metadata.
  """
  def assert_vaos_metadata(result) do
    assert String.contains?(result, "<!-- VAOS_JSON:")

    case Regex.run(~r/<!-- VAOS_JSON:(.*?) -->/s, result) do
      [_, json_str] ->
        assert {:ok, _metadata} = Jason.decode(String.trim(json_str))

      _ ->
        flunk("VAOS_JSON metadata not found in result")
    end

    :ok
  end

  @doc """
  Simulate streaming investigation for testing.

  Creates a mock SSE stream representing an investigation in progress.
  """
  def simulate_investigation_stream(topic \\ "test claim", steps \\ [:start, :search, :analyze, :complete]) do
    events =
      Enum.map(steps, fn step ->
        case step do
          :start ->
            %{
              type: "progress",
              message: "Starting investigation: #{topic}"
            }

          :search ->
            %{
              type: "progress",
              message: "Searching literature databases..."
            }

          :analyze ->
            %{
              type: "progress",
              message: "Running adversarial analysis..."
            }

          :complete ->
            %{
              type: "complete",
              result: "## Investigation: #{topic}\n\n**Direction: contested**\n\nAnalysis complete."
            }

          :error ->
            %{
              type: "error",
              error: "Investigation failed",
              code: "INVESTIGATION_ERROR"
            }
        end
      end)

    simulate_sse_stream(events)
  end

  @doc """
  Assert stream includes progress events.

  Verifies that an SSE stream contains at least one progress event.
  """
  def assert_has_progress_events(stream_string) do
    progress_count = count_chunks_by_type(stream_string, "progress")

    assert progress_count > 0,
           "Expected at least one progress event, found #{progress_count}"

    :ok
  end

  @doc """
  Assert stream completes successfully.

  Verifies that the last event in an SSE stream is a 'complete' event.
  """
  def assert_stream_completes(stream_string) do
    last_chunk = find_last_chunk(stream_string)

    assert last_chunk != nil, "Stream has no events"
    assert Map.get(last_chunk, "type") == "complete",
           "Expected last event to be 'complete', got '#{Map.get(last_chunk, "type")}'"

    :ok
  end
end
