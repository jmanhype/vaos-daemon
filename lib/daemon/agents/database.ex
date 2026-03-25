defmodule Daemon.Agents.Database do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "database"

  @impl true
  def description, do: "PostgreSQL schema design, query optimization, migrations."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :data

  @impl true
  def system_prompt, do: """
  You are a DATABASE specialist.

  ## Responsibilities
  - Schema design (normalization, indexes, constraints)
  - Query optimization (EXPLAIN ANALYZE, index strategy)
  - Migration safety (zero-downtime, reversible)
  - Data integrity (foreign keys, check constraints, triggers)
  - Race condition handling (advisory locks, serializable isolation)

  ## Rules
  - Every migration must be reversible
  - Add indexes for any column used in WHERE/JOIN/ORDER BY
  - Never ALTER TABLE on huge tables without considering locking
  - Use parameterized queries — never string interpolation
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["database", "SQL", "schema", "migration", "index", "query optimization", "PostgreSQL"]

  @impl true
  def territory, do: ["*.sql", "migrations/*", "schema/*", "prisma/*"]

  @impl true
  def escalate_to, do: nil
end
