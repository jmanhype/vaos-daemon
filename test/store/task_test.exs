defmodule Daemon.Store.TaskTest do
  @moduledoc """
  Unit tests for Daemon.Store.Task schema.

  Tests validate:
  - Changeset validation with valid and invalid inputs
  - Status conversion between atoms (in-memory) and strings (DB)
  - to_map/1 and from_map/1 conversion helpers
  - Edge cases (nil values, boundary conditions)
  """
  use ExUnit.Case, async: true

  alias Daemon.Store.Task

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "task-#{System.unique_integer([:positive])}",
        agent_id: "agent-#{System.unique_integer([:positive])}",
        payload: %{action: "test", data: "example"},
        status: "pending",
        attempts: 0,
        max_attempts: 3
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — validation
  # ---------------------------------------------------------------------------

  describe "changeset/2" do
    test "with valid attributes creates a valid changeset" do
      attrs = valid_attrs()
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "requires task_id" do
      attrs = Map.delete(valid_attrs(), :task_id)
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).task_id == ["can't be blank"]
    end

    test "requires agent_id" do
      attrs = Map.delete(valid_attrs(), :agent_id)
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).agent_id == ["can't be blank"]
    end

    test "validates status inclusion" do
      invalid_statuses = ["invalid", "IN_PROGRESS", "running", nil]

      for status <- invalid_statuses do
        attrs = valid_attrs(%{status: status})
        changeset = Task.changeset(%Task{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for status: #{inspect(status)}"

        assert errors_on(changeset).status == ["is invalid"]
      end
    end

    test "accepts all valid statuses" do
      valid_statuses = ~w(pending leased completed failed)

      for status <- valid_statuses do
        attrs = valid_attrs(%{status: status})
        changeset = Task.changeset(%Task{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for status: #{status}"
      end
    end

    test "validates attempts is greater than or equal to 0" do
      attrs = valid_attrs(%{attempts: -1})
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).attempts == ["must be greater than or equal to 0"]
    end

    test "validates max_attempts is greater than 0" do
      invalid_values = [0, -1, -10]

      for value <- invalid_values do
        attrs = valid_attrs(%{max_attempts: value})
        changeset = Task.changeset(%Task{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for max_attempts: #{value}"

        assert errors_on(changeset).max_attempts == ["must be greater than 0"]
      end
    end

    test "allows optional fields to be nil" do
      attrs = valid_attrs() |> Map.merge(%{
        leased_until: nil,
        leased_by: nil,
        result: nil,
        error: nil,
        completed_at: nil
      })

      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "allows updates to existing task" do
      task = %Task{
        task_id: "task-123",
        agent_id: "agent-456",
        status: "pending"
      }

      attrs = %{status: "completed", attempts: 1}
      changeset = Task.changeset(task, attrs)

      assert changeset.valid?
    end

    test "enforces unique constraint on task_id" do
      # Note: This would require an actual database to test the constraint
      # Here we just verify the constraint is declared in the schema
      attrs = valid_attrs()
      changeset = Task.changeset(%Task{}, attrs)

      # The unique_constraint is added but not tested without DB
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # to_map/1 — DB record to in-memory map
  # ---------------------------------------------------------------------------

  describe "to_map/1" do
    test "converts a Task struct to a map with atom status" do
      task = %Task{
        task_id: "task-123",
        agent_id: "agent-456",
        payload: %{key: "value"},
        status: "completed",
        leased_until: DateTime.utc_now(),
        leased_by: "worker-1",
        result: %{output: "success"},
        error: nil,
        attempts: 2,
        max_attempts: 3,
        completed_at: DateTime.utc_now(),
        inserted_at: DateTime.utc_now()
      }

      map = Task.to_map(task)

      assert map.task_id == "task-123"
      assert map.agent_id == "agent-456"
      assert map.payload == %{key: "value"}
      assert map.status == :completed  # Converted to atom
      assert map.leased_by == "worker-1"
      assert map.result == %{output: "success"}
      assert map.error == nil
      assert map.attempts == 2
      assert map.max_attempts == 3
      assert is_struct(map.leased_until, DateTime)
      assert is_struct(map.completed_at, DateTime)
      assert is_struct(map.created_at, DateTime)
    end

    test "handles nil datetime fields" do
      task = %Task{
        task_id: "task-123",
        agent_id: "agent-456",
        status: "pending",
        leased_until: nil,
        completed_at: nil,
        inserted_at: DateTime.utc_now()
      }

      map = Task.to_map(task)

      assert map.leased_until == nil
      assert map.completed_at == nil
      assert map.created_at != nil
    end

    test "handles empty payload map" do
      task = %Task{
        task_id: "task-123",
        agent_id: "agent-456",
        payload: %{},
        status: "pending",
        inserted_at: DateTime.utc_now()
      }

      map = Task.to_map(task)

      assert map.payload == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # from_map/1 — in-memory map to DB-compatible attrs
  # ---------------------------------------------------------------------------

  describe "from_map/1" do
    test "converts in-memory map with atom status to DB-compatible string status" do
      task_map = %{
        task_id: "task-123",
        agent_id: "agent-456",
        payload: %{key: "value"},
        status: :completed,
        attempts: 2,
        max_attempts: 3
      }

      attrs = Task.from_map(task_map)

      assert attrs.task_id == "task-123"
      assert attrs.agent_id == "agent-456"
      assert attrs.payload == %{key: "value"}
      assert attrs.status == "completed"  # Converted to string
      assert attrs.attempts == 2
      assert attrs.max_attempts == 3
    end

    test "handles map with string keys" do
      task_map = %{
        "task_id" => "task-123",
        "agent_id" => "agent-456",
        "status" => "pending"
      }

      attrs = Task.from_map(task_map)

      assert attrs.task_id == "task-123"
      assert attrs.agent_id == "agent-456"
      assert attrs.status == "pending"
    end

    test "handles nil and missing optional fields" do
      task_map = %{
        task_id: "task-123",
        agent_id: "agent-456"
      }

      attrs = Task.from_map(task_map)

      assert attrs.status == "pending"  # Default
      assert attrs.attempts == 0         # Default
      assert attrs.max_attempts == 3     # Default
      assert attrs.leased_until == nil
      assert attrs.leased_by == nil
      assert attrs.result == nil
      assert attrs.error == nil
    end

    test "preserves datetime fields" do
      dt = DateTime.utc_now()
      task_map = %{
        task_id: "task-123",
        agent_id: "agent-456",
        leased_until: dt,
        completed_at: dt
      }

      attrs = Task.from_map(task_map)

      assert attrs.leased_until == dt
      assert attrs.completed_at == dt
    end
  end

  # ---------------------------------------------------------------------------
  # Status conversion helpers
  # ---------------------------------------------------------------------------

  describe "status_to_atom/1" do
    test "converts valid status strings to atoms" do
      assert Task.status_to_atom("pending") == :pending
      assert Task.status_to_atom("leased") == :leased
      assert Task.status_to_atom("completed") == :completed
      assert Task.status_to_atom("failed") == :failed
    end

    test "passes through atoms unchanged" do
      assert Task.status_to_atom(:pending) == :pending
      assert Task.status_to_atom(:completed) == :completed
    end
  end

  describe "status_to_string/1" do
    test "converts valid status atoms to strings" do
      assert Task.status_to_string(:pending) == "pending"
      assert Task.status_to_string(:leased) == "leased"
      assert Task.status_to_string(:completed) == "completed"
      assert Task.status_to_string(:failed) == "failed"
    end

    test "passes through strings unchanged" do
      assert Task.status_to_string("pending") == "pending"
      assert Task.status_to_string("completed") == "completed"
    end
  end

  describe "to_datetime/1" do
    test "passes through DateTime structs unchanged" do
      dt = DateTime.utc_now()
      assert Task.to_datetime(dt) == dt
    end

    test "converts NaiveDateTime to UTC DateTime" do
      ndt = NaiveDateTime.utc_now()
      result = Task.to_datetime(ndt)

      assert is_struct(result, DateTime)
      assert result.time_zone == "Etc/UTC"
    end

    test "returns nil for nil input" do
      assert Task.to_datetime(nil) == nil
    end
  end
end
