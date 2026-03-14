defmodule OptimalSystemAgent.Supervisors.AgentServices do
  @moduledoc """
  Subsystem supervisor for agent intelligence processes.

  Manages all GenServer-based agent services: memory, workflow tracking,
  budget, task queuing, orchestration, progress reporting, hooks,
  learning, scheduling, context compaction, and cortex synthesis.

  Uses `:one_for_one` — agent services are independent enough that a
  crash in one (e.g. Scheduler) should not restart all others.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    knowledge_backend =
      if Mix.env() == :test,
        do: MiosaKnowledge.Backend.ETS,
        else: MiosaKnowledge.Backend.Mnesia

    children = [
      OptimalSystemAgent.Agent.Memory,
      OptimalSystemAgent.Agent.HeartbeatState,
      OptimalSystemAgent.Agent.Tasks,
      MiosaBudget.Budget,
      OptimalSystemAgent.Agent.Orchestrator,
      OptimalSystemAgent.Agent.Progress,
      OptimalSystemAgent.Agent.Hooks,
      OptimalSystemAgent.Agent.Learning,
      {MiosaKnowledge.Store, store_id: "osa_default", backend: knowledge_backend},
      OptimalSystemAgent.Agent.Memory.KnowledgeBridge,
      OptimalSystemAgent.Vault.Supervisor,
      OptimalSystemAgent.Agent.Scheduler,
      OptimalSystemAgent.Agent.Compactor,
      OptimalSystemAgent.Agent.Cortex,
      OptimalSystemAgent.Agent.ProactiveMode,
      OptimalSystemAgent.Webhooks.Dispatcher,
      OptimalSystemAgent.Signal.Persistence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
