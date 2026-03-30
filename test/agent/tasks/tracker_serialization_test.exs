defmodule Daemon.Agent.Tasks.TrackerSerializationTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Tasks.Tracker

  # ── Fixtures ─────────────────────────────────────────────────────

  defp build_task(overrides \\ %{}) do
    defaults = %{
      id: "task_abc123",
      title: "Test Task",
      description: "A test task description",
      reason: nil,
      owner: "test-automator",
      status: :pending,
      tokens_used: 0,
      blocked_by: [],
      metadata: %{"priority" => "high"},
      created_at: DateTime.utc_now(),
      started_at: nil,
      completed_at: nil
    }

    struct!(Tracker.Task, Map.merge(defaults, overrides))
  end

  # ── serialize_task/1 ────────────────────────────────────────────

  describe "serialize_task/1" do
    test "serializes task with all required fields" do
      task = build_task()
      serialized = Tracker.serialize_task(task)

      assert serialized["id"] == "task_abc123"
      assert serialized["title"] == "Test Task"
      assert serialized["description"] == "A test task description"
      assert serialized["status"] == "pending"
      assert serialized["tokens_used"] == 0
      assert serialized["blocked_by"] == []
      assert is_map(serialized["metadata"])
    end

    test "converts status atom to string" do
      statuses = [:pending, :in_progress, :completed, :failed]

      Enum.each(statuses, fn status ->
        task = build_task(%{status: status})
        serialized = Tracker.serialize_task(task)
        assert serialized["status"] == to_string(status)
      end)
    end

    test "serializes datetime fields to ISO8601 strings" do
      now = DateTime.utc_now()
      task = build_task(%{created_at: now, started_at: now, completed_at: now})

      serialized = Tracker.serialize_task(task)

      assert serialized["created_at"] == DateTime.to_iso8601(now)
      assert serialized["started_at"] == DateTime.to_iso8601(now)
      assert serialized["completed_at"] == DateTime.to_iso8601(now)
    end

    test "handles nil datetime fields" do
      task = build_task(%{started_at: nil, completed_at: nil})
      serialized = Tracker.serialize_task(task)

      assert is_nil(serialized["started_at"])
      assert is_nil(serialized["completed_at"])
      assert not is_nil(serialized["created_at"])
    end

    test "serializes blocked_by list" do
      task = build_task(%{blocked_by: ["task_1", "task_2"]})
      serialized = Tracker.serialize_task(task)

      assert serialized["blocked_by"] == ["task_1", "task_2"]
    end

    test "serializes metadata map" do
      task = build_task(%{metadata: %{"priority" => "high", "labels" => ["bug", "urgent"]}})
      serialized = Tracker.serialize_task(task)

      assert serialized["metadata"]["priority"] == "high"
      assert serialized["metadata"]["labels"] == ["bug", "urgent"]
    end

    test "handles nil reason field" do
      task = build_task(%{reason: nil})
      serialized = Tracker.serialize_task(task)

      assert is_nil(serialized["reason"])
    end

    test "handles nil metadata gracefully" do
      task = build_task(%{metadata: nil})
      serialized = Tracker.serialize_task(task)

      assert serialized["metadata"] == %{}
    end

    test "serializes tokens_used count" do
      task = build_task(%{tokens_used: 1234})
      serialized = Tracker.serialize_task(task)

      assert serialized["tokens_used"] == 1234
    end
  end

  # ── deserialize_task/1 ──────────────────────────────────────────

  describe "deserialize_task/1" do
    test "deserializes valid task map to struct" do
      map = %{
        "id" => "task_xyz",
        "title" => "Deserialized Task",
        "description" => "From map",
        "reason" => "test reason",
        "owner" => "coder",
        "status" => "pending",
        "tokens_used" => 100,
        "blocked_by" => ["task_a"],
        "metadata" => %{"key" => "value"},
        "created_at" => "2025-01-15T10:30:00Z",
        "started_at" => nil,
        "completed_at" => nil
      }

      task = Tracker.deserialize_task(map)

      assert task.id == "task_xyz"
      assert task.title == "Deserialized Task"
      assert task.description == "From map"
      assert task.reason == "test reason"
      assert task.owner == "coder"
      assert task.status == :pending
      assert task.tokens_used == 100
      assert task.blocked_by == ["task_a"]
      assert task.metadata == %{"key" => "value"}
    end

    test "converts status string to atom" do
      statuses = ["pending", "in_progress", "completed", "failed"]

      Enum.each(statuses, fn status_str ->
        map = %{
          "id" => "task_1",
          "title" => "Test",
          "status" => status_str
        }

        task = Tracker.deserialize_task(map)
        assert task.status == String.to_existing_atom(status_str)
      end)
    end

    test "defaults to pending status when missing" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "status" => nil
      }

      task = Tracker.deserialize_task(map)
      assert task.status == :pending
    end

    test "parses ISO8601 datetime strings" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "created_at" => "2025-01-15T10:30:45.123456Z",
        "started_at" => "2025-01-15T11:00:00Z",
        "completed_at" => "2025-01-15T12:00:00Z"
      }

      task = Tracker.deserialize_task(map)

      assert %DateTime{} = task.created_at
      assert %DateTime{} = task.started_at
      assert %DateTime{} = task.completed_at
      assert task.created_at.hour == 10
      assert task.started_at.hour == 11
      assert task.completed_at.hour == 12
    end

    test "handles nil datetime strings" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "created_at" => nil,
        "started_at" => nil,
        "completed_at" => nil
      }

      task = Tracker.deserialize_task(map)

      assert is_nil(task.created_at)
      assert is_nil(task.started_at)
      assert is_nil(task.completed_at)
    end

    test "defaults tokens_used to 0 when missing" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "tokens_used" => nil
      }

      task = Tracker.deserialize_task(map)
      assert task.tokens_used == 0
    end

    test "defaults blocked_by to empty list when missing" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "blocked_by" => nil
      }

      task = Tracker.deserialize_task(map)
      assert task.blocked_by == []
    end

    test "defaults metadata to empty map when missing" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "metadata" => nil
      }

      task = Tracker.deserialize_task(map)
      assert task.metadata == %{}
    end

    test "handles invalid datetime strings gracefully" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "created_at" => "invalid-datetime",
        "started_at" => "also-invalid"
      }

      task = Tracker.deserialize_task(map)

      assert is_nil(task.created_at)
      assert is_nil(task.started_at)
    end

    test "rescues from malformed data and returns minimal task" do
      # Missing required fields
      map = %{}

      task = Tracker.deserialize_task(map)

      assert task.id == "unknown"
      assert task.title == "unknown"
      assert task.status == :pending
      assert task.blocked_by == []
      assert task.metadata == %{}
    end

    test "handles empty strings in optional fields" do
      map = %{
        "id" => "task_1",
        "title" => "Test",
        "description" => "",
        "reason" => ""
      }

      task = Tracker.deserialize_task(map)

      assert task.description == ""
      assert task.reason == ""
    end
  end

  # ── Roundtrip Tests ─────────────────────────────────────────────

  describe "roundtrip: serialize -> deserialize" do
    test "preserves all task data" do
      original = build_task(%{
        status: :in_progress,
        tokens_used: 5678,
        blocked_by: ["task_a", "task_b"],
        metadata: %{"complex" => %{"nested" => "value"}, "list" => [1, 2, 3]}
      })

      serialized = Tracker.serialize_task(original)
      restored = Tracker.deserialize_task(serialized)

      assert restored.id == original.id
      assert restored.title == original.title
      assert restored.description == original.description
      assert restored.reason == original.reason
      assert restored.owner == original.owner
      assert restored.status == original.status
      assert restored.tokens_used == original.tokens_used
      assert restored.blocked_by == original.blocked_by
      assert restored.metadata == original.metadata
    end

    test "preserves datetime precision through roundtrip" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      original = build_task(%{
        created_at: now,
        started_at: now,
        completed_at: now
      })

      serialized = Tracker.serialize_task(original)
      restored = Tracker.deserialize_task(serialized)

      assert restored.created_at == original.created_at
      assert restored.started_at == original.started_at
      assert restored.completed_at == original.completed_at
    end

    test "handles all status values through roundtrip" do
      statuses = [:pending, :in_progress, :completed, :failed]

      Enum.each(statuses, fn status ->
        original = build_task(%{status: status})
        serialized = Tracker.serialize_task(original)
        restored = Tracker.deserialize_task(serialized)

        assert restored.status == status
      end)
    end

    test "preserves nil datetime fields" do
      original = build_task(%{started_at: nil, completed_at: nil})

      serialized = Tracker.serialize_task(original)
      restored = Tracker.deserialize_task(serialized)

      assert is_nil(restored.started_at)
      assert is_nil(restored.completed_at)
      assert not is_nil(restored.created_at)
    end
  end

  # ── Edge Cases ─────────────────────────────────────────────────

  describe "edge cases" do
    test "handles empty blocked_by list" do
      task = build_task(%{blocked_by: []})
      serialized = Tracker.serialize_task(task)

      assert serialized["blocked_by"] == []

      restored = Tracker.deserialize_task(serialized)
      assert restored.blocked_by == []
    end

    test "handles empty metadata map" do
      task = build_task(%{metadata: %{}})
      serialized = Tracker.serialize_task(task)

      assert serialized["metadata"] == %{}

      restored = Tracker.deserialize_task(serialized)
      assert restored.metadata == %{}
    end

    test "handles zero tokens_used" do
      task = build_task(%{tokens_used: 0})
      serialized = Tracker.serialize_task(task)

      assert serialized["tokens_used"] == 0

      restored = Tracker.deserialize_task(serialized)
      assert restored.tokens_used == 0
    end

    test "handles large tokens_used values" do
      task = build_task(%{tokens_used: 1_000_000})
      serialized = Tracker.serialize_task(task)

      assert serialized["tokens_used"] == 1_000_000

      restored = Tracker.deserialize_task(serialized)
      assert restored.tokens_used == 1_000_000
    end

    test "handles many blocked_by dependencies" do
      blockers = Enum.map(1..50, &"task_#{&1}")
      task = build_task(%{blocked_by: blockers})

      serialized = Tracker.serialize_task(task)
      assert serialized["blocked_by"] == blockers

      restored = Tracker.deserialize_task(serialized)
      assert restored.blocked_by == blockers
    end

    test "handles special characters in strings" do
      task = build_task(%{
        title: "Task with "quotes" and 'apostrophes'",
        description: "Multi\nline\twith\tspecial\\chars",
        metadata: %{"emoji" => "🎉 🔥", "unicode" => "中文 日本語"}
      })

      serialized = Tracker.serialize_task(task)
      restored = Tracker.deserialize_task(serialized)

      assert restored.title == task.title
      assert restored.description == task.description
      assert restored.metadata["emoji"] == "🎉 🔥"
    end
  end

  # ── Data Integrity ─────────────────────────────────────────────

  describe "data integrity" do
    test "serialize_task produces valid JSON-encodable map" do
      task = build_task()
      serialized = Tracker.serialize_task(task)

      # Should be JSON-encodable without error
      assert {:ok, _json_string} = Jason.encode(serialized)
    end

    test "deserialize_task handles Jason-decoded maps" do
      # Simulate JSON roundtrip
      task = build_task()
      serialized = Tracker.serialize_task(task)

      {:ok, json} = Jason.encode(serialized)
      {:ok, decoded} = Jason.decode(json)

      restored = Tracker.deserialize_task(decoded)

      assert restored.id == task.id
      assert restored.title == task.title
      assert restored.status == task.status
    end

    test "handles complex nested metadata" do
      complex_metadata = %{
        "nested" => %{
          "deep" => %{
            "value" => [1, 2, %{"inner" => "data"}]
          }
        },
        "list_of_maps" => [%{"a" => 1}, %{"b" => 2}]
      }

      task = build_task(%{metadata: complex_metadata})
      serialized = Tracker.serialize_task(task)
      restored = Tracker.deserialize_task(serialized)

      assert restored.metadata == complex_metadata
    end
  end
end
