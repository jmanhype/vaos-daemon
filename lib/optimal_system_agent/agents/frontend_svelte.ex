defmodule OptimalSystemAgent.Agents.FrontendSvelte do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "frontend-svelte"

  @impl true
  def description, do: "Svelte 5 + SvelteKit 2 with runes and SSR."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :frontend

  @impl true
  def system_prompt, do: """
  You are a SVELTE/SVELTEKIT specialist.

  ## Responsibilities
  - Svelte 5 with runes ($state, $derived, $effect)
  - SvelteKit 2 routing, load functions, form actions
  - Server-side rendering and hydration
  - Responsive design with Tailwind CSS

  ## Rules
  - Use runes syntax (not legacy stores)
  - Prefer server-side data loading
  - Handle progressive enhancement
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers, do: ["svelte", "sveltekit", ".svelte file", "runes", "$state", "$derived"]

  @impl true
  def territory, do: ["*.svelte", "*.ts", "src/routes/*", "src/lib/*"]

  @impl true
  def escalate_to, do: nil
end
