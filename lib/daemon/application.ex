defmodule Daemon.Application do
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
    Application.put_env(:daemon, :start_time, System.system_time(:second))

    # LLM concurrency limiter — caps total in-flight API calls across all subsystems
    Daemon.Providers.ConcurrencyLimiter.init()

    # ETS table for Loop cancel flags — must exist before any agent session starts.
    # public + set so Loop.cancel/1 and run_loop can read/write concurrently.
    :ets.new(:daemon_cancel_flags, [:named_table, :public, :set])

    # ETS table for read-before-write tracking — tracks which files have been read
    # per session so the pre_tool_use hook can nudge when writing unread files.
    :ets.new(:daemon_files_read, [:named_table, :public, :set])

    # ETS table for ask_user_question survey answers — the HTTP endpoint writes
    # answers here, Loop.ask_user_question/4 polls and consumes them.
    :ets.new(:daemon_survey_answers, [:set, :public, :named_table])

    # ETS table for caching Ollama model context window sizes — avoids repeated
    # /api/show HTTP calls since context_length doesn't change without re-pull.
    :ets.new(:daemon_context_cache, [:set, :public, :named_table])

    # ETS table for survey/waitlist responses when platform DB is not enabled.
    # Rows: {unique_integer, body_map, datetime}
    :ets.new(:daemon_survey_responses, [:bag, :public, :named_table])

    # ETS table for per-session provider/model overrides set via hot-swap API.
    # Rows: {session_id, provider, model}
    :ets.new(:daemon_session_provider_overrides, [:named_table, :public, :set])

    # ETS table for tracking pending ask_user questions.
    # Lets GET /sessions/:id/pending_questions show when the agent is blocked.
    # Rows: {ref_string, %{session_id, question, options, asked_at}}
    :ets.new(:daemon_pending_questions, [:named_table, :public, :set])

    children =
      platform_repo_children() ++
      [
        # General-purpose Task.Supervisor for fire-and-forget async work
        # (HTTP message dispatch, background learning, etc.)
        {Task.Supervisor, name: Daemon.TaskSupervisor},

        Daemon.Supervisors.Infrastructure,
        Daemon.Supervisors.Sessions,
        Daemon.Supervisors.AgentServices,
        Daemon.Supervisors.Extensions,

        # Deferred channel startup — starts configured channels in handle_continue
        Daemon.Channels.Starter,

        # HTTP channel — Plug/Bandit on port 8089 (SDK API surface)
        # Started LAST so all agent processes are ready before accepting requests
        {Bandit, plug: Daemon.Channels.HTTP, port: http_port()}
      ]

    opts = [strategy: :rest_for_one, name: Daemon.Supervisor]

    # Load soul/personality files into persistent_term BEFORE supervision tree
    # starts — agents need identity/soul content from their first LLM call.
    Daemon.Soul.load()
    Daemon.PromptLoader.load()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Auto-detect best Ollama model + tier assignments SYNCHRONOUSLY at boot
        # so the banner shows the correct model (not a stale fallback)
        MiosaProviders.Ollama.auto_detect_model()
        Daemon.Agent.Tier.detect_ollama_tiers()

        # Start MCP servers asynchronously — don't block boot if servers are slow.
        # After servers initialise, register their tools in Tools.Registry.
        Task.start(fn ->
          Daemon.MCP.Client.start_servers()
          # Block on list_tools() — it's a GenServer.call that queues behind initialize.
          # No sleep needed; we wait for all servers to complete their JSON-RPC handshake.
          Daemon.MCP.Client.list_tools()
          Daemon.Tools.Registry.register_mcp_tools()
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
    if Application.get_env(:daemon, :platform_enabled, false) do
      Logger.info("[Application] Platform enabled — starting Platform.Repo")
      [Daemon.Platform.Repo]
    else
      []
    end
  end

  defp http_port do
    case System.get_env("DAEMON_HTTP_PORT") do
      nil -> Application.get_env(:daemon, :http_port, 8089)
      port -> String.to_integer(port)
    end
  end
end
