defmodule OptimalSystemAgent.Channels.HTTP.API.CostRoutes do
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.CostTracker

  plug :match
  plug :dispatch

  get "/" do
    case List.last(conn.script_name) do
      "budgets" -> handle_budgets(conn)
      _ -> handle_summary(conn)
    end
  end

  get "/by-agent" do
    json(conn, 200, %{agents: CostTracker.get_by_agent()})
  end

  get "/by-model" do
    json(conn, 200, %{models: CostTracker.get_by_model()})
  end

  get "/events" do
    {page, per_page} = pagination_params(conn)
    agent_name = conn.query_params["agent_name"]

    opts =
      [page: page, per_page: per_page]
      |> maybe_put(:agent_name, agent_name)

    events = CostTracker.get_events(opts)
    json(conn, 200, %{events: events, page: page, per_page: per_page})
  end

  @max_daily 1_000_000
  @max_monthly 10_000_000

  put "/:agent_name" do
    agent_name = conn.params["agent_name"]

    with %{"budget_daily_cents" => daily, "budget_monthly_cents" => monthly} <- conn.body_params,
         true <- is_integer(daily) and daily > 0 and daily <= @max_daily,
         true <- is_integer(monthly) and monthly > 0 and monthly <= @max_monthly do
      CostTracker.update_budget(agent_name, budget_daily_cents: daily, budget_monthly_cents: monthly)
      json(conn, 200, %{status: "updated", agent_name: agent_name})
    else
      _ -> json_error(conn, 422, "unprocessable_entity", "Invalid budget: positive integers required, daily max $10K, monthly max $100K")
    end
  end

  post "/:agent_name/reset" do
    agent_name = conn.params["agent_name"]
    CostTracker.reset_budget(agent_name)
    json(conn, 200, %{status: "reset", agent_name: agent_name})
  end

  match _ do
    json_error(conn, 404, "not_found", "Cost endpoint not found")
  end

  defp handle_summary(conn), do: json(conn, 200, CostTracker.get_summary())
  defp handle_budgets(conn), do: json(conn, 200, %{budgets: CostTracker.get_budgets()})
end
