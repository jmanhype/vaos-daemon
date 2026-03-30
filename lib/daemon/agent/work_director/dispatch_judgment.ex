defmodule Daemon.Agent.WorkDirector.DispatchJudgment do
  @moduledoc """
  Pure-functional dispatch judgment module for WorkDirector Phase 2.

  Provides senior-engineer-level awareness: already-solved detection,
  PR conflict awareness, confidence scoring, and task decomposition.

  All functions are zero LLM cost — static analysis, `gh` CLI queries,
  and existing system data. Every public function has rescue/catch guards
  that fail open.
  """

  require Logger

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem
  alias Daemon.Intelligence.DecisionJournal
  alias Daemon.Intelligence.DecisionLedger
  alias Daemon.Vault

  # -- Configuration --
  @jaccard_merged_threshold 0.5
  @jaccard_open_threshold 0.4
  @merged_recency_hours 72
  @hot_zone_recency_days 7
  @hot_zone_min_prs 2
  @symbol_match_threshold 2
  @relevance_threshold 0.8
  @pr_cache_ttl_ms :timer.minutes(5)
  @decomposition_min_dirs 3
  @decomposition_max_items 5
  @confidence_high 0.7
  @confidence_low 0.4

  @doc_indicators ["document", "readme", "changelog", "guide", "migration notes", "wiki", "spec", "specification"]
  @code_indicators ~w(implement add create fix refactor module function endpoint handler)

  # -- Confidence signal weights --
  @signal_weights %{
    risk_inverse: 0.25,
    historical_success: 0.25,
    vault_signal: 0.20,
    tool_reliability: 0.10,
    pr_conflict_penalty: 0.20
  }

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Check if a task has already been solved by a recently merged PR,
  existing implementation, or is a non-code task.

  Returns `{:already_solved, reason}` or `:not_solved`.
  """
  @spec check_already_solved(WorkItem.t(), map(), String.t()) ::
          {:already_solved, String.t()} | :not_solved
  def check_already_solved(%WorkItem{} = item, enrichment, repo_path) do
    title_words = extract_words(item.title)

    # A. Recently merged PR match
    with :not_solved <- check_merged_pr_match(title_words, item.title, repo_path),
         # B. Existing implementation check
         :not_solved <- check_existing_implementation(title_words, enrichment),
         # C. Non-code task detection
         :not_solved <- check_non_code_task(item) do
      :not_solved
    end
  rescue
    e ->
      Logger.warning("[DispatchJudgment] check_already_solved error: #{Exception.message(e)}")
      :not_solved
  catch
    :exit, _ -> :not_solved
  end

  @doc """
  Check for PR conflicts with open PRs and detect hot zones.

  Returns `%{open_pr_conflicts: [...], hot_zones: [...], conflict_score: 0.0-1.0}`.
  """
  @spec check_pr_conflicts(WorkItem.t(), map(), String.t()) :: map()
  def check_pr_conflicts(%WorkItem{} = item, enrichment, repo_path) do
    title_words = extract_words(item.title)
    open_prs = get_cached_prs(:open, repo_path)

    # Title overlap detection
    title_conflicts =
      open_prs
      |> Enum.map(fn pr ->
        pr_words = extract_words(pr["title"] || "")
        similarity = jaccard_similarity(title_words, pr_words)
        Map.put(pr, "similarity", similarity)
      end)
      |> Enum.filter(fn pr -> pr["similarity"] >= @jaccard_open_threshold end)
      |> Enum.sort_by(fn pr -> -pr["similarity"] end)

    # File overlap (top 3 title-matched PRs only)
    file_territory_paths =
      (enrichment[:file_territory] || [])
      |> Enum.map(fn ft -> ft[:path] || ft["path"] end)
      |> Enum.reject(&is_nil/1)

    pr_conflicts =
      title_conflicts
      |> Enum.take(3)
      |> Enum.map(fn pr ->
        pr_files = get_pr_files_cached(pr["number"], repo_path)

        overlapping =
          Enum.filter(pr_files, fn pf ->
            Enum.any?(file_territory_paths, fn ft -> String.contains?(pf, ft) or String.contains?(ft, pf) end)
          end)

        %{
          number: pr["number"],
          title: pr["title"],
          branch: pr["headRefName"],
          title_similarity: pr["similarity"],
          overlapping_files: overlapping
        }
      end)

    # Hot zone detection
    hot_zones = detect_hot_zones(repo_path)

    # Compute conflict score (0.0-1.0)
    conflict_score = compute_conflict_score(pr_conflicts, hot_zones, file_territory_paths)

    %{
      open_pr_conflicts: pr_conflicts,
      hot_zones: hot_zones,
      conflict_score: conflict_score
    }
  rescue
    e ->
      Logger.warning("[DispatchJudgment] check_pr_conflicts error: #{Exception.message(e)}")
      %{open_pr_conflicts: [], hot_zones: [], conflict_score: 0.0}
  catch
    :exit, _ ->
      %{open_pr_conflicts: [], hot_zones: [], conflict_score: 0.0}
  end

  @doc """
  Compute aggregate confidence score from 5 signals.

  Returns `%{score: 0.0-1.0, level: :high|:medium|:low, recommendation: atom, breakdown: map}`.
  """
  @spec compute_confidence(WorkItem.t(), map(), map(), map()) :: map()
  def compute_confidence(%WorkItem{} = item, enrichment, risk, pr_conflicts) do
    # Signal 1: Risk inverse
    risk_score = risk[:score] || 5
    risk_inverse = (10 - min(risk_score, 10)) / 10

    # Signal 2: Historical success rate from DecisionJournal
    historical = compute_historical_signal(item)

    # Signal 3: Vault signal ratio
    vault_signal = compute_vault_signal(item)

    # Signal 4: Tool reliability from DecisionLedger
    tool_signal = compute_tool_reliability_signal()

    # Signal 5: PR conflict penalty
    conflict_score = pr_conflicts[:conflict_score] || 0.0
    pr_penalty = 1.0 - conflict_score

    breakdown = %{
      risk_inverse: %{value: risk_inverse, weight: @signal_weights.risk_inverse},
      historical_success: %{value: historical, weight: @signal_weights.historical_success},
      vault_signal: %{value: vault_signal, weight: @signal_weights.vault_signal},
      tool_reliability: %{value: tool_signal, weight: @signal_weights.tool_reliability},
      pr_conflict_penalty: %{value: pr_penalty, weight: @signal_weights.pr_conflict_penalty}
    }

    score =
      risk_inverse * @signal_weights.risk_inverse +
        historical * @signal_weights.historical_success +
        vault_signal * @signal_weights.vault_signal +
        tool_signal * @signal_weights.tool_reliability +
        pr_penalty * @signal_weights.pr_conflict_penalty

    # Clamp to 0.0-1.0
    score = max(0.0, min(1.0, score))

    # Determine level and recommendation
    {level, recommendation} = route_confidence(score, enrichment)

    %{
      score: Float.round(score, 3),
      level: level,
      recommendation: recommendation,
      breakdown: breakdown
    }
  rescue
    e ->
      Logger.warning("[DispatchJudgment] compute_confidence error: #{Exception.message(e)}")
      %{score: 0.6, level: :medium, recommendation: :proceed, breakdown: %{}}
  catch
    :exit, _ ->
      %{score: 0.6, level: :medium, recommendation: :proceed, breakdown: %{}}
  end

  @doc """
  Decompose a broad, low-confidence task into sub-items by directory clustering.

  Returns `{:ok, [sub_items]}` or `:cannot_decompose`.
  """
  @spec decompose(WorkItem.t(), map(), String.t()) :: {:ok, [map()]} | :cannot_decompose
  def decompose(%WorkItem{} = item, enrichment, _repo_path) do
    all_paths =
      ((enrichment[:file_territory] || []) |> Enum.map(fn ft -> ft[:path] || ft["path"] end)) ++
        ((enrichment[:relevant_files] || []) |> Enum.map(fn rf -> rf[:path] || rf["path"] end))

    all_paths = all_paths |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Group by top-level directory (first 3 path segments)
    clusters =
      all_paths
      |> Enum.group_by(fn path ->
        path
        |> String.split("/")
        |> Enum.take(3)
        |> Enum.join("/")
      end)
      |> Enum.sort_by(fn {_dir, files} -> -length(files) end)

    if length(clusters) < @decomposition_min_dirs do
      :cannot_decompose
    else
      total = min(length(clusters), @decomposition_max_items)

      sub_items =
        clusters
        |> Enum.take(total)
        |> Enum.with_index(1)
        |> Enum.map(fn {{dir, files}, index} ->
          dir_basename = dir |> String.split("/") |> List.last()
          file_list = Enum.join(files, ", ")

          %{
            title: "[#{index}/#{total}] #{item.title} -- #{dir_basename}",
            description: """
            Sub-task #{index} of #{total} for: #{item.title}

            Focus area: #{dir}
            Files: #{file_list}

            Original description:
            #{item.description || "(none)"}
            """,
            base_priority: item.base_priority * 0.9,
            metadata: %{
              parent_hash: item.content_hash,
              sub_index: index,
              focus_dir: dir
            }
          }
        end)

      {:ok, sub_items}
    end
  rescue
    e ->
      Logger.warning("[DispatchJudgment] decompose error: #{Exception.message(e)}")
      :cannot_decompose
  catch
    :exit, _ -> :cannot_decompose
  end

  # ============================================================
  # Internal: Already-Solved Sub-Checks
  # ============================================================

  defp check_merged_pr_match(title_words, _title, repo_path) do
    merged_prs = get_cached_prs(:merged, repo_path)
    cutoff = DateTime.add(DateTime.utc_now(), -@merged_recency_hours * 3600, :second)

    match =
      Enum.find(merged_prs, fn pr ->
        pr_words = extract_words(pr["title"] || "")
        similarity = jaccard_similarity(title_words, pr_words)

        merged_at =
          case DateTime.from_iso8601(pr["mergedAt"] || "") do
            {:ok, dt, _} -> dt
            # If mergedAt is unparseable, treat as ancient — don't match as recent
            _ -> ~U[2000-01-01 00:00:00Z]
          end

        similarity >= @jaccard_merged_threshold and DateTime.compare(merged_at, cutoff) != :lt
      end)

    if match do
      {:already_solved, "Similar PR recently merged: ##{match["number"]} #{match["title"]}"}
    else
      :not_solved
    end
  end

  defp check_existing_implementation(title_words, enrichment) do
    relevant_files = enrichment[:relevant_files] || []

    strong_matches =
      Enum.filter(relevant_files, fn rf ->
        relevance = rf[:relevance] || rf["relevance"] || 0.0
        symbols = rf[:symbols] || rf["symbols"] || []
        symbol_words = symbols |> Enum.flat_map(&extract_words/1) |> MapSet.new()
        title_set = MapSet.new(title_words)
        overlap = MapSet.intersection(symbol_words, title_set) |> MapSet.size()

        relevance >= @relevance_threshold and overlap >= @symbol_match_threshold
      end)

    if length(strong_matches) >= 2 do
      paths = Enum.map_join(strong_matches, ", ", fn rf -> rf[:path] || rf["path"] end)
      {:already_solved, "Strong matches in existing files: #{paths}"}
    else
      :not_solved
    end
  end

  defp check_non_code_task(item) do
    text = String.downcase("#{item.title} #{item.description || ""}")

    doc_hits = Enum.count(@doc_indicators, fn ind -> String.contains?(text, ind) end)
    code_hits = Enum.count(@code_indicators, fn ind -> String.contains?(text, ind) end)

    if doc_hits >= 2 and code_hits == 0 do
      {:already_solved, "Non-code task -- not suitable for autonomous dispatch"}
    else
      :not_solved
    end
  end

  # ============================================================
  # Internal: PR Conflict Detection
  # ============================================================

  defp detect_hot_zones(repo_path) do
    merged_prs = get_cached_prs(:merged, repo_path)
    cutoff_days = @hot_zone_recency_days

    cutoff = DateTime.add(DateTime.utc_now(), -cutoff_days * 86400, :second)

    recent_prs =
      Enum.filter(merged_prs, fn pr ->
        case DateTime.from_iso8601(pr["mergedAt"] || "") do
          {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
          _ -> false
        end
      end)

    # Count file modifications across recent merged PRs
    file_counts =
      recent_prs
      |> Enum.flat_map(fn pr -> get_pr_files_cached(pr["number"], repo_path) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_file, count} -> count >= @hot_zone_min_prs end)
      |> Enum.sort_by(fn {_file, count} -> -count end)
      |> Enum.map(fn {file, count} -> %{file: file, modification_count: count} end)

    file_counts
  end

  defp compute_conflict_score(pr_conflicts, hot_zones, file_territory_paths) do
    # Base score from title similarity of conflicts
    title_score =
      case pr_conflicts do
        [] -> 0.0
        conflicts ->
          max_sim = conflicts |> Enum.map(& &1.title_similarity) |> Enum.max(fn -> 0.0 end)
          max_sim * 0.5
      end

    # File overlap bonus
    file_score =
      case pr_conflicts do
        [] ->
          0.0

        conflicts ->
          total_overlaps = Enum.sum(Enum.map(conflicts, fn c -> length(c.overlapping_files) end))
          min(total_overlaps * 0.1, 0.3)
      end

    # Hot zone bonus
    hot_zone_score =
      if file_territory_paths != [] do
        hot_files = Enum.map(hot_zones, & &1.file)

        hot_overlap =
          Enum.count(file_territory_paths, fn ft ->
            Enum.any?(hot_files, fn hf -> String.contains?(hf, ft) or String.contains?(ft, hf) end)
          end)

        min(hot_overlap * 0.1, 0.2)
      else
        0.0
      end

    min(title_score + file_score + hot_zone_score, 1.0)
  end

  # ============================================================
  # Internal: Confidence Signals
  # ============================================================

  defp compute_historical_signal(item) do
    decisions = DecisionJournal.decisions()

    matching =
      Enum.filter(decisions, fn d ->
        d[:source] == item.source or d[:source] == :work_director
      end)

    if matching == [] do
      0.6
    else
      successes =
        Enum.count(matching, fn d ->
          d[:outcome] in [:merged, :success] or d[:status] == :completed
        end)

      total =
        Enum.count(matching, fn d ->
          d[:outcome] != nil or d[:status] not in [nil, :pending]
        end)

      if total > 0, do: successes / total, else: 0.6
    end
  rescue
    _ -> 0.6
  catch
    :exit, _ -> 0.6
  end

  defp compute_vault_signal(item) do
    recalls = Vault.recall(item.title, limit: 10)

    if recalls == [] do
      0.6
    else
      {successes, failures} =
        Enum.reduce(recalls, {0, 0}, fn {_cat, path, _score}, {s, f} ->
          case File.read(to_string(path)) do
            {:ok, content} ->
              cond do
                String.contains?(content, "Successful") -> {s + 1, f}
                String.contains?(content, "Failed") -> {s, f + 1}
                true -> {s, f}
              end

            _ ->
              {s, f}
          end
        end)

      total = successes + failures
      if total > 0, do: successes / total, else: 0.6
    end
  rescue
    _ -> 0.6
  catch
    :exit, _ -> 0.6
  end

  defp compute_tool_reliability_signal do
    patterns = DecisionLedger.patterns(min_observations: 5)

    if patterns == [] do
      0.7
    else
      total_success = Enum.sum(Enum.map(patterns, fn p -> p.success_count end))
      total_failure = Enum.sum(Enum.map(patterns, fn p -> p.failure_count end))
      total = total_success + total_failure

      if total > 0, do: total_success / total, else: 0.7
    end
  rescue
    _ -> 0.7
  catch
    :exit, _ -> 0.7
  end

  defp route_confidence(score, enrichment) do
    dir_count = count_distinct_dirs(enrichment)

    cond do
      score >= @confidence_high ->
        {:high, :proceed}

      score >= @confidence_low ->
        {:medium, :proceed_with_review}

      dir_count >= @decomposition_min_dirs ->
        {:low, :decompose}

      true ->
        {:low, :skip}
    end
  end

  defp count_distinct_dirs(enrichment) do
    all_paths =
      ((enrichment[:file_territory] || []) |> Enum.map(fn ft -> ft[:path] || ft["path"] end)) ++
        ((enrichment[:relevant_files] || []) |> Enum.map(fn rf -> rf[:path] || rf["path"] end))

    all_paths
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn path -> path |> String.split("/") |> Enum.take(3) |> Enum.join("/") end)
    |> Enum.uniq()
    |> length()
  end

  # ============================================================
  # Internal: PR Query Caching
  # ============================================================

  @doc false
  def get_cached_prs(state, repo_path) when state in [:open, :merged] do
    cache_key = :"pr_cache_#{state}"

    case Process.get(cache_key) do
      {prs, timestamp} ->
        age = System.monotonic_time(:millisecond) - timestamp

        if age < @pr_cache_ttl_ms do
          prs
        else
          prs = fetch_prs(state, repo_path)
          Process.put(cache_key, {prs, System.monotonic_time(:millisecond)})
          prs
        end

      nil ->
        prs = fetch_prs(state, repo_path)
        Process.put(cache_key, {prs, System.monotonic_time(:millisecond)})
        prs
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_prs(:open, repo_path) do
    json_fields = "number,title,headRefName"
    case System.cmd("gh", ["pr", "list", "--state", "open", "--json", json_fields, "--limit", "30"], cd: repo_path) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, result} -> result
          {:error, _} -> []
        end
      {_, _} -> []
    end
  rescue
    _ -> []
  end

  defp fetch_prs(:merged, repo_path) do
    json_fields = "number,title,headRefName,mergedAt"
    case System.cmd("gh", ["pr", "list", "--state", "merged", "--json", json_fields, "--limit", "30"], cd: repo_path) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, result} -> result
          {:error, _} -> []
        end
      {_, _} -> []
    end
  rescue
    _ -> []
  end

  @doc false
  def get_pr_files_cached(pr_number, repo_path) do
    cache_key = :"pr_files_#{pr_number}"

    case Process.get(cache_key) do
      nil ->
        files = fetch_pr_files(pr_number, repo_path)
        Process.put(cache_key, files)
        files

      cached ->
        cached
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_pr_files(pr_number, repo_path) do
    case System.cmd("gh", ["pr", "view", to_string(pr_number), "--json", "files"], cd: repo_path) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"files" => files}} when is_list(files) ->
            Enum.map(files, fn f -> f["path"] end) |> Enum.reject(&is_nil/1)
          _ -> []
        end
      {_, _} -> []
    end
  rescue
    _ -> []
  end

  # ============================================================
  # Internal: Text Utilities
  # ============================================================

  @stop_words ~w(the a an is are was were be been being have has had do does did will would shall should may might must can could and or but in on at to for of with by from as into through during before after above below between)

  defp extract_words(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn w -> w in @stop_words or String.length(w) < 3 end)
  end

  defp extract_words(_), do: []

  defp jaccard_similarity(words_a, words_b) do
    set_a = MapSet.new(words_a)
    set_b = MapSet.new(words_b)

    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end
end
