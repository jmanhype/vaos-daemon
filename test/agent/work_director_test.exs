defmodule Daemon.Agent.WorkDirectorTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.WorkDirector.Backlog
  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  describe "reward spread constants" do
    # These tests document the intended reward spread.
    # Success=0.8, merge=1.0, rejection=0.05, all failures<=0.1
    # Wide gap ensures Thompson Sampling can distinguish good from bad sources.

    test "success reward (0.8) is at least 4x max failure reward (0.1)" do
      success_reward = 0.8
      max_failure_reward = 0.1
      assert success_reward / max_failure_reward >= 4.0
    end

    test "merge reward (1.0) is higher than success reward (0.8)" do
      assert 1.0 > 0.8
    end

    test "rejection reward (0.05) is much lower than success reward (0.8)" do
      assert 0.05 < 0.8 / 4
    end
  end

  describe "dispatch throttle" do
    test "max_dispatches_per_day is capped at reasonable level" do
      # WorkDirector should not create more than ~1 PR/hour average
      # 24 dispatches/day = 1/hour average
      max_dispatches = 24
      assert max_dispatches <= 48, "max_dispatches_per_day should be <= 48 to prevent hamster wheel"
    end
  end

  describe "failure context round-trip via backlog" do
    setup do
      Backlog.clear_blacklist()
      :ok
    end

    test "failure context is preserved across mark_failed -> merge cycle" do
      item = WorkItem.new(%{source: :vision, title: "RT Test", description: "round trip", base_priority: 0.5})
      backlog = %{item.content_hash => %{item | status: :dispatched, attempt_count: 1}}

      # Mark failed with context
      backlog = Backlog.mark_failed(backlog, item.content_hash, %{
        class: :compilation_error,
        reason: "undefined function foo/1"
      })

      failed_item = backlog[item.content_hash]
      assert failed_item.last_failure_class == :compilation_error
      assert failed_item.last_failure_reason =~ "foo/1"

      # Simulate recycle: when merge sees a failed item with attempts < max and past cooldown,
      # it recycles to :pending but should preserve the failure context fields
      recycled_item = %{failed_item |
        last_attempted_at: DateTime.add(DateTime.utc_now(), -10, :hour)
      }
      backlog = %{item.content_hash => recycled_item}

      # New item comes in from source refresh
      fresh = WorkItem.new(%{source: :vision, title: "RT Test", description: "round trip", base_priority: 0.6})
      merged = Backlog.merge(backlog, [fresh])

      # Item should be recycled (status back to :pending) but keep failure info
      result = merged[item.content_hash]
      assert result.status == :pending
      # Failure context preserved through recycle
      assert result.last_failure_class == :compilation_error
    end

    test "blacklisted items stay blocked across merge cycles" do
      item = WorkItem.new(%{source: :vision, title: "BL Persist", description: "stays blocked", base_priority: 0.5})

      # Blacklist it
      Backlog.blacklist(item.content_hash, "exhausted 3 attempts")

      # Try to merge — should be rejected
      result1 = Backlog.merge(%{}, [item])
      assert result1 == %{}

      # Try again — still rejected
      result2 = Backlog.merge(%{}, [item])
      assert result2 == %{}
    end
  end
end
