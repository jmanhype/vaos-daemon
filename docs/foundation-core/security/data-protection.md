# Data Protection

## What Data OSA Stores

| Data class | Storage location | Sensitivity |
|---|---|---|
| LLM provider API keys | BEAM application env (process memory) | High |
| JWT signing secret | BEAM application env / `persistent_term` | High |
| Bot tokens (Telegram, Discord, etc.) | BEAM application env | High |
| Conversation history | JSONL files on disk | Medium |
| Long-term memory | `~/.osa/MEMORY.md` on disk | Medium |
| Vault memories | `~/.osa/vault/**/*.md` on disk | Medium |
| SQLite messages | `~/.osa/osa.db` | Medium |
| Episodic memory index | ETS (in-process, not persisted) | Low |
| Rate limit state | ETS (in-process, not persisted) | Low |
| Tool list cache | `persistent_term` (in-process) | Low |
| Budget ledger | SQLite `budget_ledger` table | Low |
| Platform user accounts | PostgreSQL `platform_users` | High (password hash) |

---

## API Key and Secret Storage

### LLM Provider API Keys

Keys are loaded from environment variables or `.env` files into the BEAM application environment at startup (`config/runtime.exs`). Once loaded:

- Keys exist only in process memory (`Application.get_env`)
- They are not written to any database, log file, or HTTP response
- They are passed to HTTP clients via request headers, over TLS to external APIs
- Process crash/restart requires reloading from env — no key persistence in OSA itself

### JWT Signing Secret

The JWT HS256 signing secret (`OSA_SHARED_SECRET` / `JWT_SECRET`) follows the same pattern. When no secret is configured in enforced mode, a 32-byte cryptographically random secret is generated via `:crypto.strong_rand_bytes(32)` and stored in `persistent_term` under the key `:osa_dev_secret`. This ephemeral secret is:

- Not written to disk
- Not logged (only a warning that the secret is ephemeral)
- Lost on process restart (all existing tokens become invalid)

The `Plug.Crypto.secure_compare/2` function is used for all secret comparisons to prevent timing attacks.

---

## Conversation History

### Session JSONL Files

Each conversation session is stored as an append-only JSONL file:

```
~/.osa/sessions/{session_id}.jsonl
```

Each line is a JSON object representing one message:
```json
{"role": "user", "content": "...", "timestamp": "2026-03-14T10:00:00Z"}
{"role": "assistant", "content": "...", "timestamp": "2026-03-14T10:00:05Z"}
```

**File permissions:** Created by OSA with default OS permissions for the running user. No special permission setting — the security boundary is the OS user account.

**Deletion:** `DELETE /api/v1/sessions/:id` calls `File.rm/1` on the JSONL file. There is no secure erase (overwrite with random bytes before deletion). Files are deleted with the OS `unlink` call.

**No encryption:** JSONL files are stored as plaintext. Sensitive conversation content is accessible to any process running as the same OS user.

### SQLite Message Table

Messages are also written to SQLite (`OptimalSystemAgent.Store.Repo`) via the `OptimalSystemAgent.Store.Message` schema. This provides queryable history and supports the FTS5 search index.

**Encryption:** SQLite databases are stored as plaintext. `ecto_sqlite3` does not use SQLite Encryption Extension (SEE) or SQLCipher. No at-rest encryption.

**Access:** SQLite database file at `~/.osa/osa.db` is protected only by OS file permissions.

### Content Sanitization

Before insertion, message content is validated as valid UTF-8 by `Message.validate_utf8/2`. Invalid byte sequences are cleaned using `:unicode.characters_to_binary/3` (replacing invalid portions rather than rejecting the entire message). This prevents multi-byte character mangling but is not a security control.

---

## Long-term Memory

### MEMORY.md

`~/.osa/MEMORY.md` stores consolidated insights, decisions, and preferences. It is a structured markdown file maintained by `MiosaMemory.Store`.

- Plaintext, no encryption
- Accessible to any process with filesystem access as the running user
- No automatic expiry; entries are manually archived via `Memory.archive/1`

### Vault

`~/.osa/vault/` contains categorized markdown files written by `Vault.remember/3`. Each file has YAML frontmatter with metadata and markdown body with the memory content.

- Plaintext, no encryption
- Category directories: `facts/`, `decisions/`, `lessons/`, `preferences/`, etc.
- Files are named by a URL-safe slug of the memory title
- Session checkpoints in `~/.osa/vault/.vault/checkpoints/` include context snapshots

### Episodic Memory Index

`MiosaMemory.Store` maintains two ETS tables as an in-process inverted index:

- `:osa_memory_index` — keyword → entry ID map
- `:osa_memory_entries` — entry ID → entry struct map

Both tables are `:named_table, :public, :set`. They are rebuilt from `MEMORY.md` at startup and on each `remember` or `archive` operation. They are not persisted to disk — process restart rebuilds from the markdown file.

**ETS `:public` flag:** All processes in the BEAM VM can read from (and write to) these tables. This is intentional for performance (avoids GenServer bottleneck on recall) but means any Elixir code in the process can access memory content.

---

## Platform Data (PostgreSQL)

When the platform is enabled, user credentials are stored in `platform_users`:

- `password_hash` — Bcrypt hash via `Bcrypt.hash_pwd_salt/1` (12 rounds by default)
- Plaintext password exists only in the virtual Ecto field during changeset processing; it is deleted from the changeset before persistence via `delete_change/2`
- Email addresses are stored as plaintext (used for login)

Platform database uses standard PostgreSQL at-rest and in-transit encryption configurations — OSA does not configure these; they are operator responsibility.

---

## Sensitive Data Clearing

OSA does not implement explicit memory zeroing for sensitive strings (API keys, passwords) after use. Elixir strings are garbage-collected by the BEAM GC; the timing of collection is non-deterministic.

For `password_hash` computation, the plaintext password is a short-lived virtual field on the Ecto changeset that is deleted by `maybe_hash_password/1` in `User.changeset/2`. The BEAM GC will eventually collect it.

There is no HSM, secure enclave, or hardware-backed key storage integration.

---

## Data Retention and Deletion

| Data | Retention | Deletion mechanism |
|---|---|---|
| Session JSONL | Until `DELETE /sessions/:id` | `File.rm/1` |
| SQLite messages | Indefinite (no TTL) | Manual SQL or `DROP TABLE` |
| MEMORY.md entries | Until `archive/1` is called | Markdown entry removal |
| Vault memories | Indefinite | Manual file deletion |
| ETS tables | Process lifetime | Process restart |
| Budget ledger | Indefinite | Manual SQL |
| Platform user data | Until account deletion API | PostgreSQL row delete |

There is no automatic data expiry, session TTL, or GDPR-compliant right-to-erasure flow implemented. These are known gaps for hosted multi-tenant deployment.
