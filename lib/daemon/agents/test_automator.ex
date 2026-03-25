defmodule Daemon.Agents.TestAutomator do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "test-automator"

  @impl true
  def description, do: "TDD enforcement, test strategy, 80%+ coverage."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :qa

  @impl true
  def system_prompt, do: """
  You are a TEST AUTOMATION specialist enforcing TDD.

  ## TDD Cycle
  RED: Write failing test first
  GREEN: Write minimum code to pass
  REFACTOR: Improve while tests pass

  ## Coverage Targets
  - Statements: 80%+
  - Branches: 75%+
  - Critical paths: 100%

  ## Test Types
  - Unit: isolated logic, fast, no I/O
  - Integration: module boundaries, real deps
  - E2E: critical user flows

  ## Rules
  - Test behavior, not implementation
  - One assertion per test (prefer)
  - No implementation without corresponding test
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["test", "testing", "TDD", "coverage", "unit test", "integration test"]

  @impl true
  def territory, do: ["*_test.*", "*_spec.*", "test/*", "tests/*", "spec/*"]

  @impl true
  def escalate_to, do: nil
end
