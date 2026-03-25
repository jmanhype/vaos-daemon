defmodule Daemon.Events.FailureModesTest do
  use ExUnit.Case, async: true

  alias MiosaSignal.Event
  alias MiosaSignal.FailureModes

  describe "detect/1" do
    test "returns empty list for a well-formed event" do
      event =
        Event.new(:tool_call, "agent:loop", %{tool: "grep"},
          correlation_id: "corr_1",
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default,
          signal_sn: 0.85
        )

      assert FailureModes.detect(event) == []
    end

    test "returns a list of {mode, description} tuples" do
      # Unclassified event with no signal dimensions
      event = Event.new(:test, "src", %{})
      failures = FailureModes.detect(event)

      assert is_list(failures)

      Enum.each(failures, fn {mode, desc} ->
        assert is_atom(mode)
        assert is_binary(desc)
      end)
    end
  end

  describe "Shannon violations" do
    test "routing_failure when source is nil" do
      # Build a struct directly to bypass enforce_keys for source=nil test
      event = %Event{
        id: "evt_test",
        type: :test,
        source: nil,
        time: DateTime.utc_now(),
        signal_mode: :code,
        signal_genre: :chat,
        signal_type: :inform,
        signal_format: :json,
        signal_structure: :default,
        extensions: %{}
      }

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :routing_failure in modes
    end

    test "bandwidth_overload for large payloads" do
      # Create a data payload that exceeds 100KB when inspect'd
      large_string = String.duplicate("x", 150_000)
      large_data = %{payload: large_string}

      event =
        Event.new(:test, "src", large_data,
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :bandwidth_overload in modes
    end

    test "fidelity_failure when S/N ratio is below 0.3" do
      event =
        Event.new(:test, "src", %{},
          signal_sn: 0.1,
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :fidelity_failure in modes
    end

    test "no fidelity_failure when S/N ratio is nil" do
      event =
        Event.new(:test, "src", %{},
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :fidelity_failure in modes
    end
  end

  describe "Ashby violations" do
    test "variety_failure when no dimensions are resolved" do
      event = Event.new(:test, "src", %{})
      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :variety_failure in modes
    end

    test "structure_failure for partial classification" do
      event = Event.new(:test, "src", %{}, signal_mode: :code, signal_genre: :chat)
      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :structure_failure in modes
    end

    test "no structure_failure when all dimensions resolved" do
      event =
        Event.new(:test, "src", %{},
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :structure_failure in modes
      refute :variety_failure in modes
    end

    test "genre_mismatch when declared genre contradicts inferred" do
      # Type contains "error" but genre is :spec
      event = Event.new(:system_error, "src", %{}, signal_genre: :spec)
      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :genre_mismatch in modes
    end

    test "no genre_mismatch when inferred genre is :chat (default)" do
      # Type is generic, inferred genre would be :chat — no mismatch
      event = Event.new(:tool_call, "src", %{}, signal_genre: :spec)
      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :genre_mismatch in modes
    end
  end

  describe "Beer violations" do
    test "herniation_failure when parent_id without correlation_id" do
      event =
        Event.new(:test, "src", %{},
          parent_id: "parent_123",
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :herniation_failure in modes
    end

    test "no herniation_failure when both parent_id and correlation_id set" do
      event =
        Event.new(:test, "src", %{},
          parent_id: "parent_123",
          correlation_id: "corr_456",
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :herniation_failure in modes
    end

    test "bridge_failure when extensions exceed 20 keys" do
      big_extensions = for i <- 1..25, into: %{}, do: {:"key_#{i}", "value_#{i}"}

      event =
        Event.new(:test, "src", %{},
          extensions: big_extensions,
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :bridge_failure in modes
    end

    test "decay_failure for stale events" do
      old_time = DateTime.add(DateTime.utc_now(), -90_000, :second)

      event = %Event{
        id: "evt_test",
        type: :test,
        source: "src",
        time: old_time,
        signal_mode: :code,
        signal_genre: :chat,
        signal_type: :inform,
        signal_format: :json,
        signal_structure: :default,
        extensions: %{}
      }

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :decay_failure in modes
    end
  end

  describe "Wiener violations" do
    test "feedback_failure for direct-type without correlation" do
      event =
        Event.new(:test, "src", %{},
          signal_type: :direct,
          signal_mode: :code,
          signal_genre: :chat,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :feedback_failure in modes
    end

    test "no feedback_failure when correlation_id is set" do
      event =
        Event.new(:test, "src", %{},
          signal_type: :direct,
          correlation_id: "corr_1",
          signal_mode: :code,
          signal_genre: :chat,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :feedback_failure in modes
    end

    test "no feedback_failure for non-direct types" do
      event =
        Event.new(:test, "src", %{},
          signal_type: :inform,
          signal_mode: :code,
          signal_genre: :chat,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      refute :feedback_failure in modes
    end
  end

  describe "Adversarial noise" do
    test "adversarial_noise for extreme extension count" do
      huge_extensions = for i <- 1..55, into: %{}, do: {:"key_#{i}", "value_#{i}"}

      event =
        Event.new(:test, "src", %{},
          extensions: huge_extensions,
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      failures = FailureModes.detect(event)
      modes = Enum.map(failures, &elem(&1, 0))

      assert :adversarial_noise in modes
      # Should also trigger bridge_failure (>20)
      assert :bridge_failure in modes
    end
  end

  describe "check/2" do
    test "returns :ok when no violation" do
      event =
        Event.new(:test, "src", %{},
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      assert FailureModes.check(event, :routing_failure) == :ok
      assert FailureModes.check(event, :variety_failure) == :ok
      assert FailureModes.check(event, :herniation_failure) == :ok
    end

    test "returns {:violation, mode, description} when detected" do
      event = Event.new(:test, "src", %{}, signal_sn: 0.1)

      assert {:violation, :fidelity_failure, desc} =
               FailureModes.check(event, :fidelity_failure)

      assert String.contains?(desc, "0.1")
    end
  end
end
