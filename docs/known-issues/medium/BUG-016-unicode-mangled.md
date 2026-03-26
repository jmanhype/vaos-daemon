# BUG-016: Japanese and Emoji Characters Stored as ????? in SQLite

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/daemon/store/repo.ex`, `lib/daemon/store/message.ex`
> **Reported:** 2026-03-14

---

## Summary

Messages containing multi-byte Unicode characters (Japanese text, emoji, Arabic,
Chinese) are retrieved from the SQLite store with the non-ASCII bytes replaced
by `?` characters. The characters are stored correctly in memory and displayed
in the streaming response, but after persisting and reloading from the database
the content is mangled.

## Symptom

Send message: `おはよう 🌅`
Receive correct streaming response.
On `/resume` or session reload, the user message appears as: `????? ?`

## Root Cause

`repo.ex` line 20 sets the encoding pragma via `Keyword.put_new/3`:

```elixir
pragmas =
  existing
  |> Keyword.put_new(:encoding, "'UTF-8'")
```

The SQLite `PRAGMA encoding` must be set _before the first write_ to a new
database. After any data has been written, the pragma has no effect — SQLite
ignores it silently. If the database file was created without the pragma (e.g.
by a previous version of Daemon or by `mix ecto.migrate` before `repo.ex` was
updated), the database remains in the default `UTF-8` mode that SQLite claims
to support, but the `ecto_sqlite3` adapter version being used may not set the
connection-level encoding correctly, causing the driver to substitute `?` for
bytes it cannot represent.

Additionally, `sanitize_utf8/1` in `message.ex` at line 67 uses
`:unicode.characters_to_binary(bin, :utf8, :utf8)` which strips or truncates
invalid bytes, but valid multi-byte UTF-8 sequences that SQLite cannot store
are silently dropped at the database layer rather than at application layer.
The changeset validation at line 55 (`String.valid?(value)`) passes (because
the Elixir string is valid), and the truncation happens at write time with no
error reported.

## Impact

- All non-ASCII user messages and agent responses are unreadable after session
  reload.
- Chat history is permanently corrupted for affected sessions.
- Japanese, Chinese, Arabic, and emoji-heavy conversations are most affected.

## Suggested Fix

1. Verify the existing database was created with UTF-8 encoding:
   ```sql
   PRAGMA encoding;  -- should return "UTF-8"
   ```
   If it returns "UTF-16" or is absent, migrate by creating a new database.

2. Pass `:journal_mode` and `:encoding` in `config.exs` as connection options
   rather than `custom_pragmas`, which some adapter versions handle differently:
   ```elixir
   config :daemon, Daemon.Store.Repo,
     database: "priv/osa.db",
     journal_mode: :wal,
     encoding: "UTF-8"
   ```

3. Pin `ecto_sqlite3` to a version ≥ 0.15 where UTF-8 handling is fixed.

## Workaround

Delete the existing database file (`priv/osa.db` or the path in `config.exs`)
and run `mix ecto.migrate` to recreate it. All session history will be lost.
