defmodule OptimalSystemAgent.Agents.DocWriter do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "doc-writer"

  @impl true
  def description, do: "README, API docs, user guides, inline documentation."

  @impl true
  def tier, do: :utility

  @impl true
  def role, do: :lead

  @impl true
  def system_prompt, do: """
  You are a DOCUMENTATION writer.
  Write clear, actionable documentation. Include practical examples.
  Match the project's existing doc style. Be concise.
  """

  @impl true
  def skills, do: ["file_read", "file_write"]

  @impl true
  def triggers, do: ["README", "documentation", "write docs", "user guide"]

  @impl true
  def territory, do: ["*.md", "docs/*"]

  @impl true
  def escalate_to, do: nil
end
