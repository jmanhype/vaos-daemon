defmodule OptimalSystemAgent.Agent.Memory.Episodic do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Episodic.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  defdelegate start_link(opts \\ []), to: MiosaMemory.Episodic
  defdelegate child_spec(opts), to: MiosaMemory.Episodic
  defdelegate record(event_type, data, session_id), to: MiosaMemory.Episodic
  defdelegate recall(query, opts \\ []), to: MiosaMemory.Episodic
  defdelegate recent(session_id, limit \\ 20), to: MiosaMemory.Episodic
  defdelegate stats(), to: MiosaMemory.Episodic
  defdelegate clear_session(session_id), to: MiosaMemory.Episodic
  defdelegate temporal_decay(timestamp, half_life_hours), to: MiosaMemory.Episodic
end
