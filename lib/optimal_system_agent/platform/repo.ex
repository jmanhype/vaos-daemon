defmodule OptimalSystemAgent.Platform.Repo do
  use Ecto.Repo,
    otp_app: :optimal_system_agent,
    adapter: Ecto.Adapters.Postgres
end
