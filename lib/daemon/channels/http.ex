defmodule Daemon.Channels.HTTP do
  @moduledoc """
  HTTP channel adapter — Plug.Router served by Bandit on port 8089.

  This is the API surface that MIOSA SDK clients consume. Symmetrical with
  CLI, Telegram, and other channel adapters — all signals go through the
  same Agent.Loop pipeline.

  Endpoints (v1):
    POST /api/v1/orchestrate           Full ReAct agent loop
    GET  /api/v1/stream/:session_id    SSE event stream
    GET  /api/v1/tools                 List executable tools
    POST /api/v1/tools/:name/execute   Execute a tool by name
    GET  /api/v1/skills                List SKILL.md prompt definitions
    POST /api/v1/skills/create         Create a new SKILL.md
    POST /api/v1/orchestrate/complex   Multi-agent orchestration
    POST /api/v1/swarm/launch          Launch agent swarm
    POST /api/v1/memory                Save to memory
    GET  /api/v1/memory/recall         Recall memory
    GET  /api/v1/machines              List active machines
    POST /api/v1/fleet/*               Fleet management (register, heartbeat, dispatch)
    POST /api/v1/channels/*/webhook    Channel adapter webhooks
    GET  /health                       Health check (no auth)

  Auth: HS256 JWT via Authorization: Bearer <token>
  Transport: HTTP/1.1 + SSE via Plug/Bandit
  """
  use Plug.Router
  require Logger

  plug(:security_headers)
  plug(:cors_headers)
  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  # ── Security headers ──────────────────────────────────────────────

  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("content-security-policy", "default-src 'none'")
    |> put_resp_header("strict-transport-security", "max-age=31536000; includeSubDomains")
  end

  # ── CORS middleware ────────────────────────────────────────────────

  defp cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization, accept, cache-control, x-accel-buffering")
    |> put_resp_header("access-control-max-age", "86400")
  end

  # ── OPTIONS preflight (CORS) ────────────────────────────────────────

  options _ do
    conn
    |> send_resp(204, "")
  end

  # ── Health (no auth) ────────────────────────────────────────────────

  @doc """
  Health check endpoint with graceful shutdown status.

  Returns 503 Service Unavailable if system is shutting down.
  """
  get "/health" do
    # Check if system is shutting down
    if Daemon.GracefulShutdown.shutting_down?() do
      body = Jason.encode!(%{
        status: "shutting_down",
        message: "System is gracefully shutting down"
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, body)
    else
      provider =
        Application.get_env(:daemon, :default_provider, "unknown")
        |> to_string()

      model_name =
        case Application.get_env(:daemon, :default_model) do
          nil ->
            # Resolve from provider's default model
            prov = Application.get_env(:daemon, :default_provider, :ollama)

            case MiosaProviders.Registry.provider_info(prov) do
              {:ok, info} -> to_string(info.default_model)
              _ -> to_string(prov)
            end

          m ->
            to_string(m)
        end

      version =
        case Application.spec(:daemon, :vsn) do
          nil -> "0.2.5"
          vsn -> to_string(vsn)
        end

      uptime = System.system_time(:second) - Application.get_env(:daemon, :start_time, System.system_time(:second))

      context_window = MiosaProviders.Registry.context_window(model_name)

      in_flight_tasks = Daemon.GracefulShutdown.task_count()

      body =
        Jason.encode!(%{
          status: "ok",
          version: version,
          uptime_seconds: uptime,
          provider: provider,
          model: model_name,
          context_window: context_window,
          in_flight_tasks: in_flight_tasks
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  # ── Onboarding (no auth) ──────────────────────────────────────

  get "/onboarding/status" do
    needs = Daemon.Onboarding.first_run?()
    system_info = Daemon.Onboarding.detect_system()
    providers = Daemon.Onboarding.providers_list()
    templates = Daemon.Onboarding.templates_list()
    machines = Daemon.Onboarding.machines_list()
    channels = Daemon.Onboarding.channels_list()

    body =
      Jason.encode!(%{
        needs_onboarding: needs,
        system_info: system_info,
        providers: providers,
        templates: templates,
        machines: machines,
        channels: channels
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/onboarding/setup" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        setup_onboarding(conn, raw)

      {:more, _partial, conn} ->
        conn |> put_resp_content_type("application/json") |> send_resp(413, ~s({"error":"payload_too_large"}))

      {:error, _reason} ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"read_failed"}))
    end
  end

  defp setup_onboarding(conn, raw) do
    case Jason.decode(raw) do
      {:ok, params} ->
        raw_provider = Map.get(params, "provider", "ollama")

        # Normalize "ollama_cloud" → "ollama" with remote URL + API key
        {provider, ollama_url} =
          if raw_provider == "ollama_cloud" do
            url = Map.get(params, "ollama_url", "https://ollama.lunivate.com")
            Application.put_env(:daemon, :ollama_url, url)
            {"ollama", url}
          else
            {raw_provider, nil}
          end

        api_key = Map.get(params, "api_key")

        # For Ollama Cloud, ensure API key is propagated
        if raw_provider == "ollama_cloud" and is_binary(api_key) and api_key != "" do
          Application.put_env(:daemon, :ollama_api_key, api_key)
          System.put_env("OLLAMA_API_KEY", api_key)
        end

        state = %{
          agent_name: Map.get(params, "agent_name", "Daemon"),
          user_name: Map.get(params, "user_name"),
          user_context: Map.get(params, "user_context"),
          provider: provider,
          model: Map.get(params, "model", "kimi-k2.5:cloud"),
          api_key: api_key,
          env_var: Map.get(params, "env_var") || (if raw_provider == "ollama_cloud", do: "OLLAMA_API_KEY"),
          machines: Map.get(params, "machines", %{"communication" => false, "productivity" => false, "research" => false}),
          channels_config: Map.get(params, "channels", %{}),
          os_template: Map.get(params, "os_template"),
          ollama_url: ollama_url
        }

        case Daemon.Onboarding.write_setup(state) do
          :ok ->
            Daemon.Onboarding.apply_config()

            # Reload soul files to pick up new IDENTITY.md/SOUL.md
            try do
              Daemon.Soul.reload()
            rescue
              _ -> :ok
            end

            # Auto-detect Ollama tiers if Ollama selected
            if state.provider == "ollama" do
              try do
                MiosaProviders.Ollama.auto_detect_model()
                Daemon.Agent.Tier.detect_ollama_tiers()
              rescue
                _ -> :ok
              end
            end

            # Connect OS template if specified
            if state.os_template do
              try do
                path = Map.get(state.os_template, "path")

                if is_binary(path) and path != "" do
                  Daemon.OS.Registry.connect(path)
                end
              rescue
                _ -> :ok
              end
            end

            # Run post-setup health checks
            checks =
              try do
                Daemon.Onboarding.doctor_checks()
                |> Enum.map(fn
                  {:ok, desc} -> %{status: "ok", check: desc}
                  {:error, desc, reason} -> %{status: "error", check: desc, reason: reason}
                end)
              rescue
                _ -> []
              end

            body =
              Jason.encode!(%{
                status: "ok",
                provider: state.provider,
                model: state.model,
                checks: checks
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {:error, reason} ->
            body = Jason.encode!(%{error: "setup_failed", details: reason})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, body)
        end

      {:error, _} ->
        body = Jason.encode!(%{error: "invalid_json"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, body)
    end
  end

  # ── Survey / waitlist (no auth — anonymous submissions) ─────────────

  post "/api/survey" do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(raw) do
      {:ok, body} ->
        result =
          if Application.get_env(:daemon, :platform_enabled, false) do
            Daemon.Platform.Surveys.create(body)
          else
            :ets.insert(:daemon_survey_responses, {System.unique_integer([:positive]), body, DateTime.utc_now()})
            {:ok, body}
          end

        case result do
          {:ok, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "collected"}))

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{error: "validation_failed", details: errors}))
        end

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "invalid_json"}))
    end
  end

  post "/api/waitlist" do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(raw) do
      {:ok, body} ->
        # Waitlist is a lightweight survey with just email + optional source
        attrs = Map.put_new(body, "role", "other")

        result =
          if Application.get_env(:daemon, :platform_enabled, false) do
            Daemon.Platform.Surveys.create(attrs)
          else
            :ets.insert(:daemon_survey_responses, {System.unique_integer([:positive]), attrs, DateTime.utc_now()})
            {:ok, attrs}
          end

        case result do
          {:ok, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "collected"}))

          {:error, _changeset} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{error: "validation_failed"}))
        end

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "invalid_json"}))
    end
  end

  # ── All /api routes require JWT ─────────────────────────────────────

  forward("/api/v1", to: Daemon.Channels.HTTP.API)

  # ── Catch-all ───────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end
