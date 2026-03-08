defmodule OptimalSystemAgent.Agent.Learning do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Learning.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  defdelegate start_link(opts \\ []), to: MiosaMemory.Learning
  defdelegate child_spec(opts), to: MiosaMemory.Learning
  defdelegate observe(interaction), to: MiosaMemory.Learning
  defdelegate correction(what_was_wrong, what_is_right), to: MiosaMemory.Learning
  defdelegate error(tool_name, error_message, context), to: MiosaMemory.Learning
  defdelegate metrics(), to: MiosaMemory.Learning
  defdelegate patterns(), to: MiosaMemory.Learning
  defdelegate solutions(), to: MiosaMemory.Learning
  defdelegate consolidate(), to: MiosaMemory.Learning
end
