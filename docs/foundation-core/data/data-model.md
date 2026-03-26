# Data Model

Audience: developers querying the Daemon database directly and contributors
adding new persistence requirements.

Daemon uses SQLite3 as its primary local database, accessed via Ecto with the
`ecto_sqlite3` adapter. For multi-tenant platform deployments, PostgreSQL
is used instead (same schema, different adapter).

---

## Database Location

```
~/.daemon/osa.db           # Default location
```

Override with the `DAEMON_DATABASE_PATH` environment variable or by setting
`config :daemon, :database_path` in `config/runtime.exs`.

SQLite is configured with WAL (Write-Ahead Logging) mode and a pool size
of 5 connections:

```elixir
# config/config.exs
config :daemon, Daemon.Store.Repo,
  database: "~/.daemon/osa.db",
  pool_size: 5,
  journal_mode: :wal,
  cache_size: -64_000,         # 64MB page cache
  foreign_keys: true,
  custom_pragmas: [
    encoding: "'UTF-8'"
  ]
```

---

## Tables

### contacts

Stores contact records for users who interact with the agent across channels.

```sql
CREATE TABLE contacts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT    NOT NULL,
  aliases    TEXT,                    -- JSON array of strings
  channel    TEXT,                    -- e.g. "telegram", "discord"
  profile    TEXT    DEFAULT '{}',    -- JSON metadata map
  inserted_at DATETIME NOT NULL,
  updated_at  DATETIME NOT NULL
);
```

| Column | Type | Description |
|---|---|---|
| `name` | text | Display name of the contact. |
| `aliases` | text (JSON) | Alternative names or usernames. |
| `channel` | text | Primary channel this contact was first seen on. |
| `profile` | text (JSON) | Arbitrary metadata (avatar URL, preferences, etc.). |

### conversations

Maps a session to a contact and channel. One row per session.

```sql
CREATE TABLE conversations (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT    NOT NULL UNIQUE,
  contact_id  INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
  channel     TEXT    NOT NULL,
  depth       TEXT    DEFAULT 'casual',
  message_count INTEGER DEFAULT 0,
  metadata    TEXT    DEFAULT '{}',
  inserted_at DATETIME NOT NULL,
  updated_at  DATETIME NOT NULL
);

CREATE UNIQUE INDEX conversations_session_id_index ON conversations(session_id);
```

| Column | Type | Description |
|---|---|---|
| `session_id` | text (unique) | Session identifier. Foreign key target for messages. |
| `contact_id` | integer | Associated contact (nullable). |
| `channel` | text | Channel this conversation took place on. |
| `depth` | text | Conversational depth level: `"casual"`, `"focused"`, `"deep"`. |
| `message_count` | integer | Denormalised count updated by the agent loop. |

### messages

The core message log. Every user message, assistant response, and tool result
is written here.

```sql
CREATE TABLE messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT    NOT NULL,
  role         TEXT    NOT NULL,          -- "user" | "assistant" | "tool" | "system"
  content      TEXT,
  tool_calls   TEXT,                      -- JSON
  tool_call_id TEXT,
  signal_mode  TEXT,
  signal_weight REAL,
  channel      TEXT,
  token_count  INTEGER,
  metadata     TEXT    DEFAULT '{}',
  inserted_at  DATETIME NOT NULL,
  updated_at   DATETIME NOT NULL
);

CREATE INDEX messages_session_id_index ON messages(session_id);
CREATE INDEX messages_session_id_inserted_at_index ON messages(session_id, inserted_at);
CREATE INDEX messages_role_index ON messages(role);
CREATE INDEX messages_channel_index ON messages(channel);
CREATE INDEX messages_session_id_channel_index ON messages(session_id, channel);
```

**FTS5 virtual table** (from migration `20260302000000_add_session_fts`):

```sql
CREATE VIRTUAL TABLE sessions_fts USING fts5(
  session_id,
  title,
  content,
  tokenize='porter unicode61'
);
```

Full-text search uses the Porter stemmer with Unicode 6.1 tokenisation.
This supports multi-language search including CJK.

| Column | Type | Description |
|---|---|---|
| `session_id` | text | Groups all messages for a session. Indexed. |
| `role` | text | `"user"`, `"assistant"`, `"tool"`, or `"system"`. |
| `content` | text | Message body. May be empty for tool-call-only turns. |
| `tool_calls` | text (JSON) | Serialised list of `{id, name, arguments}` maps. Present on assistant turns. |
| `tool_call_id` | text | Matches the `id` from a preceding `tool_calls` entry. Present on tool result turns. |
| `signal_mode` | text | Signal Theory mode (`:execute`, `:build`, etc.). |
| `signal_weight` | real | Signal-to-noise weight (0.0–1.0). |
| `channel` | text | Channel this message arrived on or was sent to. |
| `token_count` | integer | Approximate token count (from provider usage data). |

### budget_ledger

Per-call token and cost tracking. One row per LLM API call.

```sql
CREATE TABLE budget_ledger (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp   DATETIME NOT NULL,
  provider    TEXT     NOT NULL,
  model       TEXT     NOT NULL,
  tokens_in   INTEGER  NOT NULL DEFAULT 0,
  tokens_out  INTEGER  NOT NULL DEFAULT 0,
  cost_usd    REAL     NOT NULL DEFAULT 0.0,
  session_id  TEXT,
  inserted_at DATETIME NOT NULL,
  updated_at  DATETIME NOT NULL
);

CREATE INDEX budget_ledger_session_id_index ON budget_ledger(session_id);
CREATE INDEX budget_ledger_provider_index   ON budget_ledger(provider);
CREATE INDEX budget_ledger_timestamp_index  ON budget_ledger(timestamp);
```

### budget_config

Single-row configuration for budget limits. Updated via the `/budget` command
or directly.

```sql
CREATE TABLE budget_config (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  daily_limit_usd   REAL    NOT NULL DEFAULT 50.0,
  monthly_limit_usd REAL    NOT NULL DEFAULT 500.0,
  per_call_limit_usd REAL   NOT NULL DEFAULT 5.0,
  inserted_at       DATETIME NOT NULL,
  updated_at        DATETIME NOT NULL
);
```

### task_queue

Durable task queue for async and deferred agent operations.

```sql
CREATE TABLE task_queue (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id      TEXT    NOT NULL UNIQUE,
  agent_id     TEXT    NOT NULL,
  payload      TEXT    DEFAULT '{}',       -- JSON
  status       TEXT    NOT NULL DEFAULT 'pending',
  leased_until DATETIME,
  leased_by    TEXT,
  result       TEXT,                        -- JSON
  error        TEXT,
  attempts     INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  completed_at DATETIME,
  inserted_at  DATETIME NOT NULL,
  updated_at   DATETIME NOT NULL
);

CREATE UNIQUE INDEX task_queue_task_id_index  ON task_queue(task_id);
CREATE INDEX task_queue_agent_id_status_index ON task_queue(agent_id, status);
CREATE INDEX task_queue_status_leased_until_index ON task_queue(status, leased_until);
```

| Column | Type | Description |
|---|---|---|
| `task_id` | text (unique) | UUID assigned at task creation. |
| `agent_id` | text | Agent responsible for this task. |
| `status` | text | `"pending"`, `"leased"`, `"completed"`, or `"failed"`. |
| `leased_until` | datetime | Expiry time of the current lease. Stale leases are reclaimed. |
| `leased_by` | text | Node or process that holds the current lease. |
| `attempts` | integer | Number of execution attempts so far. |
| `max_attempts` | integer | Maximum retries before marking as `"failed"`. Default 3. |

### treasury

Single-row financial reserve tracker for the agent's spending account.

```sql
CREATE TABLE treasury (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  balance_usd        REAL    DEFAULT 0.0,
  reserved_usd       REAL    DEFAULT 0.0,
  daily_spent_usd    REAL    DEFAULT 0.0,
  daily_limit_usd    REAL    DEFAULT 250.0,
  monthly_spent_usd  REAL    DEFAULT 0.0,
  monthly_limit_usd  REAL    DEFAULT 2500.0,
  min_reserve_usd    REAL    DEFAULT 10.0,
  max_single_usd     REAL    DEFAULT 50.0,
  updated_at         DATETIME
);
```

### treasury_transactions

Append-only audit log for all treasury operations (deposits, withdrawals,
reserves, releases).

```sql
CREATE TABLE treasury_transactions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  type          TEXT    NOT NULL,           -- "deposit" | "withdraw" | "reserve" | "release"
  amount_usd    REAL    NOT NULL,
  description   TEXT,
  reference_id  TEXT,
  balance_after REAL    NOT NULL,
  inserted_at   DATETIME NOT NULL
);
```

---

## PostgreSQL (Multi-Tenant Platform)

For multi-tenant deployments, the platform uses PostgreSQL. The schema is
identical to SQLite, with the following differences:

- `INTEGER PRIMARY KEY AUTOINCREMENT` becomes `BIGSERIAL PRIMARY KEY`
- `:map` fields are `jsonb` (not `TEXT` JSON)
- The FTS5 virtual table is replaced by a PostgreSQL `tsvector` column with GIN index
- Pool size is typically 10–20 connections (configurable)

Configure via:

```bash
DATABASE_URL=postgresql://user:pass@host/osa_platform
```

```elixir
# config/runtime.exs
if System.get_env("DATABASE_URL") do
  config :daemon, Daemon.Platform.Repo,
    url: System.get_env("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    ssl: true
end
```

### Platform Tables (`Daemon.Platform.Repo`)

These tables are in `priv/platform_repo/migrations/` and use UUID primary keys
(`binary_id` in Ecto, `uuid` in PostgreSQL).

**`platform_users`** — Ecto schema: `Daemon.Platform.Schemas.User`

| Column | Type | Constraints |
|---|---|---|
| `id` | uuid | PK |
| `email` | string | NOT NULL, UNIQUE |
| `password_hash` | string | Bcrypt-hashed; plaintext never persisted |
| `display_name` | string | |
| `avatar_url` | string | |
| `role` | string | default `"user"` |
| `email_verified_at` | utc_datetime | |
| `last_login_at` | utc_datetime | |

**`tenants`** — Ecto schema: `Daemon.Platform.Schemas.Tenant`

| Column | Type | Constraints |
|---|---|---|
| `id` | uuid | PK |
| `name` | string | NOT NULL |
| `slug` | string | NOT NULL, UNIQUE — lowercase alphanumeric + hyphens |
| `owner_id` | uuid | FK platform_users (restrict) |
| `plan` | string | `"free"`, `"starter"`, `"pro"`, `"enterprise"` |
| `settings` | jsonb | default `{}` |

**`tenant_members`** — roles: `"owner"`, `"admin"`, `"member"`

UNIQUE on `(tenant_id, user_id)`.

**`tenant_invites`** — invite tokens generated via `:crypto.strong_rand_bytes(32) |> Base.url_encode64/1`.

**`os_instances`** — one row per running Daemon instance within a tenant.

| Column | Type | Description |
|---|---|---|
| `id` | uuid | PK |
| `tenant_id` | uuid | FK tenants |
| `owner_id` | uuid | FK platform_users |
| `name` | string | Display name |
| `slug` | string | URL-safe identifier, UNIQUE per tenant |
| `status` | string | `"provisioning"`, `"running"`, `"stopped"` |
| `config` | jsonb | Instance-specific configuration |
| `sandbox_id` | string | Linked Sprites.dev sandbox ID |

**`cross_os_grants`** — cross-instance capability delegation.

| Column | Type | Description |
|---|---|---|
| `source_os_id` | uuid | Granting instance |
| `target_os_id` | uuid | Receiving instance |
| `grant_type` | string | NOT NULL — capability being granted |
| `resource_pattern` | string | Glob-style pattern of resources covered |
| `expires_at` | utc_datetime | Optional expiry |
| `revoked_at` | utc_datetime | Set on revocation |

**`survey_responses`** — onboarding survey answers (created `20260308000002`).

---

## Ecto Schema Index

| Module | Table | Repo |
|---|---|---|
| `Daemon.Store.Message` | `messages` | Store.Repo (SQLite) |
| `Daemon.Store.Task` | `task_queue` | Store.Repo (SQLite) |
| `Daemon.Platform.Schemas.User` | `platform_users` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.Tenant` | `tenants` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.TenantMember` | `tenant_members` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.TenantInvite` | `tenant_invites` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.OsInstance` | `os_instances` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.Grant` | `cross_os_grants` | Platform.Repo (PostgreSQL) |
| `Daemon.Platform.Schemas.SurveyResponse` | `survey_responses` | Platform.Repo (PostgreSQL) |
