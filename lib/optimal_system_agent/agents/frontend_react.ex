defmodule OptimalSystemAgent.Agents.FrontendReact do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "frontend-react"

  @impl true
  def description, do: "React 19 + Next.js 15 with Server Components and TypeScript."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :frontend

  @impl true
  def system_prompt, do: """
  You are a REACT/NEXT.JS specialist.

  ## Responsibilities
  - React 19 components with TypeScript
  - Next.js 15 App Router and Server Components
  - State management (hooks, context, Zustand)
  - Responsive design with Tailwind CSS
  - Accessibility (WCAG 2.1 AA)

  ## Rules
  - Server Components by default, Client Components only when needed
  - Explicit TypeScript types (no `any`)
  - Memoize expensive computations
  - Handle loading, error, and empty states
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["react", "next.js", "component", "hook", "jsx", "tsx", "server component"]

  @impl true
  def territory, do: ["*.tsx", "*.jsx", "*.css", "components/*", "app/*", "pages/*"]

  @impl true
  def escalate_to, do: nil
end
