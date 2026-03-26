defmodule Daemon.Investigation.SourceScoring do
  @moduledoc """
  Shared publisher/source quality scoring for investigate.ex and optimizer.

  Extracted from investigate.ex to eliminate scoring divergence between the
  investigation pipeline and the MCTS optimizer. Both now use the same
  pattern lists, the same low-quality journal gate, and the same
  review-type detection logic.
  """

  alias Daemon.Investigation.Strategy

  # Word-boundary patterns to avoid false positives on common words like "cell", "nature", "science"
  @high_quality_pattern_sources [
    {~S"\bnature\b(?!\s+of\b)", "i"},
    {~S"(?<!\bcomputer\s)(?<!\bdata\s)\bscience\b(?!\s+of\b|\s+fiction\b)", "i"},
    {~S"\blancet\b", "i"},
    {~S"\bbmj\b", "i"},
    {~S"\bnejm\b", "i"},
    {~S"\bcochrane\b", "i"},
    {~S"\bjama\b", "i"},
    {~S"\bplos\b", "i"},
    {~S"\bcell\s+(press|reports|research|biology|metabolism|host|systems|stem|chemical)\b", "i"},
    {~S"\bannual\s+review", "i"},
    {~S"\bpnas\b", "i"},
    {~S"\bwiley\b", "i"},
    {~S"\bspringer\b", "i"},
    {~S"\belsevier\b", "i"},
    {~S"\boxford\s+(university|academic|press)", "i"},
    {~S"\bcambridge\s+(university|press)", "i"},
    {~S"\bieee\b", "i"},
    {~S"\bacm\b", "i"},
    {~S"\bamerican\s+medical", "i"},
    {~S"\bamerican\s+psychological", "i"},
    {~S"\bbritish\s+medical", "i"},
    {~S"\bworld\s+health", "i"}
  ]

  # Low-quality JOURNAL/SOURCE patterns — matched ONLY against source/journal field.
  # Do NOT add topic terms here (e.g. "homeopath") — they'll match every paper's
  # title/abstract when investigating that topic, nuking all source quality scores.
  @low_quality_journal_sources [
    {~S"journal.of.alternative", "i"},
    {~S"complementary.*medicine", "i"},
    {~S"integrative.*medicine", "i"},
    {~S"traditional.*medicine", "i"},
    {~S"holistic.*medicine", "i"},
    {~S"journal.*healing", "i"},
    {~S"explore.*journal", "i"},
    {~S"frontier.*alternative", "i"},
    {~S"evidence.based.complementary", "i"},
    {~S"homeopath.*journal", "i"},
    {~S"journal.*homeopath", "i"},
    {~S"journal.*naturopath", "i"},
    {~S"journal.*ayurved", "i"}
  ]

  @doc """
  Score a paper's source quality using strategy's citation/publisher weights.
  Returns a float in [0.0, 1.0].
  """
  @spec score(map(), Strategy.t()) :: float()
  def score(paper, %Strategy{} = strategy) do
    title = (paper["title"] || "") |> String.downcase()
    source = (paper["source"] || "") |> String.downcase()
    abstract = (paper["abstract"] || "") |> String.downcase()
    citations = paper["citation_count"] || paper["citationCount"] || 0
    pub_types = paper["publicationTypes"] || []

    # 1. Citation count score (log scale, normalized to 0-1)
    citation_score = if citations > 0, do: :math.log10(citations) / 5.0, else: 0.0
    citation_score = min(citation_score, 1.0)

    # 2. Publisher/journal quality — low-quality check MUST come first
    # to prevent review-type boost from laundering garbage journals.
    # Only match journal patterns against SOURCE field — matching against title/abstract
    # would nuke every paper when investigating topics like "homeopathy".
    journal_text = "#{source}"
    is_low_quality = Enum.any?(compiled_low_quality_journal_patterns(), &Regex.match?(&1, journal_text))

    # 3. Publication type boost — only if NOT from a low-quality source
    # A "systematic review" in a CAM journal is not the same as one in Cochrane
    is_review_type = not is_low_quality and is_review_or_meta_analysis?(title, pub_types)

    # High-quality patterns match against full text (title + source + abstract)
    all_text = "#{title} #{source} #{abstract}"
    publisher_score = cond do
      is_low_quality -> 0.05  # Low-quality journals always score low, review or not
      is_review_type -> 0.8   # Reviews from non-garbage sources get grounded
      Enum.any?(compiled_high_quality_patterns(), &Regex.match?(&1, all_text)) -> 0.8
      true -> 0.3
    end

    # 4. Combined (using strategy's citation/publisher weights)
    Float.round(citation_score * strategy.citation_weight + publisher_score * strategy.publisher_weight, 3)
  end

  @doc """
  Compute just the publisher score component (no strategy weights).
  Used by optimizer's enrich_probe_ctx to cache publisher scores in paper_map.
  Returns 0.05, 0.3, or 0.8.
  """
  @spec publisher_score(map()) :: float()
  def publisher_score(paper) do
    title = (paper["title"] || "") |> String.downcase()
    source = (paper["source"] || "") |> String.downcase()
    abstract = (paper["abstract"] || "") |> String.downcase()
    pub_types = paper["publicationTypes"] || []

    journal_text = "#{source}"
    is_low_quality = Enum.any?(compiled_low_quality_journal_patterns(), &Regex.match?(&1, journal_text))
    is_review_type = not is_low_quality and is_review_or_meta_analysis?(title, pub_types)
    all_text = "#{title} #{source} #{abstract}"

    cond do
      is_low_quality -> 0.05
      is_review_type -> 0.8
      Enum.any?(compiled_high_quality_patterns(), &Regex.match?(&1, all_text)) -> 0.8
      true -> 0.3
    end
  end

  @doc "Detect systematic reviews and meta-analyses from publicationTypes field or title keywords."
  @spec is_review_or_meta_analysis?(String.t(), list()) :: boolean()
  def is_review_or_meta_analysis?(title, pub_types) do
    type_match = Enum.any?(List.wrap(pub_types), fn t ->
      t_lower = String.downcase(to_string(t))
      t_lower in ["review", "meta-analysis", "metaanalysis", "systematic review"]
    end)

    title_match = Regex.match?(
      ~r/\b(systematic\s+review|meta[\-\s]?analysis|cochrane|umbrella\s+review)\b/i,
      title
    )

    type_match or title_match
  end

  @doc false
  def compiled_high_quality_patterns do
    Enum.map(@high_quality_pattern_sources, fn {src, opts} -> Regex.compile!(src, opts) end)
  end

  @doc false
  def compiled_low_quality_journal_patterns do
    Enum.map(@low_quality_journal_sources, fn {src, opts} -> Regex.compile!(src, opts) end)
  end
end
