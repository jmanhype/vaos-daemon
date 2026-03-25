defmodule Daemon.SDK.Supervisor do
  @moduledoc """
  Supervision tree for embedded SDK mode.

  Starts the subset of OSA processes needed for SDK operation:
  Registry, PubSub, Bus, Repo, Providers, Tools, Memory, Budget, Hooks,
  Learning, Orchestrator, Progress, TaskQueue, Compactor, Swarm, and
  optionally Bandit.

  Excludes CLI-only processes: Channels.Manager, Scheduler, Cortex,
  HeartbeatState, Fleet, Sandbox, Wallet, Updater, OS.Registry, Machines.

  ## Usage

      config = %Daemon.SDK.Config{
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        max_budget_usd: 10.0
      }

      children = [{Daemon.SDK.Supervisor, config}]
  """

  use Supervisor
  require Logger

  alias Daemon.SDK.Config

  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(%Config{} = config) do
    # Initialize SDK agent ETS table
    Daemon.SDK.Agent.init_table()

    # Wire Application env BEFORE children start (so Budget/Providers pick it up)
    wire_app_env(config)

    # Load soul/personality into persistent_term
    try do
      Daemon.Soul.load()
      Daemon.PromptLoader.load()
    rescue
      _ -> :ok
    end

    children =
      [
        # Process registry
        {Registry, keys: :unique, name: Daemon.SessionRegistry},

        # Core infrastructure
        {Phoenix.PubSub, name: Daemon.PubSub},
        Daemon.Events.Bus,
        Daemon.Bridge.PubSub,
        Daemon.Store.Repo,

        # LLM providers
        MiosaProviders.Registry,

        # Tools
        Daemon.Tools.Registry,

        # Channel supervisor (for session Loop processes)
        {DynamicSupervisor, name: Daemon.Channels.Supervisor, strategy: :one_for_one},

        # Agent processes — full set needed by Loop + Orchestrator
        Daemon.Agent.Memory,
        MiosaBudget.Budget,
        Daemon.Agent.Tasks,
        Daemon.Agent.Orchestrator,
        Daemon.Agent.Progress,
        Daemon.Agent.Hooks,
        Daemon.Agent.Learning,
        Daemon.Agent.Compactor,

        # Intelligence (Signal Theory)
        Daemon.Intelligence.Supervisor,

        # Swarm coordination
        Daemon.Agent.Orchestrator.Mailbox,
        Daemon.Agent.Orchestrator.SwarmMode,
        {DynamicSupervisor,
         name: Daemon.Agent.Orchestrator.SwarmMode.AgentPool,
         strategy: :one_for_one,
         max_children: 10}
      ] ++ http_children(config)

    # Register SDK extensions after tree is up
    Task.start(fn ->
      Process.sleep(100)
      register_config_tools(config)
      register_config_agents(config)
      register_config_hooks(config)
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ── Config Wiring (pre-boot — sets Application env before children start) ──

  defp wire_app_env(%Config{} = config) do
    # Set default provider (Budget + Providers read this at init)
    if config.provider do
      Application.put_env(:daemon, :default_provider, config.provider)
    end

    # Set default model override
    if config.model do
      Application.put_env(:daemon, :default_model, config.model)
    end

    # Set budget limit so Agent.Budget picks it up at init
    if config.max_budget_usd do
      Application.put_env(:daemon, :daily_budget_usd, config.max_budget_usd)
    end
  rescue
    _ -> :ok
  end

  # ── Child Specs ──────────────────────────────────────────────────

  defp http_children(%Config{http_port: nil}), do: []

  defp http_children(%Config{http_port: port}) when is_integer(port) do
    [{Bandit, plug: Daemon.Channels.HTTP, port: port}]
  end

  # ── Config Registration ──────────────────────────────────────────

  defp register_config_tools(%Config{tools: tools}) do
    Enum.each(tools, fn
      {name, desc, params, handler} ->
        Daemon.SDK.Tool.define(name, desc, params, handler)

      module when is_atom(module) ->
        Daemon.Tools.Registry.register(module)
    end)
  end

  defp register_config_agents(%Config{agents: agents}) do
    Enum.each(agents, fn
      %{name: name} = def_map -> Daemon.SDK.Agent.define(name, def_map)
      {name, def_map} -> Daemon.SDK.Agent.define(name, def_map)
    end)
  end

  defp register_config_hooks(%Config{hooks: hooks}) do
    Enum.each(hooks, fn
      {event, name, handler, opts} ->
        Daemon.SDK.Hook.register(event, name, handler, opts)

      {event, name, handler} ->
        Daemon.SDK.Hook.register(event, name, handler)
    end)
  end
end
