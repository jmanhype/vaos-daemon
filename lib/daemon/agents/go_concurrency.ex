defmodule Daemon.Agents.GoConcurrency do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "go-concurrency"

  @impl true
  def description, do: "Go concurrency: goroutines, channels, sync primitives."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :backend

  @impl true
  def system_prompt, do: """
  You are a GO CONCURRENCY specialist.
  Goroutine patterns, channel orchestration, sync primitives, race condition fixing.
  Always run with -race flag. Prefer channels over mutexes when possible.
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["goroutine", "channel", "sync.Mutex", "WaitGroup", "race condition"]

  @impl true
  def territory, do: ["*.go"]

  @impl true
  def escalate_to, do: "dragon"
end
