defmodule Daemon.Python.Embeddings do
  @moduledoc """
  Pure-Elixir semantic search using Ollama for embeddings + ETS vector store.

  No Python sidecar. Embedding vectors are generated via Ollama's
  `/api/embeddings` endpoint and stored in an ETS table. Cosine similarity
  is computed in pure Elixir (dot product / magnitude).

  The module name is kept as `Daemon.Python.Embeddings` for backward
  compatibility — all callers continue to work unchanged.
  """
  require Logger

  @ets_table :daemon_embedding_vectors
  @model "nomic-embed-text"
  @timeout 15_000

  # ── Public API (same contract as before) ────────────────────────

  @doc "Generate an embedding vector for the given text."
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, atom()}
  def embed(text) when is_binary(text) do
    case ollama_embed(text) do
      {:ok, vec} -> {:ok, vec}
      {:error, _} = err -> err
    end
  end

  @doc """
  Semantic search across indexed entries.

  Returns `{:ok, [%{"id" => id, "score" => float}]}` sorted by descending similarity.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 10)

    case ollama_embed(query) do
      {:ok, query_vec} ->
        ensure_table()

        results =
          :ets.tab2list(@ets_table)
          |> Enum.map(fn {id, vec} ->
            %{"id" => id, "score" => cosine_similarity(query_vec, vec)}
          end)
          |> Enum.sort_by(& &1["score"], :desc)
          |> Enum.take(top_k)

        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Reindex entries in the ETS vector store.

  Each entry: `%{id: "...", content: "..."}`. Embeds each via Ollama
  and stores the vector in ETS. Returns `{:ok, count}`.
  """
  @spec reindex([map()]) :: {:ok, non_neg_integer()} | {:error, atom()}
  def reindex(entries) when is_list(entries) do
    ensure_table()

    # Batch embed — sequential for now, Ollama handles one at a time anyway
    indexed =
      entries
      |> Enum.reduce(0, fn entry, count ->
        id = to_string(entry[:id] || entry["id"] || "")
        content = to_string(entry[:content] || entry["content"] || "")

        case ollama_embed(content) do
          {:ok, vec} ->
            :ets.insert(@ets_table, {id, vec})
            count + 1

          {:error, reason} ->
            Logger.debug("[embeddings] Failed to embed #{id}: #{inspect(reason)}")
            count
        end
      end)

    {:ok, indexed}
  end

  @doc "Compute cosine similarity between two texts."
  @spec similarity(String.t(), String.t()) :: {:ok, float()} | {:error, atom()}
  def similarity(text_a, text_b) do
    with {:ok, vec_a} <- ollama_embed(text_a),
         {:ok, vec_b} <- ollama_embed(text_b) do
      {:ok, cosine_similarity(vec_a, vec_b)}
    end
  end

  @doc "Check if Ollama is reachable for embedding generation."
  @spec available?() :: boolean()
  def available? do
    url = ollama_url()

    case Req.get("#{url}/api/tags", receive_timeout: 3_000, connect_options: [timeout: 2_000]) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  # ── Ollama HTTP client ──────────────────────────────────────────

  defp ollama_embed(text) do
    url = ollama_url()

    case Req.post("#{url}/api/embeddings",
           json: %{model: @model, prompt: text},
           receive_timeout: @timeout,
           connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: %{"embedding" => vec}}} when is_list(vec) ->
        {:ok, vec}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[embeddings] Ollama returned #{status}: #{inspect(body)}")
        {:error, :ollama_error}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ollama_url do
    Application.get_env(:daemon, :ollama_url, "http://localhost:11434")
  end

  # ── Pure Elixir cosine similarity ───────────────────────────────

  defp cosine_similarity(vec_a, vec_b) when length(vec_a) == length(vec_b) do
    {dot, mag_a, mag_b} =
      Enum.zip(vec_a, vec_b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {a, b}, {dot, ma, mb} ->
        {dot + a * b, ma + a * a, mb + b * b}
      end)

    denom = :math.sqrt(mag_a) * :math.sqrt(mag_b)

    if denom > 0.0, do: dot / denom, else: 0.0
  end

  defp cosine_similarity(_vec_a, _vec_b), do: 0.0

  # ── ETS table management ────────────────────────────────────────

  defp ensure_table do
    :ets.new(@ets_table, [:named_table, :public, :set])
  rescue
    ArgumentError -> :ok  # already exists
  end
end
