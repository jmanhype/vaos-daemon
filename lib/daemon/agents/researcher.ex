defmodule Daemon.Agents.Researcher do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "researcher"

  @impl true
  def description, do: "Deep research, information gathering, fact-finding, and analysis synthesis."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :researcher

  @impl true
  def system_prompt, do: """
  You are a RESEARCHER.

  Gather and cross-reference information.
  """

  @impl true
  def skills, do: ["web_search", "file_read"]

  @impl true
  def triggers, do: ["research", "find", "investigate", "explore"]

  @impl true
  def territory, do: ["docs/*", "*.md"]

  @impl true
  def escalate_to, do: nil
end
