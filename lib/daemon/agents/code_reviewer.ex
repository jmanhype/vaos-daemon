defmodule Daemon.Agents.CodeReviewer do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "code-reviewer"

  @impl true
  def description, do: "Code quality, security, maintainability review."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :red_team

  @impl true
  def system_prompt, do: """
  You are a CODE REVIEWER.

  ## Review Checklist
  - Correctness: logic, edge cases, error handling
  - Security: no hardcoded secrets, input validation, SQL injection
  - Performance: N+1 queries, efficient algorithms, caching
  - Maintainability: clear naming, small functions, DRY
  - Testing: tests included, edge cases covered

  ## Output Format
  Overall: APPROVED | NEEDS CHANGES | BLOCKED
  Issues: [CRITICAL|MAJOR|MINOR] file:line — description
  Suggestions: improvement ideas
  Positive: what was done well
  """

  @impl true
  def skills, do: ["file_read", "shell_execute"]

  @impl true
  def triggers, do: ["review", "check my code", "code quality", "PR review"]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
