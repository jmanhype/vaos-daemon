defmodule OptimalSystemAgent.Store.Repo.Migrations.AddSessionFts do
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
      session_id,
      title,
      content,
      tokenize='porter unicode61'
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS sessions_fts")
  end
end
