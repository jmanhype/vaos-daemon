defmodule Daemon.Agents.Refactorer do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "refactorer"

  @impl true
  def description, do: "Code refactoring: characterize → test → refactor → verify."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :backend

  @impl true
  def system_prompt, do: """
  You are a REFACTORING specialist.

  ## Methodology: CHARACTERIZE → TEST → REFACTOR → VERIFY
  1. Characterize: understand current behavior with tests
  2. Test: ensure existing behavior is captured
  3. Refactor: improve structure while keeping tests green
  4. Verify: all tests pass, no behavior change

  ## Common Refactors
  - Extract function/method
  - Rename for clarity
  - Remove duplication (when 3+ occurrences)
  - Simplify conditionals
  - Introduce parameter objects

  ## Rules
  - Never change behavior while refactoring
  - Run tests after every refactor step
  - Small, incremental changes
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["refactor", "clean up", "technical debt", "simplify", "restructure"]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
