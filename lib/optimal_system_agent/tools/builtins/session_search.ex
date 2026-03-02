defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch do
  @moduledoc """
  Full-text session search via SQLite FTS5.

  Indexes session content (title + conversation text) and provides BM25-ranked
  search results with highlighted snippets. Registered as an LLM-callable tool
  so the model can find past conversations and patterns.

  Uses raw SQL through `Ecto.Adapters.SQL.query/3` — FTS5 virtual tables
  aren't Ecto-native.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Store.Repo

  @impl true
  def name, do: "session_search"

  @impl true
  def description do
    "Search past conversation sessions by keyword. " <>
      "Returns matching sessions ranked by relevance with text snippets. " <>
      "Use to find previous conversations, patterns, and solutions."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query — keywords or phrases to find in past sessions"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum results to return (default: 10)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = params) do
    limit = params["limit"] || 10

    case search(query, limit: limit) do
      {:ok, []} ->
        {:ok, "No sessions found matching '#{query}'."}

      {:ok, results} ->
        formatted =
          Enum.map_join(results, "\n\n", fn r ->
            "**#{r.title || "Untitled"}** (session: #{r.session_id})\n" <>
              "  Relevance: #{r.rank}\n" <>
              "  #{r.snippet}"
          end)

        {:ok, "Found #{length(results)} matching sessions:\n\n#{formatted}"}

      {:error, reason} ->
        {:error, "Session search failed: #{reason}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: query"}

  # ── Public API (called by other modules) ────────────────────────

  @doc """
  Index a session for full-text search.

  Inserts or replaces the session content in the FTS5 table.
  Call this when saving a session to make it searchable.
  """
  @spec index_session(String.t(), map()) :: :ok | {:error, term()}
  def index_session(session_id, %{title: title, content: content}) do
    sql = """
    INSERT OR REPLACE INTO sessions_fts(session_id, title, content)
    VALUES (?1, ?2, ?3)
    """

    case Repo.query(sql, [session_id, title || "", content || ""]) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[SessionSearch] Failed to index session #{session_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[SessionSearch] Index error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Search sessions using FTS5 full-text search with BM25 ranking.

  Returns `{:ok, results}` where each result has `:session_id`, `:title`,
  `:snippet`, and `:rank` fields.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Sanitize query for FTS5 — escape special characters
    safe_query = sanitize_fts_query(query)

    if safe_query == "" do
      {:ok, []}
    else
      sql = """
      SELECT session_id, title,
             snippet(sessions_fts, 2, '»', '«', '...', 32) AS snippet,
             rank
      FROM sessions_fts
      WHERE sessions_fts MATCH ?1
      ORDER BY rank
      LIMIT ?2
      """

      case Repo.query(sql, [safe_query, limit]) do
        {:ok, %{rows: rows}} ->
          results =
            Enum.map(rows, fn [session_id, title, snippet, rank] ->
              %{
                session_id: session_id,
                title: title,
                snippet: snippet,
                rank: Float.round(rank * -1.0, 3)
              }
            end)

          {:ok, results}

        {:error, reason} ->
          Logger.warning("[SessionSearch] Search failed: #{inspect(reason)}")
          {:error, inspect(reason)}
      end
    end
  rescue
    e ->
      Logger.warning("[SessionSearch] Search error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Delete a session from the FTS index."
  @spec delete_session(String.t()) :: :ok | {:error, term()}
  def delete_session(session_id) do
    sql = "DELETE FROM sessions_fts WHERE session_id = ?1"

    case Repo.query(sql, [session_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Private ─────────────────────────────────────────────────────

  # Sanitize input for FTS5 MATCH syntax. Strip special FTS operators
  # and wrap each term for safe matching.
  defp sanitize_fts_query(query) do
    query
    |> String.replace(~r/["\(\)\*\:\^]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.map(fn term -> "\"#{term}\"" end)
    |> Enum.join(" ")
  end
end
