defmodule OptimalSystemAgent.Agent.Cortex do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Cortex.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  defdelegate start_link(opts), to: MiosaMemory.Cortex
  defdelegate child_spec(opts), to: MiosaMemory.Cortex
  defdelegate bulletin(), to: MiosaMemory.Cortex
  defdelegate refresh(), to: MiosaMemory.Cortex
  defdelegate active_topics(), to: MiosaMemory.Cortex
  defdelegate session_summary(session_id), to: MiosaMemory.Cortex
  defdelegate synthesis_stats(), to: MiosaMemory.Cortex
end
