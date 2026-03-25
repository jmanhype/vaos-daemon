defmodule Mix.Tasks.Osa.Serve do
  @moduledoc """
  Start the OSA backend HTTP server without the built-in CLI.

  Use this when connecting the Go TUI or other external clients.

  Usage: mix osa.serve
  """
  use Mix.Task
  require Logger

  @shortdoc "Start HTTP backend (no CLI)"

  @impl true
  def run(_args) do
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    # Zero-config: auto-detect a provider and continue (never blocks)
    Daemon.Onboarding.auto_configure()

    if Application.get_env(:daemon, :default_provider) == :ollama do
      MiosaProviders.Ollama.auto_detect_model()
      Daemon.Agent.Tier.detect_ollama_tiers()
    end

    port = Application.get_env(:daemon, :http_port, 8089)
    safe_puts("OSA backend serving on http://localhost:#{port}")
    safe_puts("Connect with: cd priv/go/tui-v2 && ./osa")
    safe_puts("Or: curl http://localhost:#{port}/health")
    Process.sleep(:infinity)
  end

  # Guard against lost console HANDLE on Windows (backgrounded processes,
  # piped output, or closed terminal windows).  Erlang raises ErlangError
  # wrapping :enotsup / :eio when the prim_tty port loses its CONOUT$
  # handle.  Silently drop the line rather than crash the VM.
  defp safe_puts(msg) do
    IO.puts(msg)
  rescue
    ErlangError -> :ok
  catch
    :error, :enotsup -> :ok
    :error, :eio     -> :ok
  end
end
