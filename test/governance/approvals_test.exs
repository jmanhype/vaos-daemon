defmodule OptimalSystemAgent.Governance.ApprovalsTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Governance.Approvals
  alias OptimalSystemAgent.Store.Repo

  setup do
    Repo.delete_all(Approvals)
    :ok
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        type: "budget_change",
        title: "Increase monthly budget",
        description: "Need more tokens",
        requested_by: "architect"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # create/1
  # ---------------------------------------------------------------------------

  describe "create/1" do
    test "creates an approval with pending status by default" do
      assert {:ok, approval} = Approvals.create(valid_attrs())
      assert approval.status == "pending"
    end

    test "persists all provided fields" do
      attrs = valid_attrs(%{
        description: "Detailed description",
        requested_by: "dragon",
        related_entity_type: "agent",
        related_entity_id: "agent-123",
        context: %{reason: "scaling"}
      })

      assert {:ok, approval} = Approvals.create(attrs)
      assert approval.type == "budget_change"
      assert approval.title == "Increase monthly budget"
      assert approval.description == "Detailed description"
      assert approval.requested_by == "dragon"
      assert approval.related_entity_type == "agent"
      assert approval.related_entity_id == "agent-123"
      assert approval.context == %{"reason" => "scaling"}
    end

    test "assigns a non-nil id on creation" do
      {:ok, approval} = Approvals.create(valid_attrs())
      refute is_nil(approval.id)
    end

    test "returns {:error, changeset} when type is missing" do
      attrs = Map.delete(valid_attrs(), :type)
      assert {:error, changeset} = Approvals.create(attrs)
      assert Keyword.has_key?(changeset.errors, :type)
    end

    test "returns {:error, changeset} when title is missing" do
      attrs = Map.delete(valid_attrs(), :title)
      assert {:error, changeset} = Approvals.create(attrs)
      assert Keyword.has_key?(changeset.errors, :title)
    end

    test "returns {:error, changeset} for invalid type" do
      assert {:error, changeset} = Approvals.create(valid_attrs(%{type: "explode_everything"}))
      assert Keyword.has_key?(changeset.errors, :type)
    end

    test "accepts all valid types" do
      valid_types = ~w(agent_create budget_change task_reassign strategy_change agent_terminate)

      for type <- valid_types do
        assert {:ok, approval} = Approvals.create(valid_attrs(%{type: type}))
        assert approval.type == type
      end
    end
  end

  # ---------------------------------------------------------------------------
  # get/1
  # ---------------------------------------------------------------------------

  describe "get/1" do
    test "returns {:ok, approval} for an existing id" do
      {:ok, created} = Approvals.create(valid_attrs())
      assert {:ok, fetched} = Approvals.get(created.id)
      assert fetched.id == created.id
      assert fetched.title == created.title
    end

    test "returns {:error, :not_found} for a non-existent id" do
      assert {:error, :not_found} = Approvals.get(999_999)
    end

    test "returns {:error, :not_found} for nil id" do
      assert {:error, :not_found} = Approvals.get(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/4
  # ---------------------------------------------------------------------------

  describe "resolve/4" do
    test "approves a pending approval" do
      {:ok, approval} = Approvals.create(valid_attrs())

      assert {:ok, resolved} = Approvals.resolve(approval.id, "approved", "LGTM", "master_orchestrator")
      assert resolved.status == "approved"
      assert resolved.resolved_by == "master_orchestrator"
      assert resolved.decision_notes == "LGTM"
      assert %DateTime{} = resolved.resolved_at
    end

    test "rejects a pending approval" do
      {:ok, approval} = Approvals.create(valid_attrs())

      assert {:ok, resolved} = Approvals.resolve(approval.id, "rejected", "Too costly", "master_orchestrator")
      assert resolved.status == "rejected"
    end

    test "marks approval as revision_requested" do
      {:ok, approval} = Approvals.create(valid_attrs())

      assert {:ok, resolved} = Approvals.resolve(approval.id, "revision_requested", "Needs more detail", "architect")
      assert resolved.status == "revision_requested"
    end

    test "accepts nil notes" do
      {:ok, approval} = Approvals.create(valid_attrs())

      assert {:ok, resolved} = Approvals.resolve(approval.id, "approved", nil, "master_orchestrator")
      assert resolved.decision_notes == nil
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Approvals.resolve(999_999, "approved", nil, "admin")
    end

    test "returns {:error, :already_resolved} when approving an already-approved record" do
      {:ok, approval} = Approvals.create(valid_attrs())
      Approvals.resolve(approval.id, "approved", nil, "master_orchestrator")

      assert {:error, :already_resolved} =
               Approvals.resolve(approval.id, "approved", "again", "master_orchestrator")
    end

    test "returns {:error, :already_resolved} when rejecting an already-rejected record" do
      {:ok, approval} = Approvals.create(valid_attrs())
      Approvals.resolve(approval.id, "rejected", nil, "master_orchestrator")

      assert {:error, :already_resolved} =
               Approvals.resolve(approval.id, "rejected", "double reject", "admin")
    end

    test "returns {:error, :already_resolved} when acting on a revision_requested record" do
      {:ok, approval} = Approvals.create(valid_attrs())
      Approvals.resolve(approval.id, "revision_requested", nil, "master_orchestrator")

      assert {:error, :already_resolved} =
               Approvals.resolve(approval.id, "approved", nil, "master_orchestrator")
    end
  end

  # ---------------------------------------------------------------------------
  # list_pending/0
  # ---------------------------------------------------------------------------

  describe "list_pending/0" do
    test "returns empty list when no approvals exist" do
      assert [] = Approvals.list_pending()
    end

    test "returns only pending approvals" do
      {:ok, a1} = Approvals.create(valid_attrs(%{title: "Pending 1"}))
      {:ok, a2} = Approvals.create(valid_attrs(%{title: "Pending 2"}))
      {:ok, a3} = Approvals.create(valid_attrs(%{title: "To resolve"}))
      Approvals.resolve(a3.id, "approved", nil, "admin")

      pending = Approvals.list_pending()
      ids = Enum.map(pending, & &1.id)

      assert a1.id in ids
      assert a2.id in ids
      refute a3.id in ids
    end

    test "all returned records have status pending" do
      Approvals.create(valid_attrs(%{title: "P1"}))
      Approvals.create(valid_attrs(%{title: "P2"}))

      for approval <- Approvals.list_pending() do
        assert approval.status == "pending"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # pending_count/0
  # ---------------------------------------------------------------------------

  describe "pending_count/0" do
    test "returns 0 when no approvals exist" do
      assert 0 = Approvals.pending_count()
    end

    test "counts only pending approvals" do
      Approvals.create(valid_attrs(%{title: "P1"}))
      Approvals.create(valid_attrs(%{title: "P2"}))
      {:ok, a3} = Approvals.create(valid_attrs(%{title: "P3"}))
      Approvals.resolve(a3.id, "approved", nil, "admin")

      assert 2 = Approvals.pending_count()
    end

    test "increments when a new pending approval is added" do
      before = Approvals.pending_count()
      Approvals.create(valid_attrs())
      assert Approvals.pending_count() == before + 1
    end
  end

  # ---------------------------------------------------------------------------
  # list_all/1
  # ---------------------------------------------------------------------------

  describe "list_all/1" do
    setup do
      {:ok, a1} = Approvals.create(valid_attrs(%{title: "Budget", type: "budget_change"}))
      {:ok, a2} = Approvals.create(valid_attrs(%{title: "New Agent", type: "agent_create"}))
      {:ok, a3} = Approvals.create(valid_attrs(%{title: "Terminate", type: "agent_terminate"}))
      Approvals.resolve(a3.id, "rejected", nil, "admin")
      %{a1: a1, a2: a2, a3: a3}
    end

    test "returns all records without filters" do
      result = Approvals.list_all()
      assert result.total == 3
      assert length(result.approvals) == 3
    end

    test "returns pagination metadata" do
      result = Approvals.list_all()
      assert result.page == 1
      assert result.per_page == 20
    end

    test "filters by status" do
      result = Approvals.list_all(%{status: "pending"})
      assert result.total == 2
      for a <- result.approvals, do: assert(a.status == "pending")
    end

    test "filters by type" do
      result = Approvals.list_all(%{type: "budget_change"})
      assert result.total == 1
      [only] = result.approvals
      assert only.type == "budget_change"
    end

    test "combining status and type filters returns intersection" do
      result = Approvals.list_all(%{status: "pending", type: "agent_create"})
      assert result.total == 1
      [only] = result.approvals
      assert only.type == "agent_create"
      assert only.status == "pending"
    end

    test "pagination limits results per page" do
      result = Approvals.list_all(%{page: 1, per_page: 1})
      assert length(result.approvals) == 1
      assert result.per_page == 1
      assert result.page == 1
    end

    test "page 2 returns different records than page 1" do
      r1 = Approvals.list_all(%{page: 1, per_page: 1})
      r2 = Approvals.list_all(%{page: 2, per_page: 1})
      ids1 = Enum.map(r1.approvals, & &1.id)
      ids2 = Enum.map(r2.approvals, & &1.id)
      assert ids1 != ids2
    end

    test "returns empty approvals list when filter matches nothing" do
      result = Approvals.list_all(%{type: "strategy_change"})
      assert result.total == 0
      assert result.approvals == []
    end
  end

  # ---------------------------------------------------------------------------
  # requires_approval?/1
  # ---------------------------------------------------------------------------

  describe "requires_approval?/1" do
    test "returns true for all valid action types" do
      valid_types = ~w(agent_create budget_change task_reassign strategy_change agent_terminate)

      for type <- valid_types do
        assert Approvals.requires_approval?(type) == true, "expected true for type #{type}"
      end
    end

    test "returns false for an unknown action type" do
      refute Approvals.requires_approval?("delete_database")
    end

    test "returns false for an empty string" do
      refute Approvals.requires_approval?("")
    end

    test "returns false for a nil-like string" do
      refute Approvals.requires_approval?("nil")
    end
  end
end
