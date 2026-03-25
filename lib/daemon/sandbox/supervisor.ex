defmodule Daemon.Sandbox.Supervisor do
  @moduledoc """
  Supervisor for the Docker sandbox subsystem.

  Manages the lifecycle of sandbox infrastructure:
  - `Sandbox.Pool` — warm container pool (GenServer)

  This supervisor is only started when `sandbox_enabled: true` is set in
  config. See `Daemon.Application` for the conditional start.

  Strategy: `:one_for_one` — if the Pool crashes it restarts independently
  without disrupting other agent processes.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Sandbox.Supervisor] Starting sandbox infrastructure")

    config = Daemon.Sandbox.Config.from_config()

    children =
      [Daemon.Sandbox.Pool, Daemon.Sandbox.Registry] ++
        if config.mode == :sprites and config.sprites_token,
          do: [Daemon.Sandbox.Sprites],
          else: []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
