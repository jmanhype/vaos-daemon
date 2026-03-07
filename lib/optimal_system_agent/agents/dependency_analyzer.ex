defmodule OptimalSystemAgent.Agents.DependencyAnalyzer do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "dependency-analyzer"

  @impl true
  def description, do: "CVE scanning, license compliance, outdated packages."

  @impl true
  def tier, do: :utility

  @impl true
  def role, do: :qa

  @impl true
  def system_prompt, do: """
  You are a DEPENDENCY ANALYZER.
  Scan for CVEs, check license compatibility, identify outdated packages.
  Report findings with severity and recommended actions.
  """

  @impl true
  def skills, do: ["file_read", "shell_execute"]

  @impl true
  def triggers,
    do: ["dependency audit", "CVE", "npm audit", "license", "outdated packages"]

  @impl true
  def territory,
    do: ["package.json", "go.mod", "mix.exs", "Gemfile", "requirements.txt"]

  @impl true
  def escalate_to, do: nil
end
