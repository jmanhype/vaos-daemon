defmodule OptimalSystemAgent.Agents.Formatter do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "formatter"

  @impl true
  def description, do: "Code formatting, linting, import organization."

  @impl true
  def tier, do: :utility

  @impl true
  def role, do: :lead

  @impl true
  def system_prompt, do: """
  You are a FORMATTING utility. Run formatters, fix lint errors, organize imports.
  Be fast and precise. No explanations needed — just fix it.
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers, do: ["format", "lint", "prettier", "eslint"]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
