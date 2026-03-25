defmodule Daemon.Vault.Inject do
  @moduledoc """
  Deterministic prompt injection from vault content.

  Matches keywords and triggers against vault files to inject relevant
  rules, decisions, and preferences into the system prompt.
  """
  alias Daemon.Vault.{Store, FactStore}

  @doc """
  Query vault for content matching keywords and return injection text.

  Searches facts and vault files for matches, returns formatted text
  suitable for system prompt injection.
  """
  @spec query(String.t(), keyword()) :: String.t()
  def query(input, opts \\ []) do
    max_items = Keyword.get(opts, :max_items, 10)
    max_chars = Keyword.get(opts, :max_chars, 2000)
    categories = Keyword.get(opts, :categories, [:decision, :preference, :lesson, :fact])

    # Search facts
    fact_matches =
      FactStore.search(input)
      |> Enum.take(max_items)
      |> Enum.map(fn f -> "- [#{f[:type]}] #{f[:value]}" end)

    # Search vault files
    file_matches =
      Store.search(input, categories: categories, limit: max_items)
      |> Enum.map(fn {cat, path, _score} ->
        title = path |> Path.basename(".md") |> String.replace("-", " ")
        "- [#{cat}] #{title}"
      end)

    items = (fact_matches ++ file_matches) |> Enum.take(max_items)

    if items == [] do
      ""
    else
      result = "### Vault Context\n\n#{Enum.join(items, "\n")}"

      if String.length(result) > max_chars do
        String.slice(result, 0, max_chars)
      else
        result
      end
    end
  end

  @doc """
  Auto-inject: given a user message, find relevant vault content.
  Returns empty string if nothing relevant found.
  """
  @spec auto_inject(String.t()) :: String.t()
  def auto_inject(message) do
    # Extract keywords (words > 3 chars, excluding common words)
    keywords =
      message
      |> String.downcase()
      |> String.split(~r/\W+/)
      |> Enum.filter(&(String.length(&1) > 3))
      |> Enum.reject(&(&1 in ~w(this that with from have been would could should)))
      |> Enum.take(5)

    if keywords == [] do
      ""
    else
      query(Enum.join(keywords, " "), max_items: 5, max_chars: 1000)
    end
  end
end
