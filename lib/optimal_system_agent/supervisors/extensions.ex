defmodule OptimalSystemAgent.Supervisors.Extensions do
  @moduledoc """
  Subsystem supervisor for optional/extension processes.

  Manages conditionally-started subsystems: treasury, Signal Theory intelligence,
  swarm coordination, fleet management, sidecars (Go/Python), sandbox, wallet,
  OTA updater, and AMQP publisher.

  All children here are either opt-in (via config flags) or entirely self-contained.
  Uses `:one_for_one` — extensions are independent; a fleet crash should not
  restart the sidecar manager or the AMQP publisher.
  """
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      treasury_children() ++
      cost_tracker_children() ++
      intelligence_children() ++
      swarm_children() ++
      fleet_children() ++
      sidecar_children() ++
      sandbox_children() ++
      wallet_children() ++
      updater_children() ++
      amqp_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Treasury — opt-in via OSA_TREASURY_ENABLED=true
  defp treasury_children do
    if Application.get_env(:optimal_system_agent, :treasury_enabled, false) do
      Logger.info("[Extensions] Treasury enabled — starting MiosaBudget.Treasury")
      [MiosaBudget.Treasury]
    else
      []
    end
  end

  defp cost_tracker_children do
    [OptimalSystemAgent.Agent.CostTracker]
  end

  # Communication intelligence (Signal Theory unique) — always started when present.
  # ConversationTracker, ContactDetector, ProactiveMonitor are dormant until wired;
  # starting the supervisor is cheap and keeps them ready for future integration.
  defp intelligence_children do
    [OptimalSystemAgent.Intelligence.Supervisor]
  end

  # Swarm coordination: Mailbox (ETS), SwarmMode (GenServer), AgentPool (DynamicSupervisor).
  # Must start Mailbox first so the ETS table is available before SwarmMode starts.
  defp swarm_children do
    Logger.info("[Extensions] Swarm coordination starting")

    [
      OptimalSystemAgent.Agent.Orchestrator.Mailbox,
      OptimalSystemAgent.Agent.Orchestrator.SwarmMode,
      {DynamicSupervisor,
       name: OptimalSystemAgent.Agent.Orchestrator.SwarmMode.AgentPool,
       strategy: :one_for_one,
       max_children: 50}
    ]
  end

  # Fleet management (registry + sentinels) — opt-in via OSA_FLEET_ENABLED=true
  defp fleet_children do
    if Application.get_env(:optimal_system_agent, :fleet_enabled, false) do
      Logger.info("[Extensions] Fleet enabled — starting Fleet.Supervisor")
      [OptimalSystemAgent.Fleet.Supervisor]
    else
      []
    end
  end

  # Unified sidecar startup: Manager first (creates registry + circuit breaker tables),
  # then individual sidecars based on config flags.
  defp sidecar_children do
    manager = [OptimalSystemAgent.Sidecar.Manager]

    go =
      if Application.get_env(:optimal_system_agent, :go_tokenizer_enabled, false) do
        Logger.info("[Extensions] Go tokenizer enabled — starting Go.Tokenizer")
        [OptimalSystemAgent.Go.Tokenizer]
      else
        []
      end

    python =
      if Application.get_env(:optimal_system_agent, :python_sidecar_enabled, false) do
        Logger.info("[Extensions] Python sidecar enabled — starting Python.Supervisor")
        [OptimalSystemAgent.Python.Supervisor]
      else
        []
      end

    go_git =
      if Application.get_env(:optimal_system_agent, :go_git_enabled, false) do
        Logger.info("[Extensions] Go git sidecar enabled — starting Go.Git")
        [OptimalSystemAgent.Go.Git]
      else
        []
      end

    go_sysmon =
      if Application.get_env(:optimal_system_agent, :go_sysmon_enabled, false) do
        Logger.info("[Extensions] Go sysmon sidecar enabled — starting Go.Sysmon")
        [OptimalSystemAgent.Go.Sysmon]
      else
        []
      end

    whatsapp_web =
      if Application.get_env(:optimal_system_agent, :whatsapp_web_enabled, false) do
        Logger.info("[Extensions] WhatsApp Web sidecar enabled — starting WhatsAppWeb")
        [OptimalSystemAgent.WhatsAppWeb]
      else
        []
      end

    manager ++ go ++ python ++ go_git ++ go_sysmon ++ whatsapp_web
  end

  # Only add Sandbox.Supervisor to the tree when the sandbox is enabled.
  defp sandbox_children do
    if Application.get_env(:optimal_system_agent, :sandbox_enabled, false) do
      Logger.info("[Extensions] Sandbox enabled — starting Sandbox.Supervisor")
      [OptimalSystemAgent.Sandbox.Supervisor]
    else
      []
    end
  end

  # Wallet integration — opt-in via OSA_WALLET_ENABLED=true
  defp wallet_children do
    if Application.get_env(:optimal_system_agent, :wallet_enabled, false) do
      Logger.info("[Extensions] Wallet enabled — starting Wallet + Mock provider")

      [
        OptimalSystemAgent.Integrations.Wallet.Mock,
        OptimalSystemAgent.Integrations.Wallet
      ]
    else
      []
    end
  end

  # OTA updater — opt-in via OSA_UPDATE_ENABLED=true
  defp updater_children do
    if Application.get_env(:optimal_system_agent, :update_enabled, false) do
      Logger.info("[Extensions] OTA updater enabled — starting System.Updater")
      [OptimalSystemAgent.System.Updater]
    else
      []
    end
  end

  # AMQP publisher — opt-in via AMQP_URL
  defp amqp_children do
    if Application.get_env(:optimal_system_agent, :amqp_url) do
      Logger.info("[Extensions] AMQP enabled — starting Platform.AMQP publisher")
      [OptimalSystemAgent.Platform.AMQP]
    else
      []
    end
  end
end
