# Backup and Recovery

Audience: operators responsible for protecting Daemon data and recovering from failures.

## What Needs Backing Up

| Data | Location | Criticality | Notes |
|------|----------|-------------|-------|
| SQLite database | `~/.daemon/osa.db` | High | Messages, budget ledger, task queue, treasury |
| Environment / API keys | `~/.daemon/.env` | High | Provider keys, secrets, config overrides |
| Vault memory | `~/.daemon/data/` | Medium | Structured memory markdown files, fact store |
| Sessions | `~/.daemon/sessions/` | Medium | JSONL conversation files |
| Skills | `~/.daemon/skills/` | Medium | User-defined SKILL.md files |
| MCP config | `~/.daemon/mcp.json` | Medium | MCP server definitions |
| Bootstrap identity | `~/.daemon/IDENTITY.md`, `~/.daemon/SOUL.md`, `~/.daemon/USER.md` | Low-medium | Agent personality and user profile |
| Metrics snapshot | `~/.daemon/metrics.json` | Low | Written every 5 minutes; ephemeral |

## SQLite Database Backup

The database at `~/.daemon/osa.db` uses WAL (Write-Ahead Log) journal mode (`journal_mode: :wal` in `config.exs`). WAL mode allows consistent online backups without shutting down Daemon.

### Online backup with the SQLite CLI

```bash
sqlite3 ~/.daemon/osa.db ".backup /tmp/osa-backup-$(date +%Y%m%d-%H%M%S).db"
```

The `.backup` command uses SQLite's online backup API and is safe to run while Daemon is active. The resulting file is a complete, self-contained copy of the database.

### Copy-based backup (WAL-safe)

Because Daemon uses WAL mode, copying all three files together produces a consistent backup:

```bash
BACKUP_DIR="/backup/osa/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
cp ~/.daemon/osa.db "$BACKUP_DIR/"
cp ~/.daemon/osa.db-wal "$BACKUP_DIR/" 2>/dev/null || true
cp ~/.daemon/osa.db-shm "$BACKUP_DIR/" 2>/dev/null || true
```

Copying only `osa.db` without the WAL file risks restoring to a state behind the latest checkpoint. Always copy all three files.

### Automated daily backup (cron)

```cron
0 3 * * * sqlite3 ~/.daemon/osa.db ".backup /backup/osa/osa-$(date +\%Y\%m\%d).db" && find /backup/osa -name "osa-*.db" -mtime +30 -delete
```

This runs at 03:00, creates a dated backup, and prunes backups older than 30 days.

## Full Data Directory Backup

Back up the entire `~/.daemon/` directory to capture all user data:

```bash
tar -czf "osa-full-$(date +%Y%m%d-%H%M%S).tar.gz" \
  --exclude="~/.daemon/osa.db-wal" \
  --exclude="~/.daemon/osa.db-shm" \
  ~/.daemon/
```

Exclude the WAL and SHM files from tar archives — they are incomplete WAL segments and should not be restored independently.

For the SQLite database specifically, take a `.backup` dump separately (see above) and include it in the archive:

```bash
BACKUP_NAME="osa-full-$(date +%Y%m%d-%H%M%S)"
TMPDIR=$(mktemp -d)
sqlite3 ~/.daemon/osa.db ".backup ${TMPDIR}/osa.db"
cp -r ~/.daemon/data ~/.daemon/sessions ~/.daemon/skills ~/.daemon/.env \
  ~/.daemon/mcp.json ~/.daemon/IDENTITY.md ~/.daemon/SOUL.md ~/.daemon/USER.md \
  "$TMPDIR/" 2>/dev/null || true
tar -czf "${BACKUP_NAME}.tar.gz" -C "$TMPDIR" .
rm -rf "$TMPDIR"
```

## Vault Memory Export

The Vault subsystem stores structured memory as markdown files under `~/.daemon/data/`. Categories include `fact`, `learning`, `project`, and `episodic`.

To export vault contents:

```bash
# All vault files
tar -czf "osa-vault-$(date +%Y%m%d).tar.gz" ~/.daemon/data/
```

To inspect vault contents without archiving:

```bash
find ~/.daemon/data -name "*.md" | sort
wc -l ~/.daemon/data/**/*.md
```

There is no dedicated vault export command in the CLI. The files are plain markdown and can be read, searched, and transferred directly.

## Session Export

Sessions are stored as JSONL files in `~/.daemon/sessions/`. Each file is one conversation, one JSON object per line:

```bash
ls -lh ~/.daemon/sessions/
# session-abc123.jsonl  session-def456.jsonl ...

# Count messages across all sessions
wc -l ~/.daemon/sessions/*.jsonl
```

To export all sessions:

```bash
tar -czf "osa-sessions-$(date +%Y%m%d).tar.gz" ~/.daemon/sessions/
```

## Recovery Procedures

### Restore SQLite from backup

Stop Daemon before restoring to prevent write conflicts:

```bash
# Stop the service (systemd example)
sudo systemctl stop daemon

# Restore from a .backup file
cp /backup/osa/osa-20260301.db ~/.daemon/osa.db

# Remove stale WAL files
rm -f ~/.daemon/osa.db-wal ~/.daemon/osa.db-shm

# Verify integrity
sqlite3 ~/.daemon/osa.db "PRAGMA integrity_check;"
# Expected: ok

# Start the service
sudo systemctl start daemon
```

### Restore from a full archive

```bash
sudo systemctl stop daemon
tar -xzf osa-full-20260301.tar.gz -C ~/.daemon/
sudo systemctl start daemon
```

### Database corruption recovery

If `PRAGMA integrity_check` returns errors:

```bash
# Attempt repair via dump and restore
sqlite3 ~/.daemon/osa.db ".dump" | sqlite3 ~/.daemon/osa-repaired.db
sqlite3 ~/.daemon/osa-repaired.db "PRAGMA integrity_check;"
# If ok:
mv ~/.daemon/osa.db ~/.daemon/osa.db.corrupt
mv ~/.daemon/osa-repaired.db ~/.daemon/osa.db
```

If dump fails, restore from the most recent backup.

### Re-run migrations after restore

After restoring a database from a much older backup, run migrations to bring the schema up to date:

```bash
# From source
mix ecto.migrate

# From release
./bin/daemon_release eval "Ecto.Migrator.run(Daemon.Store.Repo, :up)"
```

### Recover from lost `.env`

If the `.env` file is lost, re-export your API keys:

```bash
cat > ~/.daemon/.env <<EOF
ANTHROPIC_API_KEY=sk-ant-...
DAEMON_DEFAULT_PROVIDER=anthropic
DAEMON_SHARED_SECRET=$(openssl rand -hex 32)
DAEMON_REQUIRE_AUTH=true
EOF
```

Then restart Daemon.

## Docker Volume Backup

When running in Docker, the `osa_data` volume maps to `/root/.osa` inside the container:

```bash
# Backup
docker run --rm \
  -v osa_data:/data \
  -v $(pwd):/backup \
  alpine tar -czf /backup/osa-data-$(date +%Y%m%d).tar.gz /data

# Restore
docker run --rm \
  -v osa_data:/data \
  -v $(pwd):/backup \
  alpine tar -xzf /backup/osa-data-20260301.tar.gz -C /
```
