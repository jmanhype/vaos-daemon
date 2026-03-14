# Backup and Recovery

Audience: operators responsible for protecting OSA data and recovering from failures.

## What Needs Backing Up

| Data | Location | Criticality | Notes |
|------|----------|-------------|-------|
| SQLite database | `~/.osa/osa.db` | High | Messages, budget ledger, task queue, treasury |
| Environment / API keys | `~/.osa/.env` | High | Provider keys, secrets, config overrides |
| Vault memory | `~/.osa/data/` | Medium | Structured memory markdown files, fact store |
| Sessions | `~/.osa/sessions/` | Medium | JSONL conversation files |
| Skills | `~/.osa/skills/` | Medium | User-defined SKILL.md files |
| MCP config | `~/.osa/mcp.json` | Medium | MCP server definitions |
| Bootstrap identity | `~/.osa/IDENTITY.md`, `~/.osa/SOUL.md`, `~/.osa/USER.md` | Low-medium | Agent personality and user profile |
| Metrics snapshot | `~/.osa/metrics.json` | Low | Written every 5 minutes; ephemeral |

## SQLite Database Backup

The database at `~/.osa/osa.db` uses WAL (Write-Ahead Log) journal mode (`journal_mode: :wal` in `config.exs`). WAL mode allows consistent online backups without shutting down OSA.

### Online backup with the SQLite CLI

```bash
sqlite3 ~/.osa/osa.db ".backup /tmp/osa-backup-$(date +%Y%m%d-%H%M%S).db"
```

The `.backup` command uses SQLite's online backup API and is safe to run while OSA is active. The resulting file is a complete, self-contained copy of the database.

### Copy-based backup (WAL-safe)

Because OSA uses WAL mode, copying all three files together produces a consistent backup:

```bash
BACKUP_DIR="/backup/osa/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
cp ~/.osa/osa.db "$BACKUP_DIR/"
cp ~/.osa/osa.db-wal "$BACKUP_DIR/" 2>/dev/null || true
cp ~/.osa/osa.db-shm "$BACKUP_DIR/" 2>/dev/null || true
```

Copying only `osa.db` without the WAL file risks restoring to a state behind the latest checkpoint. Always copy all three files.

### Automated daily backup (cron)

```cron
0 3 * * * sqlite3 ~/.osa/osa.db ".backup /backup/osa/osa-$(date +\%Y\%m\%d).db" && find /backup/osa -name "osa-*.db" -mtime +30 -delete
```

This runs at 03:00, creates a dated backup, and prunes backups older than 30 days.

## Full Data Directory Backup

Back up the entire `~/.osa/` directory to capture all user data:

```bash
tar -czf "osa-full-$(date +%Y%m%d-%H%M%S).tar.gz" \
  --exclude="~/.osa/osa.db-wal" \
  --exclude="~/.osa/osa.db-shm" \
  ~/.osa/
```

Exclude the WAL and SHM files from tar archives — they are incomplete WAL segments and should not be restored independently.

For the SQLite database specifically, take a `.backup` dump separately (see above) and include it in the archive:

```bash
BACKUP_NAME="osa-full-$(date +%Y%m%d-%H%M%S)"
TMPDIR=$(mktemp -d)
sqlite3 ~/.osa/osa.db ".backup ${TMPDIR}/osa.db"
cp -r ~/.osa/data ~/.osa/sessions ~/.osa/skills ~/.osa/.env \
  ~/.osa/mcp.json ~/.osa/IDENTITY.md ~/.osa/SOUL.md ~/.osa/USER.md \
  "$TMPDIR/" 2>/dev/null || true
tar -czf "${BACKUP_NAME}.tar.gz" -C "$TMPDIR" .
rm -rf "$TMPDIR"
```

## Vault Memory Export

The Vault subsystem stores structured memory as markdown files under `~/.osa/data/`. Categories include `fact`, `learning`, `project`, and `episodic`.

To export vault contents:

```bash
# All vault files
tar -czf "osa-vault-$(date +%Y%m%d).tar.gz" ~/.osa/data/
```

To inspect vault contents without archiving:

```bash
find ~/.osa/data -name "*.md" | sort
wc -l ~/.osa/data/**/*.md
```

There is no dedicated vault export command in the CLI. The files are plain markdown and can be read, searched, and transferred directly.

## Session Export

Sessions are stored as JSONL files in `~/.osa/sessions/`. Each file is one conversation, one JSON object per line:

```bash
ls -lh ~/.osa/sessions/
# session-abc123.jsonl  session-def456.jsonl ...

# Count messages across all sessions
wc -l ~/.osa/sessions/*.jsonl
```

To export all sessions:

```bash
tar -czf "osa-sessions-$(date +%Y%m%d).tar.gz" ~/.osa/sessions/
```

## Recovery Procedures

### Restore SQLite from backup

Stop OSA before restoring to prevent write conflicts:

```bash
# Stop the service (systemd example)
sudo systemctl stop osagent

# Restore from a .backup file
cp /backup/osa/osa-20260301.db ~/.osa/osa.db

# Remove stale WAL files
rm -f ~/.osa/osa.db-wal ~/.osa/osa.db-shm

# Verify integrity
sqlite3 ~/.osa/osa.db "PRAGMA integrity_check;"
# Expected: ok

# Start the service
sudo systemctl start osagent
```

### Restore from a full archive

```bash
sudo systemctl stop osagent
tar -xzf osa-full-20260301.tar.gz -C ~/.osa/
sudo systemctl start osagent
```

### Database corruption recovery

If `PRAGMA integrity_check` returns errors:

```bash
# Attempt repair via dump and restore
sqlite3 ~/.osa/osa.db ".dump" | sqlite3 ~/.osa/osa-repaired.db
sqlite3 ~/.osa/osa-repaired.db "PRAGMA integrity_check;"
# If ok:
mv ~/.osa/osa.db ~/.osa/osa.db.corrupt
mv ~/.osa/osa-repaired.db ~/.osa/osa.db
```

If dump fails, restore from the most recent backup.

### Re-run migrations after restore

After restoring a database from a much older backup, run migrations to bring the schema up to date:

```bash
# From source
mix ecto.migrate

# From release
./bin/osagent_release eval "Ecto.Migrator.run(OptimalSystemAgent.Store.Repo, :up)"
```

### Recover from lost `.env`

If the `.env` file is lost, re-export your API keys:

```bash
cat > ~/.osa/.env <<EOF
ANTHROPIC_API_KEY=sk-ant-...
OSA_DEFAULT_PROVIDER=anthropic
OSA_SHARED_SECRET=$(openssl rand -hex 32)
OSA_REQUIRE_AUTH=true
EOF
```

Then restart OSA.

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
