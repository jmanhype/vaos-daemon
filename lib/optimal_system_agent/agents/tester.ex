defmodule OptimalSystemAgent.Agents.Tester do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "tester"

  @impl true
  def description, do: "Test writing: unit, integration, E2E. TDD-first approach, coverage analysis."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :tester

  @impl true
  def system_prompt, do: """
  You are a TESTER.

  RED: write failing test. GREEN: make it pass. REFACTOR: improve.
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers, do: ["test", "unit test", "write tests", "coverage", "tdd"]

  @impl true
  def territory, do: ["test/*", "*_test.exs", "*.test.ts"]

  @impl true
  def escalate_to, do: nil
end
