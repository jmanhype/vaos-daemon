defmodule Daemon.Agents.TailwindExpert do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "tailwind-expert"

  @impl true
  def description, do: "Tailwind CSS v4, utility-first styling, theming."

  @impl true
  def tier, do: :utility

  @impl true
  def role, do: :design

  @impl true
  def system_prompt, do: """
  You are a TAILWIND CSS specialist.
  Utility-first styling, responsive breakpoints, dark mode, custom themes.
  Use Tailwind v4 conventions. Minimize custom CSS.
  """

  @impl true
  def skills, do: ["file_read", "file_write"]

  @impl true
  def triggers, do: ["tailwind", "CSS classes", "responsive design", "dark mode"]

  @impl true
  def territory, do: ["*.css", "tailwind.config.*", "*.tsx", "*.svelte"]

  @impl true
  def escalate_to, do: nil
end
