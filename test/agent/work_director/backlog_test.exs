defmodule Daemon.Agent.WorkDirector.BacklogTest do
  use ExUnit.Case, async: false

  alias Daemon.Agent.WorkDirector.Backlog
  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  setup do
    # Clear blacklist before each test to avoid cross-test contamination
    Backlog.clear_blacklist()
    :ok
  end

  describe "blacklist" do
    test "blacklisted items are not inserted by merge" do
      item = WorkItem.new(%{source: :vision, title: "Blacklist Test", description: "desc", base_priority: 0.5})
      Backlog.blacklist(item.content_hash, "test reason")

      result = Backlog.merge(%{}, [item])
      assert result == %{}
    end

    test "non-blacklisted items are inserted normally" do
      item = WorkItem.new(%{source: :vision, title: "Normal Insert", description: "desc", base_priority: 0.5})

      result = Backlog.merge(%{}, [item])
      assert Map.has_key?(result, item.content_hash)
    end

    test "blacklisted?/1 returns true for blacklisted hashes" do
      hash = "test_hash_123"
      Backlog.blacklist(hash, "test")
      assert Backlog.blacklisted?(hash)
    end

    test "blacklisted?/1 returns false for non-blacklisted hashes" do
      refute Backlog.blacklisted?("never_seen_hash")
    end

    test "clear_blacklist removes all entries" do
      Backlog.blacklist("hash1", "reason1")
      Backlog.blacklist("hash2", "reason2")
      assert Backlog.blacklisted?("hash1")

      Backlog.clear_blacklist()
      refute Backlog.blacklisted?("hash1")
      refute Backlog.blacklisted?("hash2")
    end
  end

  describe "mark_failed with context" do
    test "mark_failed/3 stores failure class and reason" do
      item = WorkItem.new(%{source: :vision, title: "FC Test", description: "desc", base_priority: 0.5})
      backlog = %{item.content_hash => %{item | status: :dispatched, attempt_count: 1}}

      backlog = Backlog.mark_failed(backlog, item.content_hash, %{class: :compilation_error, reason: "undefined function"})
      updated = backlog[item.content_hash]

      assert updated.last_failure_class == :compilation_error
      assert updated.last_failure_reason =~ "undefined function"
      assert updated.status == :failed
    end

    test "mark_failed/3 auto-blacklists at max attempts" do
      item = WorkItem.new(%{source: :vision, title: "Max Attempt BL", description: "desc", base_priority: 0.5})
      backlog = %{item.content_hash => %{item | attempt_count: 3, status: :dispatched}}

      _backlog = Backlog.mark_failed(backlog, item.content_hash, %{class: :stub_detected, reason: "stub"})
      assert Backlog.blacklisted?(item.content_hash)
    end

    test "mark_failed/3 does not blacklist below max attempts" do
      item = WorkItem.new(%{source: :vision, title: "Below Max", description: "desc", base_priority: 0.5})
      backlog = %{item.content_hash => %{item | attempt_count: 1, status: :dispatched}}

      _backlog = Backlog.mark_failed(backlog, item.content_hash, %{class: :timeout, reason: "slow"})
      refute Backlog.blacklisted?(item.content_hash)
    end

    test "mark_failed/2 without context still works" do
      item = WorkItem.new(%{source: :vision, title: "No Context", description: "desc", base_priority: 0.5})
      backlog = %{item.content_hash => %{item | status: :dispatched, attempt_count: 1}}

      backlog = Backlog.mark_failed(backlog, item.content_hash)
      updated = backlog[item.content_hash]

      assert updated.status == :failed
      assert updated.last_failure_class == nil
    end
  end

  describe "eligibility" do
    test "items on cooldown are not eligible" do
      item = %{WorkItem.new(%{source: :vision, title: "CD Test", description: "desc", base_priority: 0.5}) |
        status: :pending, attempt_count: 1, last_attempted_at: DateTime.utc_now()}
      backlog = %{item.content_hash => item}

      assert Backlog.pick_next(backlog, %{}) == :empty
    end

    test "items past max attempts are not eligible" do
      item = %{WorkItem.new(%{source: :vision, title: "MA Test", description: "desc", base_priority: 0.5}) |
        status: :pending, attempt_count: 3}
      backlog = %{item.content_hash => item}

      assert Backlog.pick_next(backlog, %{}) == :empty
    end

    test "eligible items are returned by pick_next" do
      item = %{WorkItem.new(%{source: :vision, title: "Eligible", description: "desc", base_priority: 0.5}) |
        status: :pending, attempt_count: 0}
      backlog = %{item.content_hash => item}

      assert {:ok, picked} = Backlog.pick_next(backlog, %{})
      assert picked.content_hash == item.content_hash
    end
  end

  describe "serialization" do
    test "failure context survives serialize/deserialize round-trip" do
      item = %{WorkItem.new(%{source: :vision, title: "Serialize FC", description: "desc"}) |
        last_failure_class: :phantom_references,
        last_failure_reason: "undefined module Foo"}

      # Persist and reload
      backlog = %{item.content_hash => item}
      Backlog.persist(backlog)
      loaded = Backlog.load()

      loaded_item = loaded[item.content_hash]
      assert loaded_item.last_failure_class == :phantom_references
      assert loaded_item.last_failure_reason == "undefined module Foo"
    end
  end
end
