# Schema Standards

Audience: contributors adding new database tables or modifying existing ones.

This document defines the conventions used across all Daemon Ecto schemas and
migrations. All new schema work must follow these standards.

---

## Ecto Schema Conventions

### Module Structure

```elixir
defmodule Daemon.Store.MyResource do
  @moduledoc """
  One-paragraph description of what this schema represents and why it exists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "my_resources" do
    # Required fields first
    field :name,       :string
    field :status,     :string, default: "pending"

    # Optional fields
    field :metadata,   :map,    default: %{}
    field :notes,      :string

    # Associations last
    belongs_to :session, Daemon.Store.Session

    timestamps()
  end

  @required_fields [:name, :status]
  @optional_fields [:metadata, :notes, :session_id]
  @valid_statuses ~w(pending active completed failed)

  @doc "Build a changeset for inserting or updating a resource."
  def changeset(resource \\ %__MODULE__{}, attrs) do
    resource
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:session_id)
  end
end
```

### Required Patterns

- Always define `@required_fields` and `@optional_fields` as module attributes.
- Always call `validate_required(@required_fields)` in the changeset.
- Always use a whitelist in `cast/3` — never cast arbitrary attrs.
- Document the changeset function with `@doc`.
- Define a single `changeset/2` with an optional first argument defaulting to
  `%__MODULE__{}` so callers can use it for both insert and update.

---

## Primary Keys

### SQLite (Local)

Use Ecto's default auto-incrementing integer primary key. Do not use UUID
primary keys for SQLite tables — integer keys are faster for SQLite's B-tree
index structure.

```elixir
schema "messages" do
  # id is INTEGER PRIMARY KEY AUTOINCREMENT by default
  field :session_id, :string
  # ...
end
```

### Task Queue (UUID)

The `task_queue` table uses a string `task_id` as the logical identifier
because tasks are created externally (by agents, schedulers, or remote callers)
and need a globally unique ID before insertion. Use `Ecto.UUID.generate()`:

```elixir
# When creating a task:
task_id = Ecto.UUID.generate()
```

The database `id` column is still an auto-increment integer; `task_id` is
a unique string field.

### PostgreSQL (Platform)

For platform-level schemas (User, Tenant, OSInstance, Grant), use UUID primary
keys via the `binary_id` type:

```elixir
@primary_key {:id, :binary_id, autogenerate: true}
@foreign_key_type :binary_id
schema "users" do
  field :email, :string
  # ...
end
```

---

## String IDs for Sessions

Session IDs are string fields, not foreign-key integers. They are generated
by the channel layer and carry semantic meaning (e.g. channel-specific user IDs).

```elixir
field :session_id, :string, null: false
```

Do not use `references(:sessions)` for session_id foreign keys — sessions
are managed by the agent loop (not a database table) and are keyed by
process registry, not by database row.

---

## Timestamps

Always include `timestamps()` in every schema. This generates `inserted_at`
and `updated_at` fields using UTC timestamps.

```elixir
schema "my_resources" do
  # fields...
  timestamps()
end
```

The Repo init callback ensures UTF-8 encoding pragma is applied on every
connection. Timestamps are stored as ISO 8601 UTC strings in SQLite.

For schemas that need high-precision timestamps (e.g. `budget_ledger`,
`treasury_transactions`), use `:utc_datetime_usec`:

```elixir
field :timestamp, :utc_datetime_usec, null: false
```

---

## JSON Fields

Elixir maps stored as JSON use the `:map` type in Ecto:

```elixir
field :metadata,   :map, default: %{}
field :tool_calls, :map
field :payload,    :map, default: %{}
```

In SQLite, `:map` fields are stored as JSON text. In PostgreSQL, they map
to `jsonb` for efficient querying.

**Do not** store structured data that needs to be queried as flat JSON text.
If you need to filter or sort by a JSON field value, extract it to a dedicated
column.

---

## Status Fields

Enumerate valid values and validate with `validate_inclusion`:

```elixir
@valid_statuses ~w(pending leased completed failed)

field :status, :string, default: "pending"

# In changeset:
|> validate_inclusion(:status, @valid_statuses)
```

Provide helper functions for converting between string (DB) and atom (runtime):

```elixir
def status_to_atom("pending"),   do: :pending
def status_to_atom("leased"),    do: :leased
def status_to_atom("completed"), do: :completed
def status_to_atom("failed"),    do: :failed
def status_to_atom(a) when is_atom(a), do: a
```

---

## Migrations

### File Naming

Migrations use UTC timestamps in the filename:

```
priv/repo/migrations/YYYYMMDDHHMMSS_description.exs
```

Use the Daemon convention of date-only precision for manual migrations:

```
20260302000000_add_session_fts.exs
```

### Migration Structure

```elixir
defmodule Daemon.Store.Repo.Migrations.AddMyTable do
  use Ecto.Migration

  def change do
    create table(:my_table) do
      add :name,       :string,  null: false
      add :status,     :string,  null: false, default: "pending"
      add :metadata,   :map,     default: %{}
      add :session_id, :string
      timestamps()
    end

    # Always add indexes for foreign keys and frequently-queried fields
    create index(:my_table, [:session_id])
    create index(:my_table, [:status])
    create unique_index(:my_table, [:name], name: :my_table_name_unique)
  end
end
```

### Index Standards

- Always index foreign key columns (e.g. `session_id`, `contact_id`).
- Index columns used in `WHERE` clauses in common queries.
- Use composite indexes for queries that filter on multiple columns together.
- Name unique indexes explicitly: `name: :table_field_unique`.

### Irreversible Migrations

For migrations that cannot be rolled back (e.g. virtual tables, raw SQL):

```elixir
def up do
  execute("CREATE VIRTUAL TABLE ...")
end

def down do
  execute("DROP TABLE IF EXISTS ...")
end
```

Do not use `def change` for irreversible operations.

---

## Changeset Validation Checklist

Every changeset must:

- [ ] Cast with an explicit field whitelist
- [ ] Call `validate_required` for non-nullable fields
- [ ] Validate string format/inclusion where applicable
- [ ] Add `foreign_key_constraint` for association fields
- [ ] Add `unique_constraint` for fields with unique indexes
- [ ] Sanitize text fields that may contain non-UTF-8 input (see `Store.Message`)

---

## to_map / from_map Helpers

For schemas used with GenServer state (e.g. `Store.Task`), provide
`to_map/1` and `from_map/1` helpers that convert between the DB struct
and the in-memory map representation:

```elixir
@doc "Convert a DB record to the in-memory map used by the TaskQueue GenServer."
@spec to_map(%__MODULE__{}) :: map()
def to_map(%__MODULE__{} = record) do
  %{
    task_id:     record.task_id,
    status:      status_to_atom(record.status),
    created_at:  to_datetime(record.inserted_at),
    # ...
  }
end

@doc "Convert an in-memory map to DB-compatible attrs."
@spec from_map(map()) :: map()
def from_map(task_map) when is_map(task_map) do
  %{
    task_id: task_map[:task_id] || task_map["task_id"],
    status:  status_to_string(task_map[:status] || "pending"),
    # ...
  }
end
```

Support both atom and string keys in `from_map` for flexibility when
processing maps that originated from JSON decoding.
