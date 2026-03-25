defmodule Daemon.Signal.PersistenceTest do
  use ExUnit.Case, async: true

  alias Daemon.Signal.Persistence
  alias Daemon.Store.Signal

  @valid_attrs %{
    channel: "cli",
    mode: "execute",
    genre: "direct",
    type: "request",
    format: "command",
    weight: 0.7,
    session_id: "test_signal_#{:erlang.unique_integer([:positive])}",
    input_preview: "test message",
    confidence: "high"
  }

  describe "persist_signal/1" do
    test "creates a signal record with valid attrs" do
      assert {:ok, record} = Persistence.persist_signal(@valid_attrs)
      assert record.id
      assert record.channel == "cli"
      assert record.mode == "execute"
      assert record.tier == "opus"
    end

    test "derives tier from weight" do
      assert {:ok, haiku} = Persistence.persist_signal(%{@valid_attrs | weight: 0.2})
      assert haiku.tier == "haiku"

      assert {:ok, sonnet} = Persistence.persist_signal(%{@valid_attrs | weight: 0.5})
      assert sonnet.tier == "sonnet"

      assert {:ok, opus} = Persistence.persist_signal(%{@valid_attrs | weight: 0.8})
      assert opus.tier == "opus"
    end

    test "rejects invalid mode" do
      assert {:error, changeset} = Persistence.persist_signal(%{@valid_attrs | mode: "invalid"})
      assert %{mode: _} = errors_on(changeset)
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Persistence.persist_signal(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :channel)
      assert Map.has_key?(errors, :mode)
    end
  end

  describe "list_signals/1" do
    test "returns signals ordered by inserted_at desc" do
      tag = "list_#{:erlang.unique_integer([:positive])}"

      for i <- 1..3 do
        Persistence.persist_signal(%{@valid_attrs | session_id: "#{tag}_#{i}"})
      end

      signals = Persistence.list_signals(session_id: nil, limit: 100)
      assert is_list(signals)
    end

    test "filters by mode" do
      tag = "filter_mode_#{:erlang.unique_integer([:positive])}"
      Persistence.persist_signal(%{@valid_attrs | session_id: tag, mode: "build"})
      Persistence.persist_signal(%{@valid_attrs | session_id: tag, mode: "analyze"})

      build_signals = Persistence.list_signals(mode: "build", limit: 100)
      assert Enum.all?(build_signals, &(&1.mode == "build"))
    end

    test "filters by weight range" do
      tag = "filter_weight_#{:erlang.unique_integer([:positive])}"
      Persistence.persist_signal(%{@valid_attrs | session_id: tag, weight: 0.1})
      Persistence.persist_signal(%{@valid_attrs | session_id: tag, weight: 0.9})

      low = Persistence.list_signals(weight_max: 0.3, limit: 100)
      assert Enum.all?(low, &(&1.weight <= 0.3))
    end
  end

  describe "signal_stats/0" do
    test "returns expected shape" do
      stats = Persistence.signal_stats()
      assert is_integer(stats.total)
      assert is_float(stats.avg_weight) or stats.avg_weight == 0.0
      assert is_map(stats.by_mode)
      assert is_map(stats.by_channel)
      assert is_map(stats.by_tier)
    end
  end

  describe "signal_patterns/1" do
    test "returns expected shape" do
      patterns = Persistence.signal_patterns(days: 7)
      assert is_float(patterns.avg_weight) or patterns.avg_weight == 0.0
      assert is_map(patterns.top_agents)
      assert is_map(patterns.peak_hours)
      assert is_list(patterns.daily_counts)
      assert is_integer(patterns.total_in_period)
    end
  end

  describe "Signal changeset" do
    test "validates weight bounds" do
      cs = Signal.changeset(%{@valid_attrs | weight: 1.5})
      refute cs.valid?

      cs = Signal.changeset(%{@valid_attrs | weight: -0.1})
      refute cs.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
