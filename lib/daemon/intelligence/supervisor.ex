defmodule Daemon.Intelligence.Supervisor do
  @moduledoc """
  Supervises communication intelligence processes.
  These are the communication-facing intelligence services that remain outside
  the core adaptive control plane.

  GenServer children:
  - CommProfiler: Learns communication patterns per contact
  - CommCoach: Scores outbound message quality
  - ConversationTracker: Tracks conversation depth (casual→working→deep→strategic)

  Pure modules (no supervision needed):
  - ContactDetector: Pure pattern matching for contact identification (< 1ms),
    called from Agent.Loop after each inbound user message.

  `ProactiveMonitor` now lives under `Daemon.Supervisors.Adaptation` because it
  participates in VAOS's always-on adaptive control plane rather than optional
  communication intelligence.
  """
  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      Daemon.Intelligence.CommProfiler,
      Daemon.Intelligence.CommCoach,
      Daemon.Intelligence.ConversationTracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
