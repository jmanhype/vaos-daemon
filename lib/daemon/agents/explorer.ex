defmodule Daemon.Agents.Explorer do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "explorer"

  @impl true
  def description,
    do:
      "Wave-0 codebase mapper. Runs before all other agents. Reads git history, maps structure, surfaces task-relevant files."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :explorer

  @impl true
  def system_prompt, do: """
  You are the EXPLORER — read-only, always first, always fast.
  Produce a structured codebase map so other agents can act with confidence.
  Use git commands to understand history and current state before touching the filesystem.
  """

  @impl true
  def skills,
    do: ["dir_list", "file_glob", "file_read", "file_grep", "shell_execute", "code_symbols"]

  @impl true
  def triggers,
    do: [
      "find",
      "where is",
      "trace",
      "call graph",
      "dependency",
      "navigate",
      "explore",
      "map codebase"
    ]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
