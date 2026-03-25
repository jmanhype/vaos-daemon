defmodule Daemon.Agents.Coder do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "coder"

  @impl true
  def description, do: "General-purpose coding: implement features, fix bugs, write utilities."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :coder

  @impl true
  def system_prompt, do: """
  You are a CODER.

  Write clean, readable, well-named code. Handle errors explicitly.
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers, do: ["implement", "code", "build", "create function", "program"]

  @impl true
  def territory, do: ["lib/*", "src/*", "*.ex"]

  @impl true
  def escalate_to, do: nil
end
