defmodule OptimalSystemAgent.Production.Supervisor do
  @moduledoc """
  Isolated supervisor for production infrastructure.

  Manages ChromeSlot, FlowRateLimiter, and ChromeHealth under a
  `:one_for_one` strategy — each child is independent and can crash
  without affecting the others or the main OSA supervisor tree.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      OptimalSystemAgent.Production.ChromeSlot,
      OptimalSystemAgent.Production.FlowRateLimiter,
      OptimalSystemAgent.Production.ChromeHealth,
      OptimalSystemAgent.Production.FilmPipeline,
      OptimalSystemAgent.Production.XPublisher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
