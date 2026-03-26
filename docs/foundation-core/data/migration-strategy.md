# Migration Strategy

Daemon uses Ecto migrations for both SQLite (core agent database) and PostgreSQL
(platform multi-tenant database). This document covers naming conventions, how to
create and run migrations, rollback procedures, and the rules for safe schema changes.

---

## Two Repos, Two Migration Paths

| Repo | Adapter | Migration directory | When run |
|---|---|---|---|
| `Daemon.Store.Repo` | ecto_sqlite3 | `priv/repo/migrations/` | Always (local-first) |
| `Daemon.Platform.Repo` | postgrex | `priv/platform_repo/migrations/` | Only when `DATABASE_URL` is set |

The `mix ecto.migrate` alias runs migrations for all configured repos.

---

## Migration File Naming

```
priv/repo/migrations/<timestamp>_<description>.exs
```

**Timestamp format:** `YYYYMMDDHHMMSS` (UTC). Use the current UTC datetime
at the moment you create the file. Never reuse or backdate timestamps.

**Description:** lowercase with underscores, imperative verb form.

Examples from the codebase:
```
20260224000000_create_initial_tables.exs
20260227000000_create_messages.exs
20260227010000_create_budget_tables.exs
20260227020000_create_task_queue.exs
20260227030000_create_treasury.exs
20260228000000_add_channel_to_messages.exs
20260302000000_add_session_fts.exs
```

The timestamp is the primary ordering key. When multiple migrations are
created on the same day, increment the time portion (e.g. `000000`, `010000`, `020000`).

---

## Creating a Migration

```bash
# SQLite (core agent)
mix ecto.gen.migration create_scheduler_jobs

# Platform (PostgreSQL)
mix ecto.gen.migration create_scheduler_jobs --repo Daemon.Platform.Repo
```

Ecto generates the file at the correct path with the current timestamp:
```
priv/repo/migrations/20260314120000_create_scheduler_jobs.exs
```

Open the file and fill in the `change/0` callback (or `up/0` + `down/0` for irreversible operations):

```elixir
defmodule Daemon.Store.Repo.Migrations.CreateSchedulerJobs do
  use Ecto.Migration

  def change do
    create table(:scheduler_jobs) do
      add :name, :string, null: false
      add :schedule, :string, null: false
      add :enabled, :boolean, default: true
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :payload, :map, default: %{}
      timestamps()
    end

    create index(:scheduler_jobs, [:name])
    create index(:scheduler_jobs, [:next_run_at, :enabled])
  end
end
```

---

## Running Migrations

```bash
# Run all pending migrations (both repos)
mix ecto.migrate

# Run only for the SQLite repo
mix ecto.migrate --repo Daemon.Store.Repo

# Run only for the Platform repo
mix ecto.migrate --repo Daemon.Platform.Repo

# Run a specific number of migrations
mix ecto.migrate --step 1

# Check migration status
mix ecto.migrations
```

In production (OTP release), migrations run via the release eval:
```bash
./bin/daemon eval "Daemon.Release.migrate()"
```

---

## Rollback Procedures

### Rolling Back the Last Migration

```bash
mix ecto.rollback --repo Daemon.Store.Repo
```

This calls the `down/0` callback (or reverses `change/0` if the migration is reversible).

```bash
# Roll back N migrations
mix ecto.rollback --step 3
```

### Reversible vs. Irreversible Migrations

Migrations using `change/0` are automatically reversible for table creation,
column addition, and index creation. Ecto generates the inverse automatically.

Operations that are not automatically reversible:
- `execute/1` (raw SQL)
- `alter table` with column removal
- `drop table`

For these, use `up/0` and `down/0` explicitly:

```elixir
def up do
  execute("""
  CREATE VIRTUAL TABLE sessions_fts USING fts5(
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
```

If a migration has no safe rollback (e.g. data was deleted), mark it explicitly:

```elixir
def down do
  raise Ecto.MigrationError, "This migration cannot be rolled back safely."
end
```

---

## Rules for Safe Schema Changes

### Always Safe (additive)

- Adding a new table
- Adding a nullable column to an existing table
- Adding a column with a default value
- Adding an index (note: index creation on large tables may lock SQLite briefly)

```elixir
def change do
  alter table(:messages) do
    add :channel, :string          # nullable, no default required
  end
  create index(:messages, [:channel])
end
```

### Requires Caution (potentially breaking)

- Adding a NOT NULL column without a default — will fail on tables with existing rows.

  **Solution:** Add with a default, then remove the default in a later migration after backfilling.

  ```elixir
  # Migration 1: add with default
  alter table(:messages) do
    add :priority, :integer, default: 0
  end

  # Migration 2 (later, after backfill if needed): can tighten constraint
  alter table(:messages) do
    modify :priority, :integer, null: false
  end
  ```

- Renaming a column — SQLite does not support `RENAME COLUMN` in older versions. Use `add` + `copy data` + `drop old` in separate migrations, never in one.

- Changing a column type — treat as destructive. Add a new column, migrate data, drop old column across separate migrations.

### Always Dangerous (destructive)

- Dropping a table or column — data is permanently lost on `up`. Ensure `down` cannot be run in production without a backup.
- Removing a unique index while the application still enforces uniqueness — creates a split-brain condition.
- Truncating a table — never in a migration file.

---

## Migration Conventions in This Codebase

**Module naming:** `Daemon.Store.Repo.Migrations.<CamelCase>` for SQLite; `Daemon.PlatformRepo.Migrations.<CamelCase>` for PostgreSQL.

**Timestamps:** All tables use `timestamps()` (adds `inserted_at`, `updated_at`). Financial and audit tables use `utc_datetime_usec` precision: `timestamps(type: :utc_datetime_usec)`.

**Map columns:** Used for arbitrary metadata (`metadata: :map, default: %{}`). These are stored as JSON text in SQLite and as `jsonb` in PostgreSQL.

**Foreign keys:** Declared via `references/2`. SQLite foreign keys are enabled globally in the Repo config (`foreign_keys: true`). Always specify `on_delete` behavior explicitly.

**Indexes:** Add indexes for all columns used in `WHERE` clauses in application queries. Multi-column indexes follow query selectivity order (most selective column first).

**Platform migrations:** Use UUID primary keys (`@primary_key {:id, :binary_id, autogenerate: true}`) and `@foreign_key_type :binary_id`. All relations use `on_delete: :delete_all` (cascade) or `on_delete: :restrict` depending on intent.

---

## SQLite-Specific Considerations

SQLite has some migration constraints not present in PostgreSQL:

- **No `DROP COLUMN` in older SQLite versions.** The `ecto_sqlite3` adapter handles this with a table recreate strategy, but it acquires an exclusive lock. Run column drops during off-hours or maintenance windows.

- **No `RENAME COLUMN` before SQLite 3.25.** The adapter handles this, but be aware.

- **FTS5 virtual tables are not managed by Ecto.** Use `execute/1` with raw SQL for create/drop. See `20260302000000_add_session_fts.exs` for the pattern.

- **WAL mode and migrations:** Ecto migrations acquire an exclusive lock. In WAL mode this means waiting for all active readers to finish. For busy databases, use `mix ecto.migrate` during low-traffic periods.

---

## Platform Repo Migrations

Platform migrations follow the same conventions but with additional considerations:

- **PostgreSQL-specific types:** Use `:binary_id` for UUIDs, `:jsonb` is automatically used for `:map` fields.
- **Index concurrently:** For large production tables, add `concurrently: true` to index creation to avoid table locks.
- **Transactions:** Ecto wraps each migration in a transaction by default. For index creation with `CONCURRENTLY`, add `@disable_ddl_transaction true` at the module level.

```elixir
defmodule Daemon.PlatformRepo.Migrations.AddIndexConcurrently do
  use Ecto.Migration
  @disable_ddl_transaction true

  def change do
    create index(:platform_users, [:email], concurrently: true)
  end
end
```

---

## Checking Migration State

```bash
# Which migrations have run?
mix ecto.migrations --repo Daemon.Store.Repo

# Pending migrations only
mix ecto.migrations --repo Daemon.Store.Repo | grep "down"
```

The `schema_migrations` table tracks which timestamps have been applied. Do not modify this table manually.
