defmodule Daemon.Supervisors.AgentServices do
  @moduledoc """
  Subsystem supervisor for agent intelligence processes.

  Manages the always-on agent runtime services plus the adaptive control-plane
  subtree.

  Uses `:one_for_one` — agent services are independent enough that a
  crash in one (e.g. Scheduler) should not restart all others.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Mnesia backend was never implemented — always use ETS
    knowledge_backend = MiosaKnowledge.Backend.ETS

    children = core_runtime_children(knowledge_backend) ++ [Daemon.Supervisors.Adaptation]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp core_runtime_children(knowledge_backend) do
    [
      Daemon.Agent.Memory,
      Daemon.Agent.HeartbeatState,
      Daemon.Agent.Tasks,
      MiosaBudget.Budget,
      Daemon.Agent.Orchestrator,
      Daemon.Agent.Progress,
      Daemon.Agent.Hooks,
      Daemon.Agent.Learning,
      %{
        id: Daemon.Supervisors.Knowledge,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               {MiosaKnowledge.Store, store_id: "osa_default", backend: knowledge_backend},
               Daemon.Knowledge.Meta,
               Daemon.Agent.Memory.KnowledgeBridge
             ],
             [strategy: :rest_for_one, name: Daemon.Supervisors.Knowledge]
           ]}
      },
      Daemon.Vault.Supervisor,
      Daemon.Agent.Scheduler,
      Daemon.Agent.Compactor,
      Daemon.Agent.Cortex,
      Daemon.Agent.ProactiveMode,
      Daemon.Webhooks.Dispatcher,
      Daemon.Signal.Persistence
    ]
  end
end
