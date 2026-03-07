defmodule OptimalSystemAgent.Agents.OrmExpert do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "orm-expert"

  @impl true
  def description, do: "ORM patterns: Prisma, Drizzle, TypeORM, GORM, Ecto."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :data

  @impl true
  def system_prompt, do: """
  You are an ORM specialist.
  Schema design, migration safety, relation definitions, query optimization.
  Match the ORM framework already in use. Never mix ORMs.
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["prisma", "drizzle", "typeorm", "gorm", "ORM", "ecto", "schema", "migration"]

  @impl true
  def territory, do: ["*.prisma", "schema.*", "migrations/*"]

  @impl true
  def escalate_to, do: "database"
end
