defmodule Daemon.Investigation.FastProbe do
  @moduledoc """
  Fast EIG (Expected Information Gain) scorer for MCTS rollouts.

  Takes a strategy + pre-fetched investigation data and computes EIG in ~1-5ms.
  No LLM calls, no API calls — pure map/filter/reduce on evidence items.

  EIG = 0.35 * discriminability + 0.25 * grounding_coverage +
        0.20 * direction_confidence + 0.20 * uncertainty_reduction
  """

  alias Daemon.Investigation.Strategy

  @doc """
  Score a strategy against pre-fetched investigation data.
  Returns a float in [0.0, 1.0] representing the expected information gain.

  probe_ctx expects:
    - papers: list of paper maps
    - paper_map: %{integer => paper_map} with cached :_publisher_score
    - verified_supporting: list of evidence maps
    - verified_opposing: list of evidence maps
  """
  @spec score(Strategy.t(), map()) :: float()
  def score(%Strategy{} = strategy, probe_ctx) do
    paper_map = probe_ctx[:paper_map] || %{}
    verified_supporting = probe_ctx[:verified_supporting] || []
    verified_opposing = probe_ctx[:verified_opposing] || []
    all_evidence = verified_supporting ++ verified_opposing

    if all_evidence == [] do
      0.0
    else
      # 1. Re-classify evidence into grounded/belief using strategy's threshold
      {grounded, belief} = reclassify(all_evidence, paper_map, strategy)

      # 2. Re-score all evidence using strategy's hierarchy weights
      grounded_scores = Enum.map(grounded, &rescore(&1, strategy))
      belief_scores = Enum.map(belief, &rescore(&1, strategy))

      # 3. Split grounded by side for direction computation
      supporting_set = MapSet.new(Enum.map(verified_supporting, & &1.summary))

      {grounded_for, grounded_against} =
        Enum.split_with(grounded, fn ev -> MapSet.member?(supporting_set, ev.summary) end)

      for_score = grounded_for |> Enum.map(&rescore(&1, strategy)) |> Enum.sum()
      against_score = grounded_against |> Enum.map(&rescore(&1, strategy)) |> Enum.sum()

      # 4. Compute EIG components
      discriminability = compute_discriminability(grounded_scores, belief_scores)
      grounding_coverage = compute_grounding_coverage(grounded, all_evidence)
      direction_confidence = compute_direction_confidence(for_score, against_score, strategy)
      uncertainty_reduction = compute_uncertainty_reduction(grounded_scores)

      # 5. Weighted EIG
      eig =
        0.35 * discriminability +
          0.25 * grounding_coverage +
          0.20 * direction_confidence +
          0.20 * uncertainty_reduction

      clamp(eig, 0.0, 1.0)
    end
  end

  # Re-classify evidence into {grounded, belief} based on strategy's threshold
  defp reclassify(evidence, paper_map, strategy) do
    Enum.split_with(evidence, fn ev ->
      sq = source_quality(ev, paper_map, strategy)
      sq >= strategy.grounded_threshold
    end)
  end

  # Compute source quality using strategy's citation/publisher weights
  defp source_quality(ev, paper_map, strategy) do
    case ev[:paper_ref] || ev.paper_ref do
      nil ->
        0.15

      n ->
        case Map.get(paper_map, n) do
          nil ->
            0.1

          paper ->
            citations = paper["citation_count"] || paper["citationCount"] || 0
            citation_score = if citations > 0, do: :math.log10(citations) / 5.0, else: 0.0
            citation_score = min(citation_score, 1.0)
            # Use cached publisher score (pre-computed in Optimizer.enrich_probe_ctx)
            publisher_score = Map.get(paper, :_publisher_score, 0.3)
            citation_score * strategy.citation_weight + publisher_score * strategy.publisher_weight
        end
    end
  end

  # Re-score an evidence item using strategy's hierarchy weights
  defp rescore(ev, strategy) do
    base =
      case ev[:verification] || ev.verification do
        v when v in ["verified", :verified] -> 1.0
        v when v in ["partial", :partial] -> 0.5
        _ -> 0.0
      end

    type_weight =
      case ev[:paper_type] || ev.paper_type do
        :review -> strategy.review_weight
        :trial -> strategy.trial_weight
        :study -> strategy.study_weight
        _ -> 1.0
      end

    citation_count = ev[:citation_count] || ev.citation_count || 0
    citation_bonus = :math.log10(max(citation_count, strategy.citation_bonus_base))

    base * type_weight * citation_bonus
  end

  # How well does the grounded_threshold separate high from low quality evidence?
  defp compute_discriminability(grounded_scores, belief_scores) do
    grounded_mean = safe_mean(grounded_scores)
    belief_mean = safe_mean(belief_scores)
    total_mean = safe_mean(grounded_scores ++ belief_scores)

    if total_mean == 0.0 do
      0.0
    else
      clamp(abs(grounded_mean - belief_mean) / max(total_mean, 0.001), 0.0, 1.0)
    end
  end

  # What fraction of evidence is in the grounded store?
  defp compute_grounding_coverage(grounded, all_evidence) do
    total = length(all_evidence)
    if total == 0, do: 0.0, else: length(grounded) / total
  end

  # How clearly does the grounded evidence point in one direction?
  defp compute_direction_confidence(for_score, against_score, strategy) do
    total = for_score + against_score

    if total == 0.0 do
      0.0
    else
      bigger = max(for_score, against_score)
      smaller = max(min(for_score, against_score), 0.001)
      ratio = bigger / smaller
      # Higher confidence when ratio clearly exceeds direction_ratio
      clamp((ratio - 1.0) / (strategy.direction_ratio - 1.0 + 0.001), 0.0, 1.0)
    end
  end

  # Low variance in grounded scores = less uncertainty = higher reduction
  defp compute_uncertainty_reduction(grounded_scores) do
    if grounded_scores == [] do
      0.0
    else
      mean = safe_mean(grounded_scores)

      variance =
        grounded_scores
        |> Enum.map(fn s -> (s - mean) * (s - mean) end)
        |> safe_mean()

      clamp(1.0 - :math.sqrt(variance) / max(mean, 0.001), 0.0, 1.0)
    end
  end

  defp safe_mean([]), do: 0.0
  defp safe_mean(list), do: Enum.sum(list) / length(list)

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
