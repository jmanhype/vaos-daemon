defmodule Daemon.Supervisors.AdaptationSupervisorTest do
  use ExUnit.Case, async: true

  describe "Daemon.Supervisors.Adaptation" do
    test "owns the adaptive control-plane workers" do
      assert {:ok, {flags, child_specs}} = Daemon.Supervisors.Adaptation.init(nil)
      assert flags.strategy == :one_for_one

      ids = Enum.map(child_specs, & &1.id)

      assert ids == [
               Daemon.Investigation.Retrospector,
               Vaos.Ledger.ML.CrashLearner,
               Daemon.Investigation.SelfDiagnosis,
               Daemon.Intelligence.DecisionLedger,
               Daemon.Agent.SkillEvolution,
               Daemon.Agent.ActiveLearner,
               Daemon.Intelligence.DecisionJournal,
               Daemon.Intelligence.ProactiveMonitor
             ]
    end
  end

  describe "Daemon.Supervisors.AgentServices" do
    test "delegates adaptive workers to the adaptation subtree" do
      assert {:ok, {flags, child_specs}} = Daemon.Supervisors.AgentServices.init(nil)
      assert flags.strategy == :one_for_one

      ids = Enum.map(child_specs, & &1.id)

      assert Daemon.Supervisors.Adaptation in ids
      refute Daemon.Investigation.Retrospector in ids
      refute Daemon.Investigation.SelfDiagnosis in ids
      refute Daemon.Intelligence.DecisionLedger in ids
      refute Daemon.Agent.ActiveLearner in ids
      refute Daemon.Intelligence.DecisionJournal in ids
      refute Vaos.Ledger.ML.CrashLearner in ids
      refute Daemon.Intelligence.ProactiveMonitor in ids
    end
  end

  describe "Daemon.Intelligence.Supervisor" do
    test "keeps only communication intelligence children" do
      assert {:ok, {flags, child_specs}} = Daemon.Intelligence.Supervisor.init(:ok)
      assert flags.strategy == :one_for_one

      ids = Enum.map(child_specs, & &1.id)

      assert ids == [
               Daemon.Intelligence.CommProfiler,
               Daemon.Intelligence.CommCoach,
               Daemon.Intelligence.ConversationTracker
             ]
    end
  end
end
