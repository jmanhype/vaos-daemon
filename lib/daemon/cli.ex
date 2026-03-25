defmodule Daemon.CLI do
  @moduledoc """
  Entry point for the `daemon` release binary.

  Dispatches subcommands:
    daemon           interactive chat (default)
    daemon setup     configure provider, API keys
    daemon version   print version
    daemon serve     headless HTTP API mode
    daemon doctor    system health check
    daemon update    pull latest code, recompile, restart
  """

  @app :daemon

  def chat do
    # Silence boot logs for clean CLI startup
    Logger.configure(level: :none)

    {:ok, _} = Application.ensure_all_started(@app)

    Logger.configure(level: :warning)

    migrate!()

    # Zero-config: auto-detect a provider and continue (never blocks)
    Daemon.Onboarding.auto_configure()

    if Daemon.Onboarding.first_run?() do
      Daemon.Soul.reload()
    end

    Daemon.Channels.CLI.start()
  end

  def setup do
    {:ok, _} = Application.ensure_all_started(:jason)
    Daemon.Onboarding.run_setup_mode()
  end

  def version do
    Application.load(@app)
    vsn = Application.spec(@app, :vsn) |> to_string()
    safe_puts("daemon v#{vsn}")
  end

  def serve do
    {:ok, _} = Application.ensure_all_started(@app)
    migrate!()
    Daemon.Onboarding.auto_configure()

    port = Application.get_env(@app, :http_port, 8089)
    safe_puts("OSA serving on :#{port}")
    Process.sleep(:infinity)
  end

  def doctor do
    Daemon.CLI.Doctor.run()
  end

  def update do
    safe_puts("Updating OSA Agent...")

    # Find project root
    root =
      case File.read(Path.join([System.user_home!(), ".daemon", "project_root"])) do
        {:ok, path} -> String.trim(path)
        _ ->
          # Fallback: walk up from priv dir
          :code.priv_dir(@app) |> to_string() |> Path.join("..") |> Path.expand()
      end

    if not File.exists?(Path.join(root, "mix.exs")) do
      safe_puts("Error: Cannot find project at #{root}")
      System.halt(1)
    end

    safe_puts("  Project: #{root}")

    # Git pull
    safe_puts("  Pulling latest...")
    case System.cmd("git", ["pull", "--ff-only", "origin", "main"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        safe_puts("  #{String.trim(output)}")

      {output, _} ->
        safe_puts("  Warning: git pull failed: #{String.trim(output)}")
        safe_puts("  Continuing with recompile...")
    end

    # Deps + compile
    safe_puts("  Fetching dependencies...")
    System.cmd("mix", ["deps.get"], cd: root, stderr_to_stdout: true)

    safe_puts("  Compiling...")
    case System.cmd("mix", ["compile"], cd: root, stderr_to_stdout: true) do
      {_, 0} -> safe_puts("  ✓ Compiled successfully")
      {output, _} -> safe_puts("  Warning: #{String.trim(output)}")
    end

    # Rebuild Rust TUI if it exists
    tui_dir = Path.join([root, "priv", "rust", "tui"])
    if File.exists?(Path.join(tui_dir, "Cargo.toml")) do
      safe_puts("  Rebuilding TUI...")
      case System.cmd("cargo", ["build", "--release"], cd: tui_dir, stderr_to_stdout: true) do
        {_, 0} -> safe_puts("  ✓ TUI rebuilt")
        {output, _} -> safe_puts("  Warning: TUI build: #{String.trim(output)}")
      end
    end

    safe_puts("")
    safe_puts("✓ Update complete. Restart OSA to use the new version.")
  end

  # ── Migrations ──────────────────────────────────────────────────

  defp migrate! do
    priv = :code.priv_dir(@app) |> to_string()
    migrations_path = Path.join([priv, "repo", "migrations"])

    if File.dir?(migrations_path) do
      Ecto.Migrator.run(
        Daemon.Store.Repo,
        migrations_path,
        :up,
        all: true,
        log: false
      )
    end
  end

  # On Windows a backgrounded process loses its console HANDLE; any IO call
  # into prim_tty returns {:error, :enotsup} or raises ErlangError wrapping
  # :eio.  This helper swallows those errors so the serve/version commands
  # do not crash the VM when stdout is unavailable.
  defp safe_puts(msg) do
    IO.puts(msg)
  rescue
    ErlangError -> :ok
  catch
    :error, :enotsup -> :ok
    :error, :eio     -> :ok
  end
end
