defmodule OptimalSystemAgent.Vault.Handoff do
  @moduledoc """
  Session handoff documents — summarize session state for continuity.

  Creates markdown documents capturing what was worked on, decisions made,
  open questions, and next steps.
  """
  alias OptimalSystemAgent.Vault.{Store, FactStore}

  @doc "Create a handoff document for the current session."
  @spec create(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create(session_id, context \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    recent_facts =
      FactStore.active_facts()
      |> Enum.take(10)
      |> Enum.map_join("\n", fn f -> "- [#{f[:type]}] #{f[:value]}" end)

    summary = Map.get(context, :summary, "Session ended normally.")
    open_questions = Map.get(context, :open_questions, [])
    next_steps = Map.get(context, :next_steps, [])

    questions_md =
      if open_questions == [],
        do: "_None_",
        else: Enum.map_join(open_questions, "\n", &"- #{&1}")

    steps_md =
      if next_steps == [],
        do: "_None_",
        else: Enum.map_join(next_steps, "\n", &"- #{&1}")

    content = """
    ## Summary

    #{summary}

    ## Recent Facts

    #{if recent_facts == "", do: "_No facts recorded._", else: recent_facts}

    ## Open Questions

    #{questions_md}

    ## Next Steps

    #{steps_md}
    """

    dir = Path.join(Store.vault_root(), "handoffs")
    File.mkdir_p!(dir)

    filename = "#{session_id}-#{now |> String.replace(":", "-")}.md"
    path = Path.join(dir, filename)

    fm = """
    ---
    category: handoff
    session_id: #{session_id}
    created: #{now}
    ---
    """

    File.write(path, fm <> "\n# Session Handoff\n\n" <> content)
    |> case do
      :ok -> {:ok, path}
      error -> error
    end
  end

  @doc "Load the most recent handoff document."
  @spec load_latest() :: {:ok, String.t(), String.t()} | :none
  def load_latest do
    dir = Path.join(Store.vault_root(), "handoffs")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort(:desc)
        |> case do
          [latest | _] ->
            path = Path.join(dir, latest)

            case File.read(path) do
              {:ok, content} -> {:ok, path, content}
              _ -> :none
            end

          [] ->
            :none
        end

      _ ->
        :none
    end
  end

  @doc "Load a handoff for a specific session."
  @spec load_for_session(String.t()) :: {:ok, String.t()} | :none
  def load_for_session(session_id) do
    dir = Path.join(Store.vault_root(), "handoffs")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.find(&String.starts_with?(&1, session_id))
        |> case do
          nil ->
            :none

          file ->
            case File.read(Path.join(dir, file)) do
              {:ok, content} -> {:ok, content}
              _ -> :none
            end
        end

      _ ->
        :none
    end
  end
end
