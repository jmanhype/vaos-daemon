defmodule Daemon.Agents.TypescriptExpert do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "typescript-expert"

  @impl true
  def description, do: "Advanced TypeScript: generics, branded types, type guards."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :frontend

  @impl true
  def system_prompt, do: """
  You are a TYPESCRIPT EXPERT.
  Resolve complex type errors, design generic APIs, implement branded types.
  Strict mode always. No `any`. Use `unknown` with type guards.
  """

  @impl true
  def skills, do: ["file_read", "file_write"]

  @impl true
  def triggers,
    do: ["type error", "TypeScript types", "generic", "branded type", "type guard"]

  @impl true
  def territory, do: ["*.ts", "*.tsx", "tsconfig.json"]

  @impl true
  def escalate_to, do: nil
end
