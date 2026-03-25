defmodule Daemon.Platform.Repo do
  use Ecto.Repo,
    otp_app: :daemon,
    adapter: Ecto.Adapters.Postgres
end
