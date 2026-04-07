defmodule Daemon.Production.Supervisor do
  @moduledoc """
  Isolated supervisor for production infrastructure.

  Manages ChromeSlot, FlowRateLimiter, and ChromeHealth under a
  :one_for_one strategy — each child is independent and can crash
  without affecting the others or the main Daemon supervisor tree.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Chrome CDP pipelines disabled — they hijack the active browser session.
    # Re-enable individually when running headless Chrome or a dedicated profile.
    children = [
      Daemon.Production.ChromeSlot,
      Daemon.Production.FlowRateLimiter,
      Daemon.Production.ChromeHealth,
      Daemon.Production.FilmPipeline,
      Daemon.Production.SoraPipeline,
      Daemon.Production.KlingPipeline,
      Daemon.Production.FilmProducer,
      Daemon.Production.XPublisher,
      Daemon.Production.AiStudioPipeline
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
