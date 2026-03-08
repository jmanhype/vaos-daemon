defmodule OptimalSystemAgent.Channels.HTTP.API.DataRoutes do
  @moduledoc """
  Data management routes forwarded from multiple prefixes.

  Forwarded prefixes → effective routes:
    /memory     → GET /recall, GET /search, POST /
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
  alias MiosaProviders
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

  # ── GET /search — memory search ────────────────────────────────────
  # Query params: q (required), category (optional), limit (optional, default 10),
  #               sort (optional: relevance|recency|importance), mode (optional: relevant|keyword)

  get "/search" do
    query = conn.query_params["q"]

    if is_nil(query) or query == "" do
      json_error(conn, 400, "invalid_request", "Missing required query param: q")
    else
      mode = conn.query_params["mode"] || "keyword"
      limit = parse_int(conn.query_params["limit"]) || 10
      category = conn.query_params["category"]
      sort = parse_sort_atom(conn.query_params["sort"])

      results =
        if mode == "relevant" do
          max_tokens = limit * 200
          Memory.recall_relevant(query, max_tokens)
        else
          opts =
            [limit: limit, sort: sort]
            |> maybe_put(:category, category)

          Memory.search(query, opts)
        end

      body = Jason.encode!(%{results: results, count: length(results), query: query})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
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
    valid_providers = MiosaProviders.Registry.list_providers()
    valid_names = Enum.map(valid_providers, &Atom.to_string/1)

    with %{"provider" => prov_str, "model" => model_name} <- conn.body_params,
         true <- prov_str in valid_names,
         provider <- String.to_existing_atom(prov_str) do
      Application.put_env(:optimal_system_agent, :default_provider, provider)
      Application.put_env(:optimal_system_agent, :default_model, model_name)

      if provider == :ollama do
        Application.put_env(:optimal_system_agent, :ollama_model, model_name)
      end

      # Persist selection to ~/.osa/config.json so it survives restarts.
      persist_model_selection(prov_str, model_name)

      Logger.info("[Models] Switched to #{prov_str}/#{model_name}")

      context_window = MiosaProviders.Registry.context_window(model_name)
      body = Jason.encode!(%{provider: prov_str, model: model_name, status: "ok", context_window: context_window})

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
      try do
        case MiosaProviders.Ollama.list_models() do
          {:ok, models} ->
            Enum.map(models, fn m ->
              ctx = try do MiosaProviders.Registry.context_window(m.name) rescue _ -> 128_000 end
              %{
                name: m.name,
                provider: "ollama",
                size: m.size,
                active: to_string(provider) == "ollama" and m.name == current_model,
                context_window: ctx
              }
            end)

          _ ->
            []
        end
      rescue
        _ -> []
      end

    cloud_models =
      try do
        MiosaProviders.Registry.list_providers()
        |> Enum.reject(&(&1 == :ollama))
        |> Enum.filter(&MiosaProviders.Registry.provider_configured?/1)
        |> Enum.flat_map(fn p ->
          case MiosaProviders.Registry.provider_info(p) do
            {:ok, info} ->
              Enum.map(info.available_models, fn model_name ->
                ctx = try do MiosaProviders.Registry.context_window(model_name) rescue _ -> 128_000 end
                %{
                  name: model_name,
                  provider: to_string(p),
                  size: 0,
                  active: provider == p and model_name == current_model,
                  context_window: ctx
                }
              end)

            _ ->
              []
          end
        end)
      rescue
        _ -> []
      end

    all_models =
      (ollama_models ++ cloud_models)
      |> Enum.sort_by(& &1.context_window, :desc)

    body =
      Jason.encode!(%{
        models: all_models,
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
        case MiosaBudget.Budget.get_status() do
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

  defp parse_sort_atom("recency"), do: :recency
  defp parse_sort_atom("importance"), do: :importance
  defp parse_sort_atom(_), do: :relevance

  # Persist provider/model selection to ~/.osa/config.json so it survives restarts.
  # Reads existing config (if any), merges the two keys, and writes back atomically.
  defp persist_model_selection(provider, model) do
    config_path =
      Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
      |> Path.expand()
      |> Path.join("config.json")

    existing =
      with true <- File.exists?(config_path),
           {:ok, content} <- File.read(config_path),
           {:ok, parsed} <- Jason.decode(content) do
        parsed
      else
        _ -> %{}
      end

    updated = Map.merge(existing, %{"provider" => provider, "model" => model})

    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        File.mkdir_p!(Path.dirname(config_path))
        File.write!(config_path, json)

      {:error, reason} ->
        Logger.warning("[Models] Failed to persist model selection: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[Models] Config persist error: #{Exception.message(e)}")
  end
end
