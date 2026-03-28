defmodule Daemon.Channels.Starter do
  @moduledoc """
  Deferred channel startup using OTP-idiomatic handle_continue.

  Replaces the fragile `Task.start(fn -> Process.sleep(250); ... end)` pattern
  that was in Application.start/2. The GenServer initialises synchronously
  (guaranteeing it is placed in the supervision tree before any child triggers
  it), then immediately resumes with `{:continue, :start_channels}` which runs
  after `init/1` returns but before the next message is processed.

  This gives the rest of the supervision tree the chance to fully start (all
  processes registered, ETS tables created, etc.) before channels are started,
  without any wall-clock sleep.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, :ok, {:continue, :start_channels}}
  end

  @impl true
  def handle_continue(:start_channels, state) do
    Logger.info("Channels.Starter: starting configured channel adapters")

    # Log circuit breaker state before starting channels
    alias Daemon.Providers.HealthChecker
    breaker_state = HealthChecker.state()

    if map_size(breaker_state) > 0 do
      Logger.info(
        "Channels.Starter: circuit breaker state: " <>
          Enum.map_join(breaker_state, ", ", fn {provider, data} ->
            "#{provider}=#{data.circuit}" <>
              if data.rate_limited_until do
                " (rate-limited)"
              else
                ""
              end
          end)
      )
    end

    Daemon.Channels.Manager.start_configured_channels()
    {:noreply, state}
  end
end
