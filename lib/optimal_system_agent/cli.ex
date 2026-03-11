defmodule OptimalSystemAgent.CLI do
  @moduledoc """
  Entry point for the `osagent` release binary.

  Dispatches subcommands:
    osagent           interactive chat (default)
    osagent setup     configure provider, API keys
    osagent version   print version
    osagent serve     headless HTTP API mode
    osagent doctor    system health check
  """

  @app :optimal_system_agent

  def chat do
    # Silence boot logs for clean CLI startup
    Logger.configure(level: :none)

    {:ok, _} = Application.ensure_all_started(@app)

    Logger.configure(level: :warning)

    migrate!()

    # Zero-config: auto-detect a provider and continue (never blocks)
    OptimalSystemAgent.Onboarding.auto_configure()

    if OptimalSystemAgent.Onboarding.first_run?() do
      OptimalSystemAgent.Soul.reload()
    end

    OptimalSystemAgent.Channels.CLI.start()
  end

  def setup do
    {:ok, _} = Application.ensure_all_started(:jason)
    OptimalSystemAgent.Onboarding.run_setup_mode()
  end

  def version do
    Application.load(@app)
    vsn = Application.spec(@app, :vsn) |> to_string()
    safe_puts("osagent v#{vsn}")
  end

  def serve do
    {:ok, _} = Application.ensure_all_started(@app)
    migrate!()
    OptimalSystemAgent.Onboarding.auto_configure()

    port = Application.get_env(@app, :http_port, 8089)
    safe_puts("OSA serving on :#{port}")
    Process.sleep(:infinity)
  end

  def doctor do
    OptimalSystemAgent.CLI.Doctor.run()
  end

  # ── Migrations ──────────────────────────────────────────────────

  defp migrate! do
    priv = :code.priv_dir(@app) |> to_string()
    migrations_path = Path.join([priv, "repo", "migrations"])

    if File.dir?(migrations_path) do
      Ecto.Migrator.run(
        OptimalSystemAgent.Store.Repo,
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
