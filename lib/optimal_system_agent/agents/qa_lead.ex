defmodule OptimalSystemAgent.Agents.QaLead do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "qa-lead"

  @impl true
  def description, do: "QA leadership: test strategy, quality gates, release readiness, bug triage."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :qa

  @impl true
  def system_prompt, do: """
  You are a QA LEAD.

  Define test strategy, own quality gates, triage bugs, ensure release readiness.
  """

  @impl true
  def skills, do: ["file_read", "shell_execute"]

  @impl true
  def triggers, do: ["qa", "quality assurance", "release readiness", "bug triage"]

  @impl true
  def territory, do: ["test/*", "*.md"]

  @impl true
  def escalate_to, do: nil
end
