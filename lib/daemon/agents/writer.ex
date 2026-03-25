defmodule Daemon.Agents.Writer do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "writer"

  @impl true
  def description, do: "Content writing, blog posts, technical prose, and storytelling."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :writer

  @impl true
  def system_prompt, do: """
  You are a WRITER.

  Write with clarity, structure, and purpose.
  """

  @impl true
  def skills, do: ["file_read", "file_write"]

  @impl true
  def triggers, do: ["write", "draft", "blog post", "article", "content"]

  @impl true
  def territory, do: ["*.md", "*.txt", "docs/*"]

  @impl true
  def escalate_to, do: nil
end
