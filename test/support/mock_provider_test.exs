defmodule Daemon.Test.MockProviderTest do
  use ExUnit.Case, async: true

  alias Daemon.Test.MockProvider

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    # Ensure clean state for each test
    MockProvider.reset()
    :ok
  end

  # ── Backward compatibility ────────────────────────────────────────────────

  describe "backward compatibility" do
    test "chat/2 returns tool_call on first call, text on second" do
      # First call: tool_call
      {:ok, result1} = MockProvider.chat([], [])
      assert result1.content == ""
      assert length(result1.tool_calls) == 1
      assert hd(result1.tool_calls).name == "memory_recall"

      # Second call: plain text
      {:ok, result2} = MockProvider.chat([], [])
      assert result2.content == "Mock final answer from OSA."
      assert result2.tool_calls == []
    end

    test "chat_stream/3 simulates streaming on first call, text on second" do
      # First call: tool_call
      acc1 = MockProvider.chat_stream([], fn msg -> send(self(), {:stream, msg}) end, [])
      assert acc1 == :ok
      assert_receive {:stream, {:done, %{tool_calls: [_]}}}

      # Second call: streaming text then done
      acc2 = MockProvider.chat_stream([], fn msg -> send(self(), {:stream, msg}) end, [])
      assert acc2 == :ok
      assert_receive {:stream, {:text_delta, "Mock final answer from OSA."}}
      assert_receive {:stream, {:done, %{content: "Mock final answer from OSA."}}}
    end

    test "reset/0 clears state" do
      # Make a call to set state
      {:ok, _} = MockProvider.chat([], [])

      # Reset
      MockProvider.reset()

      # Should be back to initial state (tool_call)
      {:ok, result} = MockProvider.chat([], [])
      assert length(result.tool_calls) == 1
    end
  end

  # ── set_responses/1 ──────────────────────────────────────────────────────

  describe "set_responses/1" do
    test "returns responses in sequence" do
      responses = [
        {:ok, %{content: "First", tool_calls: []}},
        {:ok, %{content: "Second", tool_calls: []}},
        {:ok, %{content: "Third", tool_calls: []}}
      ]

      MockProvider.set_responses(responses)

      {:ok, r1} = MockProvider.chat([], [])
      {:ok, r2} = MockProvider.chat([], [])
      {:ok, r3} = MockProvider.chat([], [])

      assert r1.content == "First"
      assert r2.content == "Second"
      assert r3.content == "Third"
    end

    test "returns tool_call responses" do
      responses = [
        {:ok, %{
          content: "",
          tool_calls: [
            %{id: "1", name: "bash", arguments: %{"command" => "ls -la"}},
            %{id: "2", name: "file_read", arguments: %{"path" => "/tmp/file"}}
          ]
        }}
      ]

      MockProvider.set_responses(responses)

      {:ok, result} = MockProvider.chat([], [])
      assert length(result.tool_calls) == 2
      assert Enum.at(result.tool_calls, 0).name == "bash"
      assert Enum.at(result.tool_calls, 1).name == "file_read"
    end

    test "handles 5+ turns" do
      # Create 5 responses
      responses =
        for i <- 1..5 do
          {:ok, %{content: "Response #{i}", tool_calls: []}}
        end

      MockProvider.set_responses(responses)

      # Make 5 calls
      for i <- 1..5 do
        {:ok, result} = MockProvider.chat([], [])
        assert result.content == "Response #{i}"
      end
    end

    test "falls back to default after responses exhausted" do
      MockProvider.set_responses([
        {:ok, %{content: "Custom", tool_calls: []}}
      ])

      # First call: custom response
      {:ok, r1} = MockProvider.chat([], [])
      assert r1.content == "Custom"

      # Second call: default behavior (tool_call)
      {:ok, r2} = MockProvider.chat([], [])
      assert length(r2.tool_calls) == 1

      # Third call: default behavior (text)
      {:ok, r3} = MockProvider.chat([], [])
      assert r3.content == "Mock final answer from OSA."
    end
  end

  # ── Error responses ───────────────────────────────────────────────────────

  describe "error responses" do
    test "returns error tuple when set" do
      MockProvider.set_responses([
        {:error, "API rate limit exceeded"}
      ])

      result = MockProvider.chat([], [])
      assert result == {:error, "API rate limit exceeded"}
    end

    test "mixes errors and successes" do
      MockProvider.set_responses([
        {:ok, %{content: "Success 1", tool_calls: []}},
        {:error, "Timeout"},
        {:ok, %{content: "Success 2", tool_calls: []}}
      ])

      {:ok, r1} = MockProvider.chat([], [])
      assert r1.content == "Success 1"

      assert MockProvider.chat([], []) == {:error, "Timeout"}

      {:ok, r3} = MockProvider.chat([], [])
      assert r3.content == "Success 2"
    end

    test "chat_stream/3 handles errors" do
      MockProvider.set_responses([
        {:error, "Connection failed"}
      ])

      acc = MockProvider.chat_stream([], fn msg -> send(self(), {:stream, msg}) end, [])
      assert acc == {:error, "Connection failed"}
      assert_receive {:stream, {:error, {:error, "Connection failed"}}}
    end
  end

  # ── Call logging ─────────────────────────────────────────────────────────

  describe "call logging" do
    test "call_log returns nil when logging not enabled" do
      MockProvider.chat([], [])
      assert MockProvider.call_log() == nil
    end

    test "call_count returns 0 when logging not enabled" do
      MockProvider.chat([], [])
      MockProvider.chat([], [])
      assert MockProvider.call_count() == 0
    end

    test "enable_logging starts tracking calls" do
      MockProvider.enable_logging()

      MockProvider.chat([], [])
      MockProvider.chat([], [])

      log = MockProvider.call_log()
      assert is_list(log)
      assert length(log) == 2
    end

    test "call_count returns number of calls" do
      MockProvider.enable_logging()

      MockProvider.chat([], [])
      MockProvider.chat([], [])
      MockProvider.chat([], [])

      assert MockProvider.call_count() == 3
    end

    test "log entries contain type, messages, opts, and timestamp" do
      MockProvider.enable_logging()

      MockProvider.chat([%{role: "user", content: "test"}], [model: "test"])

      [entry] = MockProvider.call_log()
      assert entry.type == :chat
      assert entry.messages == [%{role: "user", content: "test"}]
      assert entry.opts == [model: "test"]
      assert is_integer(entry.timestamp)
    end

    test "logs both chat and chat_stream calls" do
      MockProvider.enable_logging()

      MockProvider.chat([], [])
      MockProvider.chat_stream([], fn _ -> :ok end, [])

      log = MockProvider.call_log()
      assert length(log) == 2

      types = Enum.map(log, & &1.type)
      assert :chat in types
      assert :chat_stream in types
    end

    test "disable_logging stops tracking" do
      MockProvider.enable_logging()
      MockProvider.chat([], [])

      MockProvider.disable_logging()
      MockProvider.chat([], [])

      # Should only have logged the first call
      assert MockProvider.call_count() == 1
    end

    test "reset clears the log" do
      MockProvider.enable_logging()
      MockProvider.chat([], [])
      MockProvider.chat([], [])

      assert MockProvider.call_count() == 2

      MockProvider.reset()

      # Logging state is cleared, so count is 0
      assert MockProvider.call_count() == 0
    end
  end

  # ── Integration ──────────────────────────────────────────────────────────

  describe "integration scenarios" do
    test "complex workflow with 5+ turns and logging" do
      MockProvider.enable_logging()

      # Set up a multi-turn conversation
      MockProvider.set_responses([
        {:ok, %{
          content: "",
          tool_calls: [
            %{id: "1", name: "bash", arguments: %{"command" => "ls"}},
            %{id: "2", name: "bash", arguments: %{"command" => "pwd"}}
          ]
        }},
        {:ok, %{content: "tool results processed", tool_calls: []}},
        {:ok, %{
          content: "",
          tool_calls: [
            %{id: "3", name: "file_read", arguments: %{"path" => "README.md"}}
          ]
        }},
        {:ok, %{content: "file content analyzed", tool_calls: []}},
        {:ok, %{content: "Final answer with all information", tool_calls: []}}
      ])

      # Execute 5 turns
      for i <- 1..5 do
        {:ok, result} = MockProvider.chat([], [])
        assert is_map(result)
      end

      # Verify all calls were logged
      assert MockProvider.call_count() == 5

      log = MockProvider.call_log()
      assert length(log) == 5
    end

    test "error handling in workflow" do
      MockProvider.enable_logging()

      MockProvider.set_responses([
        {:ok, %{content: "Starting", tool_calls: []}},
        {:error, "API timeout"},
        {:ok, %{content: "Retried successfully", tool_calls: []}}
      ])

      {:ok, r1} = MockProvider.chat([], [])
      assert r1.content == "Starting"

      assert MockProvider.chat([], []) == {:error, "API timeout"}

      {:ok, r3} = MockProvider.chat([], [])
      assert r3.content == "Retried successfully"

      # All attempts should be logged
      assert MockProvider.call_count() == 3
    end
  end
end
