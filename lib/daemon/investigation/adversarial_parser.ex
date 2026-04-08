defmodule Daemon.Investigation.AdversarialParser do
  @moduledoc """
  Parses adversarial investigate output into evidence items.

  The default prompt asks for a rigid numbered format, but providers sometimes
  drift into nearby variants like `1)`, markdown emphasis, `Score:` labels, or
  short sourced paragraphs. This parser accepts the strict format first, then a
  looser fallback before giving up.
  """

  @type parsed_item :: %{
          summary: String.t(),
          source_type: :sourced | :reasoning,
          strength: integer(),
          paper_ref: integer() | nil,
          verified: false,
          verification: String.t(),
          paper_type: :other,
          citation_count: non_neg_integer(),
          score: float()
        }

  @strict_pattern ~r/^\s*(?:\d+[\.\)]|[-*])\s*\**\[(SOURCED|REASONING)\]\**\s*\((?:strength|score)\s*:\s*(\d+)\)\s*(.+)$/im
  @loose_pattern ~r/^\s*(?:\d+[\.\)]|[-*])\s*\**\[(SOURCED|REASONING)\]\**\s*(?:[-:]\s*|\s+)(?:\**(?:strength|score)\**\s*:\s*(\d+)\s*(?:[-:]\s*)?)?(.+)$/im
  @paper_ref_pattern ~r/\[Paper\s+(\d+)\]/i

  @spec parse(String.t()) :: [parsed_item()]
  def parse(text) when is_binary(text) do
    normalized = normalize(text)

    normalized
    |> parse_structured()
    |> case do
      [] -> parse_paper_paragraphs(normalized)
      items -> items
    end
  end

  def parse(_), do: []

  defp normalize(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/```(?:json|text|markdown)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
  end

  defp parse_structured(text) do
    strict_items = parse_with_pattern(text, @strict_pattern)

    case strict_items do
      [] -> parse_with_pattern(text, @loose_pattern)
      items -> items
    end
  end

  defp parse_with_pattern(text, pattern) do
    pattern
    |> Regex.scan(text)
    |> Enum.map(&match_to_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp match_to_item([_, type, strength, summary]),
    do: build_item(type, strength, summary)

  defp match_to_item(_), do: nil

  defp parse_paper_paragraphs(text) do
    text
    |> String.split(~r/\n\s*\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@paper_ref_pattern, &1))
    |> Enum.map(fn paragraph ->
      summary =
        paragraph
        |> String.replace(~r/^\s*(?:\d+[\.\)]|[-*])\s*/, "")
        |> String.replace(~r/\s+/, " ")

      build_item("SOURCED", "5", summary)
    end)
    |> Enum.reject(&(&1.summary == ""))
  end

  defp build_item(type, strength_str, summary) do
    source_type =
      case String.upcase(to_string(type)) do
        "SOURCED" -> :sourced
        _ -> :reasoning
      end

    summary =
      summary
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^\)\s*/, "")
      |> String.replace(~r/^\s*[-:]\s*/, "")

    %{
      summary: summary,
      source_type: source_type,
      strength: normalize_strength(strength_str),
      paper_ref: extract_paper_ref(summary),
      verified: false,
      verification: "pending",
      paper_type: :other,
      citation_count: 0,
      score: 0.0
    }
  end

  defp normalize_strength(strength_str) do
    case Integer.parse(to_string(strength_str || "5")) do
      {n, _} when n >= 1 and n <= 10 -> n
      {n, _} when n > 10 -> 10
      {n, _} when n < 1 -> 1
      _ -> 5
    end
  end

  defp extract_paper_ref(text) do
    case Regex.run(@paper_ref_pattern, text) do
      [_, num] ->
        case Integer.parse(num) do
          {n, _} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
