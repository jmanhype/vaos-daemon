defmodule Daemon.Agents.HierarchyTest do
  use ExUnit.Case, async: false

  alias Daemon.Agents.Hierarchy
  alias Daemon.Store.Repo

  setup do
    Repo.delete_all(Hierarchy)
    Hierarchy.seed_defaults()
    :ok
  end

  # ---------------------------------------------------------------------------
  # seed_defaults/0
  # ---------------------------------------------------------------------------

  describe "seed_defaults/0" do
    test "returns {:ok, count} with 31 agents on a fresh table" do
      Repo.delete_all(Hierarchy)
      assert {:ok, 31} = Hierarchy.seed_defaults()
    end

    test "is idempotent — re-seeding does not duplicate rows" do
      Hierarchy.seed_defaults()
      total = Repo.aggregate(Hierarchy, :count, :id)
      assert total == 31
    end
  end

  # ---------------------------------------------------------------------------
  # get_tree/0
  # ---------------------------------------------------------------------------

  describe "get_tree/0" do
    test "returns a list with exactly one root node" do
      tree = Hierarchy.get_tree()
      assert length(tree) == 1
    end

    test "root node is master_orchestrator with ceo role" do
      [root] = Hierarchy.get_tree()
      assert root.agent_name == "master_orchestrator"
      assert root.org_role == "ceo"
      assert root.reports_to == nil
    end

    test "root node has children" do
      [root] = Hierarchy.get_tree()
      assert length(root.children) > 0
    end

    test "tree nodes carry agent_name, reports_to, org_role, title, children keys" do
      [root] = Hierarchy.get_tree()
      assert Map.has_key?(root, :agent_name)
      assert Map.has_key?(root, :reports_to)
      assert Map.has_key?(root, :org_role)
      assert Map.has_key?(root, :title)
      assert Map.has_key?(root, :children)
    end

    test "nested children are populated correctly" do
      [root] = Hierarchy.get_tree()
      child_names = Enum.map(root.children, & &1.agent_name)
      assert "architect" in child_names
      assert "security_auditor" in child_names
      assert "code_reviewer" in child_names
    end

    test "architect node has its own children" do
      [root] = Hierarchy.get_tree()
      architect = Enum.find(root.children, &(&1.agent_name == "architect"))
      refute is_nil(architect)
      assert length(architect.children) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # get_reports/1
  # ---------------------------------------------------------------------------

  describe "get_reports/1" do
    test "returns direct reports for master_orchestrator" do
      reports = Hierarchy.get_reports("master_orchestrator")
      names = Enum.map(reports, & &1.agent_name)
      assert "architect" in names
      assert "security_auditor" in names
      assert "code_reviewer" in names
    end

    test "returns direct reports for code_reviewer" do
      reports = Hierarchy.get_reports("code_reviewer")
      names = Enum.map(reports, & &1.agent_name)
      assert "test_automator" in names
      assert "qa_lead" in names
      assert "debugger" in names
    end

    test "returns empty list for a leaf agent" do
      assert [] = Hierarchy.get_reports("backend_go")
    end

    test "returns empty list for unknown agent" do
      assert [] = Hierarchy.get_reports("nonexistent_agent")
    end

    test "returned structs have expected fields" do
      reports = Hierarchy.get_reports("master_orchestrator")
      report = hd(reports)
      assert report.reports_to == "master_orchestrator"
      assert is_binary(report.agent_name)
    end
  end

  # ---------------------------------------------------------------------------
  # get_chain/1
  # ---------------------------------------------------------------------------

  describe "get_chain/1" do
    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Hierarchy.get_chain("ghost_agent")
    end

    test "returns {:ok, [node]} for root — chain of one" do
      {:ok, chain} = Hierarchy.get_chain("master_orchestrator")
      assert length(chain) == 1
      [node] = chain
      assert node.agent_name == "master_orchestrator"
    end

    test "chain for a direct report starts at agent and ends at root" do
      {:ok, chain} = Hierarchy.get_chain("architect")
      names = Enum.map(chain, & &1.agent_name)
      assert hd(names) == "architect"
      assert List.last(names) == "master_orchestrator"
    end

    test "chain for a deeply nested agent walks all the way to root" do
      {:ok, chain} = Hierarchy.get_chain("backend_go")
      names = Enum.map(chain, & &1.agent_name)
      assert "backend_go" in names
      assert "dragon" in names
      assert "architect" in names
      assert List.last(names) == "master_orchestrator"
    end

    test "chain length is monotonically correct by depth" do
      {:ok, root_chain} = Hierarchy.get_chain("master_orchestrator")
      {:ok, child_chain} = Hierarchy.get_chain("architect")
      {:ok, grandchild_chain} = Hierarchy.get_chain("backend_go")

      assert length(root_chain) < length(child_chain)
      assert length(child_chain) < length(grandchild_chain)
    end
  end

  # ---------------------------------------------------------------------------
  # move_agent/2
  # ---------------------------------------------------------------------------

  describe "move_agent/2" do
    test "reparents an agent and returns {:ok, 1}" do
      assert {:ok, 1} = Hierarchy.move_agent("doc_writer", "code_reviewer")
      names = Hierarchy.get_reports("code_reviewer") |> Enum.map(& &1.agent_name)
      assert "doc_writer" in names
    end

    test "reparenting removes agent from original parent's reports" do
      Hierarchy.move_agent("doc_writer", "code_reviewer")
      names = Hierarchy.get_reports("master_orchestrator") |> Enum.map(& &1.agent_name)
      refute "doc_writer" in names
    end

    test "moving agent to nil makes it a root-level node" do
      assert {:ok, 1} = Hierarchy.move_agent("doc_writer", nil)
      {:ok, [node | _]} = Hierarchy.get_chain("doc_writer")
      assert node.reports_to == nil
    end

    test "returns {:ok, 0} when agent does not exist" do
      assert {:ok, 0} = Hierarchy.move_agent("phantom_agent", "master_orchestrator")
    end

    test "returns {:error, :cycle_detected} when agent would report to itself" do
      assert {:error, :cycle_detected} = Hierarchy.move_agent("master_orchestrator", "master_orchestrator")
    end

    test "returns {:error, :cycle_detected} when moving parent under its own descendant" do
      assert {:error, :cycle_detected} = Hierarchy.move_agent("architect", "backend_go")
    end

    test "returns {:error, :cycle_detected} for indirect cycle via intermediate node" do
      assert {:error, :cycle_detected} = Hierarchy.move_agent("master_orchestrator", "backend_go")
    end
  end

  # ---------------------------------------------------------------------------
  # set_role/2
  # ---------------------------------------------------------------------------

  describe "set_role/2" do
    test "updates org_role for a valid role and agent" do
      assert {:ok, updated} = Hierarchy.set_role("doc_writer", "lead")
      assert updated.org_role == "lead"
    end

    test "accepts all valid roles" do
      valid_roles = ~w(ceo director lead engineer specialist)

      for role <- valid_roles do
        assert {:ok, agent} = Hierarchy.set_role("doc_writer", role)
        assert agent.org_role == role
      end
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Hierarchy.set_role("unknown_agent", "engineer")
    end

    test "returns {:error, :invalid_role} for an unrecognized role string" do
      assert {:error, :invalid_role} = Hierarchy.set_role("doc_writer", "overlord")
    end

    test "returns {:error, :invalid_role} for an empty string role" do
      assert {:error, :invalid_role} = Hierarchy.set_role("doc_writer", "")
    end

    test "persists role change — subsequent get reflects update" do
      Hierarchy.set_role("doc_writer", "director")
      {:ok, chain} = Hierarchy.get_chain("doc_writer")
      node = hd(chain)
      assert node.org_role == "director"
    end
  end

  # ---------------------------------------------------------------------------
  # delegate/3
  # ---------------------------------------------------------------------------

  describe "delegate/3" do
    test "succeeds when target is a direct report" do
      assert {:ok, result} = Hierarchy.delegate("code_reviewer", "test_automator", "write specs")
      assert result.from == "code_reviewer"
      assert result.to == "test_automator"
      assert result.task == "write specs"
      assert result.delegate_role == "engineer"
    end

    test "result includes delegated_at timestamp" do
      {:ok, result} = Hierarchy.delegate("code_reviewer", "debugger", "fix bug")
      assert %DateTime{} = result.delegated_at
    end

    test "returns {:error, :not_a_direct_report} for a non-report agent" do
      assert {:error, :not_a_direct_report} =
               Hierarchy.delegate("code_reviewer", "backend_go", "some task")
    end

    test "returns {:error, :not_a_direct_report} for an unknown agent" do
      assert {:error, :not_a_direct_report} =
               Hierarchy.delegate("code_reviewer", "ghost", "task")
    end

    test "returns {:error, :not_a_direct_report} when delegating to self" do
      assert {:error, :not_a_direct_report} =
               Hierarchy.delegate("code_reviewer", "code_reviewer", "self-assign")
    end

    test "returns {:error, :not_a_direct_report} when from_agent has no reports" do
      assert {:error, :not_a_direct_report} =
               Hierarchy.delegate("backend_go", "frontend_react", "cross-team")
    end
  end
end
