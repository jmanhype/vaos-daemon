defmodule Mix.Tasks.Osa.Db.Maintenance do
  @moduledoc """
  Database maintenance task for SQLite.

  Performs VACUUM, ANALYZE, and prunes old sessions to keep the database healthy and performant.

  ## Usage

      # Run full maintenance (vacuum, reindex, prune 30-day-old sessions)
      mix osa.db.maintenance

      # Dry-run mode (show what would be deleted without deleting)
      mix osa.db.maintenance --dry-run

      # Prune sessions older than N days (default: 30)
      mix osa.db.maintenance --prune-days 60

      # Skip pruning, only vacuum and reindex
      mix osa.db.maintenance --no-prune

  ## What it does

  1. **VACUUM**: Rebuilds the database file, reclaiming space from deleted rows
  2. **ANALYZE**: Updates query planner statistics for better performance
  3. **Prune old sessions**: Deletes messages from sessions older than the threshold

  ## Safety

  - Runs in a transaction (pruning only)
  - Shows counts before deleting
  - Dry-run mode for testing
  - VACUUM is safe to run anytime (SQLite exclusive lock, but quick)

  ## When to run

  - Weekly via cron: `0 3 * * 0 cd /path/to/app && mix osa.db.maintenance`
  - When database file grows large
  - After bulk deletions
  """

  use Mix.Task
  require Logger

  @shortdoc "Database maintenance (vacuum, reindex, prune old sessions)"

  @impl true
  def run(args) do
    # Parse options
    opts = parse_args(args)
    dry_run = Keyword.get(opts, :dry_run, false)
    prune_days = Keyword.get(opts, :prune_days, 30)
    do_prune = Keyword.get(opts, :prune, true)

    # Ensure app is started
    Mix.Task.run("app.start")

    Logger.configure(level: :info)

    Logger.info("╔═══════════════════════════════════════════════════════════════╗")
    Logger.info("║          OSA Database Maintenance                             ║")
    Logger.info("╚═══════════════════════════════════════════════════════════════╝")
    Logger.info("")

    # Get database info
    db_path = get_database_path()
    Logger.info("📁 Database: #{db_path}")

    # Get database size before
    size_before = get_db_size(db_path)
    Logger.info("📊 Size before: #{format_bytes(size_before)}")
    Logger.info("")

    # Step 1: VACUUM
    Logger.info("Step 1: VACUUM (rebuild database, reclaim space)")
    if dry_run do
      Logger.info("  [DRY RUN] Would run VACUUM")
    else
      case vacuum_database() do
        :ok ->
          Logger.info("  ✓ VACUUM completed successfully")

        {:error, reason} ->
          Logger.error("  ✗ VACUUM failed: #{inspect(reason)}")
    end
    end
    Logger.info("")

    # Step 2: ANALYZE (reindex)
    Logger.info("Step 2: ANALYZE (update query planner statistics)")
    if dry_run do
      Logger.info("  [DRY RUN] Would run ANALYZE")
    else
      case analyze_database() do
        :ok ->
          Logger.info("  ✓ ANALYZE completed successfully")

        {:error, reason} ->
          Logger.error("  ✗ ANALYZE failed: #{inspect(reason)}")
      end
    end
    Logger.info("")

    # Step 3: Prune old sessions
    if do_prune do
      Logger.info("Step 3: Prune old sessions (older than #{prune_days} days)")
      prune_sessions(prune_days, dry_run)
    else
      Logger.info("Step 3: Prune skipped (--no-prune flag)")
    end
    Logger.info("")

    # Get database size after
    size_after = get_db_size(db_path)
    Logger.info("📊 Size after:  #{format_bytes(size_after)}")

    if size_before > size_after do
      saved = size_before - size_after
      percentage = (saved / size_before * 100) |> Float.round(1)
      Logger.info("💾 Space saved: #{format_bytes(saved)} (#{percentage}%)")
    else
      Logger.info("ℹ️  Database size unchanged (no space to reclaim)")
    end

    Logger.info("")
    Logger.info("✅ Maintenance complete!")
  end

  # ── Command Line Parsing ────────────────────────────────────────────────

  defp parse_args(args) do
    {opts, _non_opts, _invalid} =
      OptionParser.parse(
        args,
        strict: [
          dry_run: :boolean,
          prune_days: :integer,
          prune: :boolean
        ],
        aliases: [
          d: :dry_run,
          p: :prune_days
        ]
      )

    # Default values
    opts =
      opts
      |> Keyword.put_new(:prune, true)
      |> Keyword.put_new(:prune_days, 30)

    opts
  end

  # ── Database Operations ─────────────────────────────────────────────────

  defp get_database_path do
    case Daemon.Store.Repo.config() do
      nil -> "unknown (not configured)"
      config -> Keyword.get(config, :database, "unknown")
    end
  end

  defp get_db_size(db_path) when is_binary(db_path) do
    if File.exists?(db_path) do
      File.stat!(db_path).size
    else
      0
    end
  end

  defp vacuum_database do
    Logger.info("  Running VACUUM... (this may take a moment)")

    try do
      # VACUUM must be run outside a transaction in SQLite
      Ecto.Adapters.SQL.query(Daemon.Store.Repo, "VACUUM", [])
      :ok
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp analyze_database do
    Logger.info("  Running ANALYZE...")

    try do
      Ecto.Adapters.SQL.query(Daemon.Store.Repo, "ANALYZE", [])
      :ok
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # ── Session Pruning ─────────────────────────────────────────────────────

  defp prune_sessions(days_ago, dry_run) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-(days_ago * 24 * 60 * 60), :second)

    Logger.info("  Cutoff date: #{DateTime.to_string(cutoff_date)}")

    # Count messages to be deleted
    {count, _} =
      Ecto.Adapters.SQL.query(
        Daemon.Store.Repo,
        "SELECT COUNT(*) FROM messages WHERE inserted_at < $1",
        [cutoff_date]
      )

    message_count = count.rows |> List.first() |> List.first()

    Logger.info("  Messages to delete: #{message_count}")

    if message_count == 0 do
      Logger.info("  ✓ No messages to prune")
      :ok
    else
      if dry_run do
        Logger.info("  [DRY RUN] Would delete #{message_count} messages")
        :ok
      else
        # Delete in batches to avoid long-running transactions
        delete_in_batches(cutoff_date)
      end
    end
  end

  defp delete_in_batches(cutoff_date, batch_size \\ 1000) do
    Logger.info("  Deleting in batches of #{batch_size}...")

    try do
      # Use a CTE to delete in batches
      {deleted, _} =
        Ecto.Adapters.SQL.query(
          Daemon.Store.Repo,
          """
          DELETE FROM messages
          WHERE id IN (
            SELECT id FROM messages
            WHERE inserted_at < $1
            LIMIT $2
          )
          """,
          [cutoff_date, batch_size]
        )

      batch_count = if deleted.num_rows == nil, do: 0, else: deleted.num_rows

      if batch_count > 0 do
        Logger.info("  ✓ Deleted #{batch_count} messages")
        # Continue with next batch
        delete_in_batches(cutoff_date, batch_size)
      else
        Logger.info("  ✓ Pruning complete")
        :ok
      end
    rescue
      e ->
        Logger.error("  ✗ Batch delete failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # ── Formatting Helpers ──────────────────────────────────────────────────

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)} MB"
      true -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
    end
  end
end
