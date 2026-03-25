defmodule Daemon.Agent.Memory do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Store.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  defdelegate start_link(opts), to: MiosaMemory.Store
  defdelegate child_spec(opts), to: MiosaMemory.Store
  defdelegate append(session_id, entry), to: MiosaMemory.Store
  defdelegate load_session(session_id), to: MiosaMemory.Store
  defdelegate remember(content, category \\ "general"), to: MiosaMemory.Store
  defdelegate recall(), to: MiosaMemory.Store
  defdelegate recall_relevant(message, max_tokens \\ 2000), to: MiosaMemory.Store
  defdelegate search(query, opts \\ []), to: MiosaMemory.Store
  defdelegate archive(max_age_days \\ 30), to: MiosaMemory.Store
  defdelegate memory_stats(), to: MiosaMemory.Store
  defdelegate list_sessions(), to: MiosaMemory.Store
  defdelegate resume_session(session_id), to: MiosaMemory.Store
  defdelegate search_messages(query, opts \\ []), to: MiosaMemory.Store
  defdelegate session_stats(session_id), to: MiosaMemory.Store
  defdelegate extract_insights(messages), to: MiosaMemory.Store
  defdelegate maybe_pattern_nudge(turn_count, messages), to: MiosaMemory.Store
  defdelegate parse_memory_entries(content), to: MiosaMemory.Parser, as: :parse
  defdelegate extract_keywords(message), to: MiosaMemory.Index
end
