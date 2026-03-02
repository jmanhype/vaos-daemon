defmodule OptimalSystemAgent.Commands.Session do
  @moduledoc """
  Session and history commands: /new, /sessions, /resume, /history.
  """

  @doc "Handle the `/new` command."
  def cmd_new(_arg, _session_id) do
    {:action, :new_session, "Starting fresh session..."}
  end

  @doc "Handle the `/sessions` command."
  def cmd_sessions(_arg, _session_id) do
    sessions = OptimalSystemAgent.Agent.Memory.list_sessions()

    output =
      if sessions == [] do
        "No stored sessions."
      else
        header = "Stored sessions (#{length(sessions)}):\n"

        body =
          sessions
          |> Enum.sort_by(& &1[:last_active], :desc)
          |> Enum.take(20)
          |> Enum.map_join("\n", fn s ->
            id = s[:session_id] || "?"
            msgs = s[:message_count] || 0
            last = OptimalSystemAgent.Commands.Info.format_timestamp(s[:last_active])
            hint = s[:topic_hint] || ""
            hint_str = if hint != "", do: " — #{String.slice(hint, 0, 50)}", else: ""

            "  #{String.pad_trailing(id, 24)} #{String.pad_trailing("#{msgs} msgs", 10)} #{last}#{hint_str}"
          end)

        footer = "\n\nUse /resume <session-id> to continue a session."

        header <> body <> footer
      end

    {:command, output}
  end

  @doc "Handle the `/resume` command."
  def cmd_resume(arg, _session_id) do
    target = String.trim(arg)

    if target == "" do
      {:command, "Usage: /resume <session-id>\n\nUse /sessions to see available sessions."}
    else
      case OptimalSystemAgent.Agent.Memory.resume_session(target) do
        {:ok, messages} ->
          {:action, {:resume_session, target, messages},
           "Resuming session #{target} (#{length(messages)} messages)..."}

        {:error, :not_found} ->
          {:command, "Session not found: #{target}\n\nUse /sessions to see available sessions."}
      end
    end
  end

  @doc "Handle the `/history` command with subcommand routing."
  def cmd_history(arg, _session_id) do
    {channel_filter, trimmed} = extract_channel_flag(String.trim(arg))

    cond do
      trimmed == "" ->
        cmd_history_list(channel_filter)

      String.starts_with?(trimmed, "search ") ->
        query = String.trim_leading(trimmed, "search ") |> String.trim()
        cmd_history_search(query, channel_filter)

      true ->
        cmd_history_session(trimmed, channel_filter)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  @doc false
  def extract_channel_flag(arg) do
    case Regex.run(~r/--channel\s+(\S+)/, arg) do
      [match, channel] ->
        rest = String.replace(arg, match, "") |> String.trim()
        {channel, rest}

      nil ->
        {nil, arg}
    end
  end

  defp cmd_history_list(channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    base_query =
      from(m in Message,
        group_by: m.session_id,
        order_by: [desc: max(m.inserted_at)],
        limit: 20,
        select: %{
          session_id: m.session_id,
          count: count(m.id),
          last_at: max(m.inserted_at)
        }
      )

    query =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    sessions = Repo.all(query)

    filter_label = if channel_filter, do: " (channel: #{channel_filter})", else: ""

    if sessions == [] do
      {:command,
       "No message history found#{filter_label}. Messages will be stored after your next conversation."}
    else
      lines =
        Enum.map_join(sessions, "\n", fn s ->
          last = if s.last_at, do: NaiveDateTime.to_string(s.last_at), else: "unknown"

          "  #{String.pad_trailing(s.session_id, 36)} #{String.pad_leading(to_string(s.count), 5)} msgs  #{last}"
        end)

      {:command,
       "Recent sessions#{filter_label}:\n#{lines}\n\n  /history <session_id>    Browse messages\n  /history search <query>  Search all messages\n  /history --channel <ch>  Filter by channel"}
    end
  rescue
    _ ->
      sessions = OptimalSystemAgent.Agent.Memory.list_sessions()

      lines =
        Enum.map_join(Enum.take(sessions, 20), "\n", fn s ->
          "  #{String.pad_trailing(s.session_id, 36)} #{String.pad_leading(to_string(s.message_count), 5)} msgs"
        end)

      {:command, "Recent sessions (from files):\n#{lines}"}
  end

  defp cmd_history_session(session_id, channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    base_query =
      from(m in Message,
        where: m.session_id == ^session_id,
        order_by: [asc: m.inserted_at],
        limit: 50,
        select: %{role: m.role, content: m.content, channel: m.channel, inserted_at: m.inserted_at}
      )

    query =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    messages = Repo.all(query)

    filter_label = if channel_filter, do: " [#{channel_filter}]", else: ""

    if messages == [] do
      {:command, "No messages found for session: #{session_id}#{filter_label}"}
    else
      lines =
        Enum.map_join(messages, "\n", fn m ->
          time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
          role = String.pad_trailing(m.role, 10)
          ch = if m.channel, do: String.pad_trailing(m.channel, 10), else: String.pad_trailing("", 10)
          content = String.slice(m.content || "", 0, 100)
          "  #{time}  #{role}  #{ch}  #{content}"
        end)

      {:command, "Session #{session_id}#{filter_label} (#{length(messages)} messages):\n#{lines}"}
    end
  rescue
    _ -> {:command, "Error loading session: #{session_id}"}
  end

  defp cmd_history_search(query, channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    limit = 20
    pattern = "%#{query}%"

    base_query =
      from(m in Message,
        where: like(m.content, ^pattern),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: %{
          id: m.id,
          session_id: m.session_id,
          role: m.role,
          content: m.content,
          channel: m.channel,
          inserted_at: m.inserted_at
        }
      )

    q =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    results = Repo.all(q)

    filter_label = if channel_filter, do: " [#{channel_filter}]", else: ""

    if results == [] do
      {:command, "No messages matching: #{query}#{filter_label}"}
    else
      lines =
        Enum.map_join(results, "\n", fn m ->
          time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
          sid = String.slice(m.session_id, 0, 12)
          ch = if m[:channel], do: " [#{m[:channel]}]", else: ""
          content = String.slice(m.content || "", 0, 100)
          "  #{sid}  #{time}#{ch}  #{content}"
        end)

      {:command, "Search results for \"#{query}\"#{filter_label} (#{length(results)}):\n#{lines}"}
    end
  rescue
    _ ->
      results = OptimalSystemAgent.Agent.Memory.search_messages(query, limit: 20)

      if results == [] do
        {:command, "No messages matching: #{query}"}
      else
        lines =
          Enum.map_join(results, "\n", fn m ->
            time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
            sid = String.slice(m.session_id, 0, 12)
            content = String.slice(m.content || "", 0, 100)
            "  #{sid}  #{time}  #{content}"
          end)

        {:command, "Search results for \"#{query}\" (#{length(results)}):\n#{lines}"}
      end
  end
end
