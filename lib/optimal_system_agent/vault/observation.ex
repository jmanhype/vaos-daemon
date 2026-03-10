defmodule OptimalSystemAgent.Vault.Observation do
  @moduledoc """
  Scored observation with time-based decay.

  Observations capture notable patterns, behaviors, and signals during agent
  operation. Each observation has a score (0.0-1.0) that decays over time,
  allowing stale observations to naturally fall out of context windows.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          score: float(),
          decay_rate: float(),
          tags: [String.t()],
          created_at: DateTime.t(),
          session_id: String.t() | nil,
          source: String.t() | nil
        }

  @enforce_keys [:id, :content, :score, :created_at]
  defstruct [
    :id,
    :content,
    :score,
    :created_at,
    :session_id,
    :source,
    decay_rate: 0.05,
    tags: []
  ]

  @doc "Create a new observation with auto-generated ID and timestamp."
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      content: content,
      score: Keyword.get(opts, :score, 0.7),
      decay_rate: Keyword.get(opts, :decay_rate, 0.05),
      tags: Keyword.get(opts, :tags, []),
      created_at: DateTime.utc_now(),
      session_id: Keyword.get(opts, :session_id),
      source: Keyword.get(opts, :source)
    }
  end

  @doc """
  Classify content and return a suggested score.

  Higher scores for actionable/important content, lower for routine.
  """
  @spec classify(String.t()) :: {float(), [String.t()]}
  def classify(content) do
    content_lower = String.downcase(content)

    {score, tags} =
      cond do
        String.contains?(content_lower, ["error", "crash", "failure", "bug"]) ->
          {0.9, ["error", "incident"]}

        String.contains?(content_lower, ["decided", "decision", "chose", "agreed"]) ->
          {0.85, ["decision"]}

        String.contains?(content_lower, ["learned", "lesson", "realized", "discovered"]) ->
          {0.8, ["learning"]}

        String.contains?(content_lower, ["prefer", "always", "never", "style"]) ->
          {0.75, ["preference"]}

        String.contains?(content_lower, ["pattern", "recurring", "common"]) ->
          {0.7, ["pattern"]}

        true ->
          {0.5, ["general"]}
      end

    {score, tags}
  end

  @doc """
  Calculate the current effective score after time-based decay.

  Uses exponential decay: effective_score = score * e^(-decay_rate * hours_elapsed)
  """
  @spec effective_score(t()) :: float()
  def effective_score(%__MODULE__{score: score, decay_rate: rate, created_at: created_at}) do
    hours_elapsed = DateTime.diff(DateTime.utc_now(), created_at, :second) / 3600.0
    decayed = score * :math.exp(-rate * hours_elapsed)
    Float.round(max(decayed, 0.0), 4)
  end

  @doc "Check if an observation is still relevant (effective score above threshold)."
  @spec relevant?(t(), float()) :: boolean()
  def relevant?(obs, threshold \\ 0.1) do
    effective_score(obs) >= threshold
  end

  @doc "Format an observation as a markdown string for storage."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = obs) do
    tags_str = Enum.join(obs.tags, ", ")

    """
    ---
    category: observation
    id: #{obs.id}
    score: #{obs.score}
    decay_rate: #{obs.decay_rate}
    tags: #{tags_str}
    session_id: #{obs.session_id || ""}
    source: #{obs.source || ""}
    created: #{DateTime.to_iso8601(obs.created_at)}
    ---

    #{obs.content}
    """
    |> String.trim_trailing()
  end

  @doc "Parse an observation from a markdown string with YAML frontmatter."
  @spec from_markdown(String.t()) :: {:ok, t()} | :error
  def from_markdown(markdown) do
    case parse_frontmatter(markdown) do
      {:ok, meta, body} ->
        {:ok,
         %__MODULE__{
           id: Map.get(meta, "id", generate_id()),
           content: String.trim(body),
           score: parse_float(Map.get(meta, "score", "0.5")),
           decay_rate: parse_float(Map.get(meta, "decay_rate", "0.05")),
           tags: parse_tags(Map.get(meta, "tags", "")),
           session_id: blank_to_nil(Map.get(meta, "session_id")),
           source: blank_to_nil(Map.get(meta, "source")),
           created_at: parse_datetime(Map.get(meta, "created"))
         }}

      :error ->
        :error
    end
  end

  # --- Private ---

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp parse_frontmatter(text) do
    case String.split(text, "---", parts: 3) do
      ["", yaml, body] ->
        meta =
          yaml
          |> String.trim()
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ": ", parts: 2) do
              [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
              _ -> acc
            end
          end)

        {:ok, meta, body}

      _ ->
        :error
    end
  end

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.5
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1

  defp parse_tags(str) when is_binary(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
