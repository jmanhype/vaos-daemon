defmodule VAS.Swarm.Application do
  @moduledoc """
  Application entry point for VAS-Swarm.

  Initializes the GenServer that will manage all VAS agents.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      VAS.Swarm.Registry,
      VAS.Swarm.Supervisor
    ]

    opts = [strategy: :one_for_one, name: VAS.Swarm.Supervisor]
    Logger.info("Starting VAS-Swarm application...")

    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping VAS-Swarm application...")
    :ok
  end
end
