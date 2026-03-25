defmodule Mix.Tasks.Osa.Setup do
  @moduledoc """
  Interactive setup wizard for Daemon.

  Creates ~/.daemon/ directory structure, configures provider and API keys,
  and writes all bootstrap files.

  Usage: mix osa.setup
  """
  use Mix.Task

  @shortdoc "Interactive OSA setup wizard"

  @impl true
  def run(_args) do
    Daemon.Onboarding.run_setup_mode()
  end
end
