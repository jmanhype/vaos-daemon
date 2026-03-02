defmodule OptimalSystemAgent.Channels.HTTP.API.DataRoutes do
  @moduledoc """
  Data management routes forwarded from multiple prefixes.

  Forwarded prefixes → effective routes:
    /memory     → GET /recall, POST /
    /models     → GET /, POST /switch
    /analytics  → GET /
    /scheduler  → GET /jobs, POST /reload
    /webhooks   → POST /:trigger_id
    /machines   → GET /
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Machines

  plug :match
  plug :dispatch

  # ── GET / ─────────────────────────────────────────────────────────
  # Handles GET /models, GET /analytics, GET /machines after prefix strip.

  get "/" do
    case List.last(conn.script_name) do
      "analytics" -> handle_analytics(conn)
      "machines" -> handle_machines(conn)
      _ -> handle_list_models(conn)
    end
  end

  # ── GET /recall — memory recall ────────────────────────────────────

  get "/recall" do
    content = Memory.recall()

    body = Jason.encode!(%{content: content})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /jobs — scheduler jobs ─────────────────────────────────────

  get "/jobs" do
    jobs = Scheduler.list_jobs()

    body =
      Jason.encode!(%{
        jobs: jobs,
        count: length(jobs)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST / ────────────────────────────────────────────────────────
  # Handles POST /memory after prefix strip.

  post "/" do
    with %{"content" => content} <- conn.body_params do
      category = conn.body_params["category"] || "general"
      Memory.remember(content, category)

      body = Jason.encode!(%{status: "saved", category: category})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: content")
    end
  end

  # ── POST /switch — model switch ────────────────────────────────────

  post "/switch" do
    valid_providers = Providers.Registry.list_providers()
    valid_names = Enum.map(valid_providers, &Atom.to_string/1)

    with %{"provider" => prov_str, "model" => model_name} <- conn.body_params,
         true <- prov_str in valid_names,
         provider <- String.to_existing_atom(prov_str) do
      Application.put_env(:optimal_system_agent, :default_provider, provider)
      Application.put_env(:optimal_system_agent, :default_model, model_name)

      if provider == :ollama do
        Application.put_env(:optimal_system_agent, :ollama_model, model_name)
      end

      Logger.info("[Models] Switched to #{prov_str}/#{model_name}")

      body = Jason.encode!(%{provider: prov_str, model: model_name, status: "ok"})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      false ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "unknown provider"}))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "missing or invalid provider/model"}))
    end
  end

  # ── POST /reload — scheduler reload ───────────────────────────────

  post "/reload" do
    Scheduler.reload_crons()

    body = Jason.encode!(%{status: "reloading", message: "Scheduler reload queued"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  # ── POST /:trigger_id — webhook trigger ────────────────────────────

  post "/:trigger_id" do
    trigger_id = conn.params["trigger_id"]
    payload = conn.body_params || %{}

    Logger.info("Webhook received for trigger '#{trigger_id}'")

    Scheduler.fire_trigger(trigger_id, payload)

    body =
      Jason.encode!(%{
        status: "accepted",
        trigger_id: trigger_id,
        message: "Trigger queued for execution"
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Data endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

  defp handle_list_models(conn) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    current_model =
      Application.get_env(:optimal_system_agent, :default_model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")

    ollama_models =
      case Providers.Ollama.list_models() do
        {:ok, models} ->
          Enum.map(models, fn m ->
            %{
              name: m.name,
              provider: "ollama",
              size: m.size,
              active: to_string(provider) == "ollama" and m.name == current_model
            }
          end)

        _ ->
          []
      end

    cloud_models =
      Providers.Registry.list_providers()
      |> Enum.reject(&(&1 == :ollama))
      |> Enum.filter(&Providers.Registry.provider_configured?/1)
      |> Enum.flat_map(fn p ->
        case Providers.Registry.provider_info(p) do
          {:ok, info} ->
            Enum.map(info.available_models, fn model_name ->
              %{
                name: model_name,
                provider: to_string(p),
                size: 0,
                active: provider == p and model_name == current_model
              }
            end)

          _ ->
            []
        end
      end)

    body =
      Jason.encode!(%{
        models: ollama_models ++ cloud_models,
        current: to_string(current_model),
        provider: to_string(provider)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_analytics(conn) do
    budget =
      try do
        case OptimalSystemAgent.Agent.Budget.get_status() do
          {:ok, data} -> data
          data when is_map(data) -> data
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    learning =
      try do
        unwrap_ok(OptimalSystemAgent.Agent.Learning.metrics())
      rescue
        _ -> %{}
      end

    hooks =
      try do
        unwrap_ok(OptimalSystemAgent.Agent.Hooks.metrics())
      rescue
        _ -> %{}
      end

    compactor =
      try do
        unwrap_ok(OptimalSystemAgent.Agent.Compactor.stats())
      rescue
        _ -> %{}
      end

    live_sessions =
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    body =
      Jason.encode!(%{
        sessions: %{active: length(live_sessions)},
        budget: budget,
        learning: learning,
        hooks: hooks,
        compactor: compactor
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_machines(conn) do
    active = Machines.active()

    body =
      Jason.encode!(%{
        machines: active,
        count: length(active)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
