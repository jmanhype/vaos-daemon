defmodule Daemon.Agent.CortexProvider do
  @moduledoc """
  Bridge from MiosaMemory.Cortex to OSA's Providers.Registry.

  Implements the cortex_provider contract expected by MiosaMemory.Cortex.
  Wires the synthesis LLM call to OSA's provider registry.
  """

  def chat(messages, opts) do
    MiosaProviders.Registry.chat(messages, opts)
  end
end
