defmodule OptimalSystemAgent.Application do
  @moduledoc """
  OTP Application supervisor for the Optimal System Agent.

  The supervision tree is organised into 4 logical subsystem supervisors
  plus the HTTP server and deferred channel startup:

    Infrastructure  — registries, pub/sub, event bus, storage, telemetry,
                      provider/tool routing, MCP integration
    Sessions        — channel adapters, event stream registry, session DynamicSupervisor
    AgentServices   — memory, workflow, orchestration, hooks, learning, scheduler, etc.
    Extensions      — opt-in subsystems: treasury, intelligence, swarm, fleet,
                      sidecars, sandbox, wallet, updater, AMQP

  The top-level strategy remains `:rest_for_one` so that a crash in
  Infrastructure (core) tears down everything above it, while each subsystem
  supervisor uses the strategy most appropriate for its children.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Application.put_env(:optimal_system_agent, :start_time, System.system_time(:second))

    # ETS table for Loop cancel flags — must exist before any agent session starts.
    # public + set so Loop.cancel/1 and run_loop can read/write concurrently.
    :ets.new(:osa_cancel_flags, [:named_table, :public, :set])

    # ETS table for read-before-write tracking — tracks which files have been read
    # per session so the pre_tool_use hook can nudge when writing unread files.
    :ets.new(:osa_files_read, [:named_table, :public, :set])

    # ETS table for ask_user_question survey answers — the HTTP endpoint writes
    # answers here, Loop.ask_user_question/4 polls and consumes them.
    :ets.new(:osa_survey_answers, [:set, :public, :named_table])

    # ETS table for caching Ollama model context window sizes — avoids repeated
    # /api/show HTTP calls since context_length doesn't change without re-pull.
    :ets.new(:osa_context_cache, [:set, :public, :named_table])

    children =
      platform_repo_children() ++
      [
        OptimalSystemAgent.Supervisors.Infrastructure,
        OptimalSystemAgent.Supervisors.Sessions,
        OptimalSystemAgent.Supervisors.AgentServices,
        OptimalSystemAgent.Supervisors.Extensions,

        # Deferred channel startup — starts configured channels in handle_continue
        OptimalSystemAgent.Channels.Starter,

        # HTTP channel — Plug/Bandit on port 8089 (SDK API surface)
        # Started LAST so all agent processes are ready before accepting requests
        {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()}
      ]

    opts = [strategy: :rest_for_one, name: OptimalSystemAgent.Supervisor]

    # Load soul/personality files into persistent_term BEFORE supervision tree
    # starts — agents need identity/soul content from their first LLM call.
    OptimalSystemAgent.Soul.load()
    OptimalSystemAgent.PromptLoader.load()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Auto-detect best Ollama model + tier assignments SYNCHRONOUSLY at boot
        # so the banner shows the correct model (not a stale fallback)
        OptimalSystemAgent.Providers.Ollama.auto_detect_model()
        OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()

        # Start MCP servers asynchronously — don't block boot if servers are slow.
        # After servers initialise, register their tools in Tools.Registry.
        # Start knowledge graph (Mnesia-backed, distributed-ready)
        start_knowledge_store()

        Task.start(fn ->
          OptimalSystemAgent.MCP.Client.start_servers()
          # Block on list_tools() — it's a GenServer.call that queues behind initialize.
          # No sleep needed; we wait for all servers to complete their JSON-RPC handshake.
          OptimalSystemAgent.MCP.Client.list_tools()
          OptimalSystemAgent.Tools.Registry.register_mcp_tools()
        end)

        {:ok, pid}

      error ->
        error
    end
  end

  # Platform PostgreSQL repo — opt-in via DATABASE_URL
  # Started at the top level (before Infrastructure) so platform DB is available
  # to any child that needs it during init.
  defp platform_repo_children do
    if Application.get_env(:optimal_system_agent, :platform_enabled, false) do
      Logger.info("[Application] Platform enabled — starting Platform.Repo")
      [OptimalSystemAgent.Platform.Repo]
    else
      []
    end
  end

  defp start_knowledge_store do
    backend =
      if Mix.env() == :test,
        do: MiosaKnowledge.Backend.ETS,
        else: MiosaKnowledge.Backend.Mnesia

    case MiosaKnowledge.open("osa_default", backend: backend) do
      {:ok, _pid} ->
        Logger.info("[Application] Knowledge store started (#{inspect(backend)})")

      {:error, reason} ->
        Logger.warning("[Application] Knowledge store failed to start: #{inspect(reason)}")
    end
  end

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 8089)
      port -> String.to_integer(port)
    end
  end
end
