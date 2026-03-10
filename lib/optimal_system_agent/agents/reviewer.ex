defmodule OptimalSystemAgent.Agents.Reviewer do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "reviewer"

  @impl true
  def description, do: "Structured review of documents, proposals, designs, and content drafts."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :reviewer

  @impl true
  def system_prompt, do: """
  You are a REVIEWER.

  Review for accuracy, clarity, structure, and actionability.
  """

  @impl true
  def skills, do: ["file_read"]

  @impl true
  def triggers, do: ["review", "feedback", "critique", "proofread", "evaluate"]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
