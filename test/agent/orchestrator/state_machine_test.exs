defmodule Daemon.Agent.Orchestrator.StateMachineTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Orchestrator.StateMachine

  # ── Construction ───────────────────────────────────────────────────

  describe "new/1" do
    test "creates state machine in :idle phase" do
      sm = StateMachine.new("task-1")
      assert sm.phase == :idle
      assert sm.task_id == "task-1"
      assert sm.error_count == 0
      assert sm.transitions == []
      assert sm.plan == nil
      assert sm.wave_results == []
      assert sm.verification == nil
    end

    test "sets started_at timestamp" do
      sm = StateMachine.new("task-2")
      assert %DateTime{} = sm.started_at
    end
  end

  # ── Valid Transitions ──────────────────────────────────────────────

  describe "transition/2 — valid transitions" do
    test "idle → planning via :start_planning" do
      sm = StateMachine.new("t")
      assert {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert sm.phase == :planning
    end

    test "planning → executing via :approve_plan" do
      sm = StateMachine.new("t")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      assert sm.phase == :executing
    end

    test "planning → idle via :reject_plan" do
      sm = StateMachine.new("t")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :reject_plan)
      assert sm.phase == :idle
    end

    test "executing → verifying via :waves_complete" do
      sm = advance_to(:executing)
      {:ok, sm} = StateMachine.transition(sm, :waves_complete)
      assert sm.phase == :verifying
    end

    test "executing → error_recovery via :wave_failure" do
      sm = advance_to(:executing)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.phase == :error_recovery
    end

    test "verifying → completed via :verification_passed" do
      sm = advance_to(:verifying)
      {:ok, sm} = StateMachine.transition(sm, :verification_passed)
      assert sm.phase == :completed
    end

    test "verifying → error_recovery via :verification_failed" do
      sm = advance_to(:verifying)
      {:ok, sm} = StateMachine.transition(sm, :verification_failed)
      assert sm.phase == :error_recovery
    end

    test "error_recovery → planning via :replan" do
      sm = advance_to(:error_recovery)
      {:ok, sm} = StateMachine.transition(sm, :replan)
      assert sm.phase == :planning
    end

    test "error_recovery → completed via :manual_override" do
      sm = advance_to(:error_recovery)
      {:ok, sm} = StateMachine.transition(sm, :manual_override)
      assert sm.phase == :completed
    end
  end

  # ── Invalid Transitions ────────────────────────────────────────────

  describe "transition/2 — invalid transitions" do
    test "idle cannot go directly to :executing" do
      sm = StateMachine.new("t")
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :approve_plan)
    end

    test "idle cannot go directly to :verifying" do
      sm = StateMachine.new("t")
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :waves_complete)
    end

    test "idle cannot go directly to :completed" do
      sm = StateMachine.new("t")
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :verification_passed)
    end

    test "planning cannot go to :verifying" do
      sm = advance_to(:planning)
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :waves_complete)
    end

    test "executing cannot go to :completed directly" do
      sm = advance_to(:executing)
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :verification_passed)
    end

    test "completed is a terminal state — no transitions out" do
      sm = advance_to(:completed)
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :start_planning)
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :replan)
    end

    test "bogus event returns :invalid_transition" do
      sm = StateMachine.new("t")
      assert {:error, :invalid_transition} = StateMachine.transition(sm, :bogus_event)
    end
  end

  # ── can_transition?/2 ──────────────────────────────────────────────

  describe "can_transition?/2" do
    test "idle can transition to planning" do
      sm = StateMachine.new("t")
      assert StateMachine.can_transition?(sm, :planning)
    end

    test "idle cannot transition to executing" do
      sm = StateMachine.new("t")
      refute StateMachine.can_transition?(sm, :executing)
    end

    test "error_recovery can transition to planning or completed" do
      sm = advance_to(:error_recovery)
      assert StateMachine.can_transition?(sm, :planning)
      assert StateMachine.can_transition?(sm, :completed)
      refute StateMachine.can_transition?(sm, :executing)
    end
  end

  # ── current_phase/1 ───────────────────────────────────────────────

  describe "current_phase/1" do
    test "returns the current phase atom" do
      sm = StateMachine.new("t")
      assert StateMachine.current_phase(sm) == :idle

      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert StateMachine.current_phase(sm) == :planning
    end
  end

  # ── Permission Tiers ──────────────────────────────────────────────

  describe "permission_tier/1" do
    test ":idle phase has :none permissions" do
      sm = StateMachine.new("t")
      assert StateMachine.permission_tier(sm) == :none
    end

    test ":planning phase has :read_only permissions" do
      sm = advance_to(:planning)
      assert StateMachine.permission_tier(sm) == :read_only
    end

    test ":executing phase has :full permissions" do
      sm = advance_to(:executing)
      assert StateMachine.permission_tier(sm) == :full
    end

    test ":verifying phase has :read_and_test permissions" do
      sm = advance_to(:verifying)
      assert StateMachine.permission_tier(sm) == :read_and_test
    end

    test ":error_recovery phase has :read_only permissions" do
      sm = advance_to(:error_recovery)
      assert StateMachine.permission_tier(sm) == :read_only
    end

    test ":completed phase has :none permissions" do
      sm = advance_to(:completed)
      assert StateMachine.permission_tier(sm) == :none
    end
  end

  # ── Transition History ─────────────────────────────────────────────

  describe "history/1" do
    test "empty for new state machine" do
      sm = StateMachine.new("t")
      assert StateMachine.history(sm) == []
    end

    test "records transitions in chronological order" do
      sm = StateMachine.new("t")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)

      history = StateMachine.history(sm)
      assert length(history) == 2

      [first, second] = history
      assert first.from == :idle
      assert first.to == :planning
      assert first.event == :start_planning
      assert second.from == :planning
      assert second.to == :executing
      assert second.event == :approve_plan
    end

    test "history entries have timestamps" do
      sm = StateMachine.new("t")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)

      [entry] = StateMachine.history(sm)
      assert %DateTime{} = entry.timestamp
    end

    test "failed transitions do not appear in history" do
      sm = StateMachine.new("t")
      {:error, :invalid_transition} = StateMachine.transition(sm, :approve_plan)
      assert StateMachine.history(sm) == []
    end
  end

  # ── Error Count ────────────────────────────────────────────────────

  describe "error_count" do
    test "increments when entering :error_recovery" do
      sm = advance_to(:executing)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.error_count == 1
    end

    test "increments each time error_recovery is entered" do
      sm = advance_to(:executing)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.error_count == 1

      # replan → planning → executing → error_recovery again
      {:ok, sm} = StateMachine.transition(sm, :replan)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.error_count == 2
    end

    test "does not increment on non-error transitions" do
      sm = advance_to(:completed)
      assert sm.error_count == 0
    end
  end

  # ── Phase-Gated Setters ───────────────────────────────────────────

  describe "set_plan/2" do
    test "sets plan in :planning phase" do
      sm = advance_to(:planning)
      plan = %{steps: ["a", "b"], estimated_agents: 3}
      assert {:ok, sm} = StateMachine.set_plan(sm, plan)
      assert sm.plan == plan
    end

    test "rejects plan in non-planning phase" do
      sm = StateMachine.new("t")
      assert {:error, :wrong_phase} = StateMachine.set_plan(sm, %{})
    end
  end

  describe "add_wave_result/2" do
    test "appends wave result in :executing phase" do
      sm = advance_to(:executing)
      r1 = %{wave: 1, status: :ok}
      r2 = %{wave: 2, status: :ok}
      {:ok, sm} = StateMachine.add_wave_result(sm, r1)
      {:ok, sm} = StateMachine.add_wave_result(sm, r2)
      assert sm.wave_results == [r1, r2]
    end

    test "rejects wave result in non-executing phase" do
      sm = advance_to(:planning)
      assert {:error, :wrong_phase} = StateMachine.add_wave_result(sm, %{wave: 1})
    end
  end

  describe "set_verification/2" do
    test "sets verification in :verifying phase" do
      sm = advance_to(:verifying)
      v = %{tests_passed: 42, coverage: 0.87}
      assert {:ok, sm} = StateMachine.set_verification(sm, v)
      assert sm.verification == v
    end

    test "rejects verification in non-verifying phase" do
      sm = advance_to(:executing)
      assert {:error, :wrong_phase} = StateMachine.set_verification(sm, %{})
    end
  end

  # ── Full Lifecycle ─────────────────────────────────────────────────

  describe "full lifecycle" do
    test "happy path: idle → planning → executing → verifying → completed" do
      sm = StateMachine.new("lifecycle-1")
      assert sm.phase == :idle

      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert sm.phase == :planning

      {:ok, sm} = StateMachine.set_plan(sm, %{agents: 3})

      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      assert sm.phase == :executing

      {:ok, sm} = StateMachine.add_wave_result(sm, %{wave: 1, ok: true})

      {:ok, sm} = StateMachine.transition(sm, :waves_complete)
      assert sm.phase == :verifying

      {:ok, sm} = StateMachine.set_verification(sm, %{passed: true})

      {:ok, sm} = StateMachine.transition(sm, :verification_passed)
      assert sm.phase == :completed

      assert length(StateMachine.history(sm)) == 4
      assert sm.error_count == 0
    end

    test "replan cycle: execute fails → error_recovery → replan → execute → verify → complete" do
      sm = StateMachine.new("replan-1")

      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :wave_failure)
      assert sm.phase == :error_recovery
      assert sm.error_count == 1

      {:ok, sm} = StateMachine.transition(sm, :replan)
      assert sm.phase == :planning

      {:ok, sm} = StateMachine.transition(sm, :approve_plan)
      {:ok, sm} = StateMachine.transition(sm, :waves_complete)
      {:ok, sm} = StateMachine.transition(sm, :verification_passed)
      assert sm.phase == :completed
      assert sm.error_count == 1

      assert length(StateMachine.history(sm)) == 7
    end

    test "verification failure → error_recovery → manual_override → completed" do
      sm = advance_to(:verifying)
      {:ok, sm} = StateMachine.transition(sm, :verification_failed)
      assert sm.phase == :error_recovery
      assert sm.error_count == 1

      {:ok, sm} = StateMachine.transition(sm, :manual_override)
      assert sm.phase == :completed
    end

    test "plan rejection returns to idle, can re-enter planning" do
      sm = StateMachine.new("t")
      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      {:ok, sm} = StateMachine.transition(sm, :reject_plan)
      assert sm.phase == :idle

      {:ok, sm} = StateMachine.transition(sm, :start_planning)
      assert sm.phase == :planning
    end
  end

  # ── phases/0 ───────────────────────────────────────────────────────

  describe "phases/0" do
    test "returns all 6 phases" do
      phases = StateMachine.phases()
      assert length(phases) == 6
      assert :idle in phases
      assert :planning in phases
      assert :executing in phases
      assert :verifying in phases
      assert :error_recovery in phases
      assert :completed in phases
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp advance_to(:planning) do
    sm = StateMachine.new("t")
    {:ok, sm} = StateMachine.transition(sm, :start_planning)
    sm
  end

  defp advance_to(:executing) do
    sm = advance_to(:planning)
    {:ok, sm} = StateMachine.transition(sm, :approve_plan)
    sm
  end

  defp advance_to(:verifying) do
    sm = advance_to(:executing)
    {:ok, sm} = StateMachine.transition(sm, :waves_complete)
    sm
  end

  defp advance_to(:error_recovery) do
    sm = advance_to(:executing)
    {:ok, sm} = StateMachine.transition(sm, :wave_failure)
    sm
  end

  defp advance_to(:completed) do
    sm = advance_to(:verifying)
    {:ok, sm} = StateMachine.transition(sm, :verification_passed)
    sm
  end
end
