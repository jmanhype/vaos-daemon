defmodule OptimalSystemAgent.Channels.HTTP.API.AgentStateRoutes do

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  alias OptimalSystemAgent.Agent.Introspection

  plug :match
  plug :dispatch

  get "/state" do
    snap = Introspection.snapshot()
    json(conn, 200, snap)
  end

  match _ do
    json_error(conn, 404, "not_found", "Not found")
  end
end
