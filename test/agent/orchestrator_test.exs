defmodule Daemon.Agent.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Orchestrator
  alias Daemon.Agent.Orchestrator.{Complexity, StateMachine}

  # ---------------------------------------------------------------------------
  # Complexity.quick_score/1  (pure, no LLM — fast unit tests)
  # ---------------------------------------------------------------------------

  describe "Complexity.quick_score/1" do
    test "short simple message scores in low range" do
      score = Complexity.quick_score("fix typo in README")
      assert score <= 5
    end

    test "long multi-system message scores higher" do
      msg = """
      Refactor the entire authentication subsystem and migrate all users,
      update the database schema, add multi-factor auth support,
      write integration tests, update the CI/CD pipeline, deploy to staging,
      write documentation for the new API endpoints, and notify stakeholders.
      """
      score = Complexity.quick_score(msg)
      assert score >= 3
    end

    test "returns an integer in 1..10 range" do
      for msg <- ["hello", "do many things " |> String.duplicate(50)] do
        s = Complexity.quick_score(msg)
        assert s in 1..10
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Complexity.parse_response/1  (pure — no LLM)
  # ---------------------------------------------------------------------------

  describe "Complexity.parse_response/1" do
    test "simple JSON is parsed as {:simple, score}" do
      json = Jason.encode!(%{
        "complexity" => "simple",
        "complexity_score" => 2,
        "reasoning" => "trivial change"
      })
      assert {:simple, 2} = Complexity.parse_response(json)
    end

    test "complex JSON is parsed with sub-tasks" do
      json = Jason.encode!(%{
        "complexity" => "complex",
        "complexity_score" => 8,
        "reasoning" => "multi-system",
        "sub_tasks" => [
          %{"name" => "research", "description" => "gather info", "role" => "backend", "tools_needed" => [], "depends_on" => []}
        ]
      })
      assert {:complex, 8, [task]} = Complexity.parse_response(json)
      assert task.name == "research"
    end

    test "invalid JSON falls back to {:simple, 3}" do
      assert {:simple, 3} = Complexity.parse_response("not json")
    end

    test "score below 1 is clamped to default" do
      json = Jason.encode!(%{"complexity" => "simple", "complexity_score" => 0})
      assert {:simple, 3} = Complexity.parse_response(json)
    end

    test "score above 10 is clamped to default" do
      json = Jason.encode!(%{"complexity" => "simple", "complexity_score" => 99})
      assert {:simple, 3} = Complexity.parse_response(json)
    end

    test "markdown-fenced JSON is unwrapped before parsing" do
      inner = Jason.encode!(%{"complexity" => "simple", "complexity_score" => 4, "reasoning" => "ok"})
      fenced = "```json\n#{inner}\n```"
      assert {:simple, 4} = Complexity.parse_response(fenced)
    end
  end

  # ---------------------------------------------------------------------------
  # StateMachine — task lifecycle (pure, no GenServer)
  # ---------------------------------------------------------------------------

  describe "task state machine" do
    test "new machine starts in :idle phase" do
      sm = StateMachine.new("orch-test-1")
      assert sm.phase == :idle
    end

    test "idle → planning → executing lifecycle" do
      sm = StateMachine.new("orch-test-2")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert sm.phase == :planning

      {:ok, sm} = StateMachine.set_plan(sm, %{sub_tasks: [], complexity_score: 5, estimated_tokens: 1000})
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      assert sm.phase == :executing
    end

    test "wave failure triggers error_recovery" do
      sm = StateMachine.new("orch-test-3")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.phase == :error_recovery
      assert sm.error_count == 1
    end

    test "error_recovery → replan → executing succeeds" do
      sm = StateMachine.new("orch-test-4")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      {:ok, sm} = StateMachine.transition(sm, :replan)
      assert sm.phase == :planning
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      assert sm.phase == :executing
    end

    test "completed is a terminal state" do
      sm = StateMachine.new("orch-test-5")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :waves_complete)
      {:ok, sm} = StateMachine.transition(sm, :verification_passed)
      assert sm.phase == :completed
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :start_planning)
    end

    test "permission_tier reflects phase correctly" do
      sm = StateMachine.new("t")
      assert StateMachine.permission_tier(sm) == :none

      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert StateMachine.permission_tier(sm) == :read_only

      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      assert StateMachine.permission_tier(sm) == :full
    end
  end

  # ---------------------------------------------------------------------------
  # TaskState struct defaults
  # ---------------------------------------------------------------------------

  describe "TaskState struct" do
    test "has expected default field values" do
      ts = %Orchestrator.TaskState{id: "t", message: "m", session_id: "s", strategy: "auto"}
      assert ts.status == :running
      assert ts.agents == %{}
      assert ts.sub_tasks == []
      assert ts.results == %{}
      assert ts.synthesis == nil
      assert ts.wave_refs == %{}
      assert ts.current_wave == 0
      assert ts.pending_waves == []
      assert ts.cached_tools == []
    end
  end

  # ---------------------------------------------------------------------------
  # SubTask struct
  # ---------------------------------------------------------------------------

  describe "SubTask struct" do
    test "has expected default field values" do
      st = %Orchestrator.SubTask{name: "research", description: "gather data", role: :backend, tools_needed: []}
      assert st.depends_on == []
      assert st.context == nil
    end
  end

  # ---------------------------------------------------------------------------
  # AgentState struct
  # ---------------------------------------------------------------------------

  describe "AgentState struct" do
    test "starts in pending status with zero counters" do
      ag = %Orchestrator.AgentState{id: "ag-1", task_id: "t-1", name: "research", role: :backend}
      assert ag.status == :pending
      assert ag.tool_uses == 0
      assert ag.tokens_used == 0
      assert ag.result == nil
      assert ag.error == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Orchestrator GenServer — integration-level (requires running process)
  # ---------------------------------------------------------------------------

  describe "Orchestrator GenServer" do
    @tag :integration
    test "list_tasks/0 returns a list" do
      assert is_list(Orchestrator.list_tasks())
    end

    @tag :integration
    test "progress/1 returns :not_found for unknown task" do
      assert {:error, :not_found} = Orchestrator.progress("nonexistent-task-id")
    end

    @tag :integration
    test "find_matching_skills/1 returns a result tuple" do
      result = Orchestrator.find_matching_skills("refactor authentication module")
      assert match?({:matches, _}, result) or result == :no_matches
    end
  end
end
