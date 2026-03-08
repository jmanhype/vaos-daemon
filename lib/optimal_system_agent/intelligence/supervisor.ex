defmodule OptimalSystemAgent.Intelligence.Supervisor do
  @moduledoc """
  Supervises communication intelligence processes.
  These are what make OSA unique — no other agent framework has them.

  GenServer children:
  - CommProfiler: Learns communication patterns per contact
  - CommCoach: Scores outbound message quality
  - ConversationTracker: Tracks conversation depth (casual→working→deep→strategic)
  - ProactiveMonitor: Scans for silence, drift, engagement drops

  Pure modules (no supervision needed):
  - ContactDetector: Pure pattern matching for contact identification (< 1ms),
    called from Agent.Loop after each inbound user message.
  """
  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      OptimalSystemAgent.Intelligence.CommProfiler,
      OptimalSystemAgent.Intelligence.CommCoach,
      OptimalSystemAgent.Intelligence.ConversationTracker,
      OptimalSystemAgent.Intelligence.ProactiveMonitor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
