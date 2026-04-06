defmodule Daemon.Vault.FactExtractor do
  @moduledoc """
  Rule-based fact extraction using regex patterns with three-layer taxonomy.

  Extracts structured facts from free-text content without LLM dependency.
  Each pattern returns a fact with type, value, confidence score, and
  knowledge layer (axiomatic/protocol/episodic).

  Three-layer taxonomy (OmniFlow + Hextropian three-box architecture):
    - Axiomatic: verified truths about the world (facts, relationships, lessons)
    - Protocol: procedures, decisions, preferences, commitments
    - Episodic: event sequences, observations (handled by EpisodeTracker)
  """

  @type fact :: %{
          type: String.t(),
          layer: String.t(),
          predicate: String.t(),
          value: String.t(),
          confidence: float(),
          pattern: String.t()
        }

  # Maps category → {knowledge_layer, predicate}
  @taxonomy %{
    decision: {:protocol, "vaos:protocol_decision"},
    preference: {:protocol, "vaos:protocol_preference"},
    fact: {:axiomatic, "vaos:axiom_fact"},
    lesson: {:axiomatic, "vaos:axiom_lesson"},
    commitment: {:protocol, "vaos:protocol_commitment"},
    relationship: {:axiomatic, "vaos:axiom_relationship"}
  }

  @pattern_sources [
    # Decisions (protocol layer)
    {:decision, {~S"(?:decided|chose|agreed|picked|selected)\s+(?:to\s+)?(.{10,120})", "i"}, 0.85},
    {:decision, {~S"(?:going with|we(?:'ll| will) use|switching to)\s+(.{5,100})", "i"}, 0.8},

    # Preferences (protocol layer)
    {:preference, {~S"(?:prefer|always use|never use|like to use)\s+(.{5,80})", "i"}, 0.85},
    {:preference, {~S"(?:style|convention|standard):\s*(.{5,100})", "i"}, 0.8},

    # Facts / technical (axiomatic layer)
    {:fact, {~S"(?:runs on|built with|powered by|requires)\s+(.{5,80})", "i"}, 0.8},
    {:fact, {~S"(?:version|v)\s*(\d+\.\d+(?:\.\d+)?)", "i"}, 0.9},
    {:fact, {~S"(?:port|listens? on)\s+(\d{2,5})", "i"}, 0.85},
    {:fact, {~S"(?:endpoint|url|api):\s*((?:https?:\/\/|\/)[^\s]{5,100})", "i"}, 0.8},

    # Lessons (axiomatic layer)
    {:lesson, {~S"(?:learned|lesson|takeaway|insight):\s*(.{10,150})", "i"}, 0.85},
    {:lesson, {~S"(?:root cause|caused by|because of)\s+(.{10,120})", "i"}, 0.8},
    {:lesson, {~S"(?:fix(?:ed)? by|solved by|resolved by)\s+(.{10,120})", "i"}, 0.8},

    # Commitments (protocol layer)
    {:commitment, {~S"(?:promised|committed|will deliver|deadline)\s+(.{10,100})", "i"}, 0.85},

    # Relationships (axiomatic layer)
    {:relationship, {~S"(?:owner|maintainer|lead|responsible):\s*(.{3,60})", "i"}, 0.8},
    {:relationship, {~S"(@\w+)\s+(?:is|works on|manages|owns)\s+(.{5,80})", "i"}, 0.8}
  ]

  @doc """
  Extract all matching facts from content.

  Returns a list of fact maps sorted by confidence (highest first).
  Each fact includes `:layer` (axiomatic/protocol) and `:predicate` for
  direct assertion into the knowledge triple store.
  """
  @spec extract(String.t()) :: [fact()]
  def extract(content) when is_binary(content) do
    @pattern_sources
    |> Enum.flat_map(fn {type, {src, opts}, confidence} ->
      regex = Regex.compile!(src, opts)

      case Regex.run(regex, content) do
        [_match | captures] ->
          value = Enum.join(captures, " ") |> String.trim()
          {layer, predicate} = Map.fetch!(@taxonomy, type)

          [
            %{
              type: Atom.to_string(type),
              layer: Atom.to_string(layer),
              predicate: predicate,
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
  def extract_confident(content, threshold \\ 0.8) do
    extract(content) |> Enum.filter(&(&1.confidence >= threshold))
  end

  @doc """
  Extract and group facts by knowledge layer.
  """
  @spec extract_by_layer(String.t()) :: %{String.t() => [fact()]}
  def extract_by_layer(content) do
    extract(content) |> Enum.group_by(& &1.layer)
  end

  @doc """
  Extract and group facts by type.
  """
  @spec extract_grouped(String.t()) :: %{String.t() => [fact()]}
  def extract_grouped(content) do
    extract(content) |> Enum.group_by(& &1.type)
  end

  @doc """
  Convert a fact to a knowledge triple {subject, predicate, object}.
  """
  @spec to_triple(fact(), String.t()) :: {String.t(), String.t(), String.t()}
  def to_triple(fact, subject) do
    {subject, fact.predicate, fact.value}
  end
end
