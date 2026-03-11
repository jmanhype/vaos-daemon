defmodule Mix.Tasks.Osa.Chat do
  @moduledoc """
  Start an interactive CLI chat session with the agent.

  Usage: mix osa.chat
  """
  use Mix.Task

  @shortdoc "Start interactive CLI chat"

  @impl true
  def run(_args) do
    # Silence all boot logs — the CLI should start clean
    Logger.configure(level: :none)

    Mix.Task.run("app.start")

    # Restore warnings after boot
    Logger.configure(level: :warning)

    # Zero-config: auto-detect a provider and continue (never blocks)
    OptimalSystemAgent.Onboarding.auto_configure()

    if OptimalSystemAgent.Onboarding.first_run?() do
      OptimalSystemAgent.Soul.reload()
    end

    # Re-run Ollama auto-detect AFTER apply_config, because config.json may
    # contain the onboarding default "llama3.2:latest" which overwrites
    # the auto-detected best model from Application.start/2.
    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      MiosaProviders.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

    OptimalSystemAgent.Channels.CLI.start()
  end
end
