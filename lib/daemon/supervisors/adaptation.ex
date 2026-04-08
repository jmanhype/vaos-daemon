defmodule Daemon.Supervisors.Adaptation do
  @moduledoc """
  Subsystem supervisor for VAOS adaptive control-plane services.

  Owns the always-on adaptive workers that tune research behavior, learn from
  tool outcomes, diagnose recurring failures, and coordinate autonomous action
  provenance.

  Uses `:one_for_one` — adaptive workers are intentionally isolated so a crash
  in one loop (for example `Retrospector`) does not restart the others.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Daemon.Investigation.Retrospector,
      {Vaos.Ledger.ML.CrashLearner, name: :daemon_crash_learner},
      Daemon.Investigation.SelfDiagnosis,
      Daemon.Intelligence.DecisionLedger,
      Daemon.Agent.SkillEvolution,
      Daemon.Agent.ActiveLearner,
      Daemon.Intelligence.DecisionJournal,
      Daemon.Intelligence.AdaptationHeartbeat,
      Daemon.Intelligence.ProactiveMonitor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
