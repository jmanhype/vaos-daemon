defmodule OptimalSystemAgent.Vault.FactExtractor do
  @moduledoc """
  Rule-based fact extraction using regex patterns.

  Extracts structured facts from free-text content without LLM dependency.
  Each pattern returns a fact with type, value, and confidence score.
  """

  @type fact :: %{
          type: String.t(),
          value: String.t(),
          confidence: float(),
          pattern: String.t()
        }

  @patterns [
    # Decisions
    {:decision, ~r/(?:decided|chose|agreed|picked|selected)\s+(?:to\s+)?(.{10,120})/i, 0.85},
    {:decision, ~r/(?:going with|we(?:'ll| will) use|switching to)\s+(.{5,100})/i, 0.8},

    # Preferences
    {:preference, ~r/(?:prefer|always use|never use|like to use)\s+(.{5,80})/i, 0.75},
    {:preference, ~r/(?:style|convention|standard):\s*(.{5,100})/i, 0.7},

    # Facts / technical
    {:fact, ~r/(?:runs on|built with|uses|powered by|requires)\s+(.{5,80})/i, 0.7},
    {:fact, ~r/(?:version|v)\s*(\d+\.\d+(?:\.\d+)?)/i, 0.9},
    {:fact, ~r/(?:port|listens? on)\s+(\d{2,5})/i, 0.85},
    {:fact, ~r/(?:endpoint|url|api):\s*((?:https?:\/\/|\/)[^\s]{5,100})/i, 0.8},

    # Lessons
    {:lesson, ~r/(?:learned|lesson|takeaway|insight):\s*(.{10,150})/i, 0.8},
    {:lesson, ~r/(?:root cause|caused by|because of)\s+(.{10,120})/i, 0.75},
    {:lesson, ~r/(?:fix(?:ed)? by|solved by|resolved by)\s+(.{10,120})/i, 0.75},

    # Commitments
    {:commitment, ~r/(?:promised|committed|will deliver|deadline)\s+(.{10,100})/i, 0.8},
    {:commitment,
     ~r/(?:by|before|due)\s+((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{4}-\d{2}-\d{2}).{0,50})/i,
     0.7},

    # Relationships
    {:relationship, ~r/(?:owner|maintainer|lead|responsible):\s*(.{3,60})/i, 0.8},
    {:relationship, ~r/(@\w+)\s+(?:is|works on|manages|owns)\s+(.{5,80})/i, 0.75}
  ]

  @doc """
  Extract all matching facts from content.

  Returns a list of fact maps sorted by confidence (highest first).
  """
  @spec extract(String.t()) :: [fact()]
  def extract(content) when is_binary(content) do
    @patterns
    |> Enum.flat_map(fn {type, regex, confidence} ->
      case Regex.run(regex, content) do
        [_match | captures] ->
          value = Enum.join(captures, " ") |> String.trim()

          [
            %{
              type: Atom.to_string(type),
              value: value,
              confidence: confidence,
              pattern: inspect(regex)
            }
          ]

        nil ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.value)
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  @doc """
  Extract facts above a confidence threshold.
  """
  @spec extract_confident(String.t(), float()) :: [fact()]
  def extract_confident(content, threshold \\ 0.7) do
    extract(content) |> Enum.filter(&(&1.confidence >= threshold))
  end

  @doc """
  Extract and group facts by type.
  """
  @spec extract_grouped(String.t()) :: %{String.t() => [fact()]}
  def extract_grouped(content) do
    extract(content) |> Enum.group_by(& &1.type)
  end
end
