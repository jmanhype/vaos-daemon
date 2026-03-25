defmodule Daemon.Vault.ContextProfile do
  @moduledoc """
  Profile-driven context assembly for vault memories.

  Four profiles control which memories are pulled into context and how much
  space they get. This prevents vault content from overwhelming the context window.
  """
  alias Daemon.Vault.{Store, FactStore, Category}

  @type profile :: :default | :planning | :incident | :handoff

  @profiles %{
    default: %{
      categories: [:fact, :decision, :preference, :lesson],
      max_items: 15,
      max_chars: 3000,
      include_observations: true,
      observation_threshold: 0.3
    },
    planning: %{
      categories: [:decision, :project, :commitment, :lesson],
      max_items: 20,
      max_chars: 5000,
      include_observations: false,
      observation_threshold: 0.5
    },
    incident: %{
      categories: [:fact, :lesson, :decision],
      max_items: 25,
      max_chars: 6000,
      include_observations: true,
      observation_threshold: 0.2
    },
    handoff: %{
      categories: Category.all(),
      max_items: 30,
      max_chars: 8000,
      include_observations: true,
      observation_threshold: 0.1
    }
  }

  @doc "Build context string for a profile."
  @spec build(profile(), keyword()) :: String.t()
  def build(profile \\ :default, opts \\ []) do
    config = Map.get(@profiles, profile, @profiles[:default])
    query = Keyword.get(opts, :query)

    # Gather facts
    facts =
      FactStore.active_facts()
      |> maybe_filter_by_query(query)
      |> Enum.take(config.max_items)

    facts_section =
      if facts == [] do
        ""
      else
        items =
          Enum.map_join(facts, "\n", fn f ->
            "- [#{f[:type]}] #{f[:value]} (confidence: #{f[:confidence] || "n/a"})"
          end)

        "## Active Facts\n\n#{items}"
      end

    # Gather recent vault files
    files_section =
      config.categories
      |> Enum.flat_map(fn cat ->
        Store.list(cat) |> Enum.take(3) |> Enum.map(&{cat, &1})
      end)
      |> Enum.take(config.max_items)
      |> Enum.map(fn {cat, path} ->
        title = path |> Path.basename(".md") |> String.replace("-", " ")
        "- [#{cat}] #{title}"
      end)
      |> case do
        [] -> ""
        items -> "## Vault Memories\n\n#{Enum.join(items, "\n")}"
      end

    context =
      [facts_section, files_section]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # Truncate to max chars
    if String.length(context) > config.max_chars do
      String.slice(context, 0, config.max_chars) <> "\n\n_[vault context truncated]_"
    else
      context
    end
  end

  @doc "List available profiles."
  @spec profiles() :: [profile()]
  def profiles, do: Map.keys(@profiles)

  # --- Private ---

  defp maybe_filter_by_query(facts, nil), do: facts

  defp maybe_filter_by_query(facts, query) do
    q = String.downcase(query)

    Enum.filter(facts, fn f ->
      String.contains?(String.downcase(f[:value] || ""), q)
    end)
  end
end
