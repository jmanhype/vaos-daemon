defmodule OptimalSystemAgent.Agent.Replay do
  @moduledoc """
  Replays a stored conversation history into a fresh session.

  Loads messages from `Memory.load_session/1` and dispatches each
  user message into a newly created session via `SDK.Session` +
  `Loop.process_message/2`.
  """
  require Logger

  alias OptimalSystemAgent.Agent.{Loop, Memory}
  alias OptimalSystemAgent.SDK.Session

  @max_replay_messages 100

  @doc """
  Replay the conversation stored under `source_session_id` into a new session.

  Options:
  - `:session_id` — target session id (auto-generated if omitted)
  - `:provider` — LLM provider override
  - `:model` — model override

  Returns `{:ok, replay_session_id}` or `{:error, reason}`.
  """
  def replay(source_session_id, opts \\ []) do
    messages = Memory.load_session(source_session_id) || []

    user_messages =
      Enum.filter(messages, fn m ->
        Map.get(m, "role") == "user" || Map.get(m, :role) == :user
      end)

    if user_messages == [] do
      {:error, :not_found}
    else
      replay_id = Keyword.get_lazy(opts, :session_id, fn ->
        "replay-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      end)

      create_opts =
        [session_id: replay_id, channel: :http]
        |> maybe_put(:provider, Keyword.get(opts, :provider))
        |> maybe_put(:model, Keyword.get(opts, :model))

      case Session.create(create_opts) do
        {:ok, _} ->
          Task.Supervisor.start_child(
            OptimalSystemAgent.TaskSupervisor,
            fn -> dispatch_messages(replay_id, user_messages) end,
            restart: :temporary
          )

          {:ok, replay_id}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp dispatch_messages(session_id, messages) do
    total = length(messages)

    if total > @max_replay_messages do
      Logger.warning(
        "Replay #{session_id}: truncating #{total} messages to #{@max_replay_messages}"
      )
    end

    messages
    |> Enum.take(@max_replay_messages)
    |> Enum.each(fn m ->
      content = Map.get(m, "content") || Map.get(m, :content) || ""

      if content != "" do
        Loop.process_message(session_id, content)
      end
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
