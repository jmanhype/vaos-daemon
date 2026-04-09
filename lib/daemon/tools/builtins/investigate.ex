defmodule Daemon.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — adversarial dual-prompt architecture.

  EVIDENCE QUALITY PIPELINE: Paper type classification + evidence hierarchy scoring.
  Every citation is verified against paper abstracts AND classified by type
  (systematic review, RCT, observational study, other).

  Scores come from: verification status * evidence hierarchy weight * citation bonus.
  - Systematic reviews/meta-analyses score 3x
  - RCTs/experiments score 2x
  - Observational studies score 1.5x
  - Unclassified score 1x

  PAPER-FIRST DESIGN: Runs THREE parallel paper search pairs (FOR, AGAINST, and
  SYSTEMATIC REVIEWS), then feeds merged papers to TWO adversarial LLM prompts.

  Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv.
  Uses vaos-ledger's Literature module for Semantic Scholar and OpenAlex,
  with alphaXiv MCP for embedding-based arXiv search.

  AEC TWO-STORE ARCHITECTURE (arxiv.org/abs/2602.03974):
  Evidence is classified into two stores based on source quality:
  - Grounded store: high-quality sources (major journals, high citations) — determines verdict
  - Belief store: low-quality sources (predatory journals, niche) — context only, cannot flip direction
  This prevents the homeopathy problem where niche journals outvote established science.

  ACE PATTERN (Agentic Context Engineering):
  - Helpful/Harmful counters on evidence triples in the knowledge graph
  - Compound loop fetches prior EVIDENCE, not prior conclusions
  """

  require Logger

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger
  alias Vaos.Ledger.Epistemic.Models
  alias Vaos.Ledger.Research.Literature
  alias Vaos.Ledger.Epistemic.Policy
  alias Vaos.Ledger.Research.Pipeline
  alias Vaos.Ledger.ML.CrashLearner

  alias Daemon.Intelligence.AdaptationTrials
  alias Daemon.ModelSelection

  alias Daemon.Investigation.{
    AdversarialParser,
    ClaimFamily,
    Strategy,
    StrategyStore,
    SourceScoring,
    PromptConfig,
    PromptFeedback,
    PromptSelector
  }

  @ledger_path Path.join(System.user_home!(), ".openclaw/investigate_ledger.json")
  @ledger_name :investigate_ledger

  @stop_words ~w(the a an is are was were be been being have has had do does did
    will would shall should may might must can could of in to for with on at by
    from as into through during before after above below between out off over
    under again further then once here there when where why how all both each
    few more most other some such no nor not only own same so than too very it
    its this that these those and but or if while)
  @search_relation_words ~w(cause causes caused causing improve improves improved improving
    prevent prevents prevented preventing effective effectiveness efficacy associated
    association linked links linking relation relationship claims claim whether if)
  @retrieval_discourse_terms ~w(misinformation disinformation journalism media communication
    discourse ideology belief beliefs denial denialism history historical philosophy
    perception attitudes social conference public commentary review survey overview)

  # AEC Two-Store Architecture (arxiv.org/abs/2602.03974)
  # Grounded store: high-quality sources that can determine the verdict
  # Belief store: low-quality sources for context only (cannot flip direction)
  # Threshold is now configurable via Strategy.grounded_threshold (default: 0.4)
  # Scoring patterns extracted to Daemon.Investigation.SourceScoring

  # -- Source Circuit Breaker --
  # Per-source adaptive circuit breaker prevents wasting 30s on consistently-broken APIs.
  # States: :closed (normal) → :open (tripped, skip) → :half_open (probe one request)
  @circuit_table :investigate_source_health
  # Consecutive failures to trip
  @circuit_failure_threshold 3
  # 10 min cooldown before half-open probe
  @circuit_cooldown_ms 600_000
  @circuit_sources [:openalex, :semantic_scholar, :alphaxiv, :huggingface]
  # Reuse the same uncertainty bar that triggers an iteration hint.
  @high_uncertainty_threshold 0.5
  @emergent_question_contested_directions ~w(genuinely_contested belief_contested)

  # OpenAlex polite pool — requests with mailto get routed to faster servers
  @openalex_mailto "vaos-daemon@miosa.ai"

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "investigate"

  @impl true
  def description do
    "Investigate a claim or topic: runs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv, " <>
      "FOR, AGAINST, and REVIEWS), then dual adversarial LLM analysis with citation verification " <>
      "and evidence hierarchy scoring (review > trial > study > other)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "description" => "The claim or topic to investigate"
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["standard", "deep"],
          "description" =>
            "standard = adversarial debate + citation verification; deep = standard + research pipeline (hypotheses, testing, report)"
        },
        "steering" => %{
          "type" => "string",
          "description" =>
            "Optional steering context injected into advocate system prompts (from ActiveLearner bottleneck diagnosis)"
        },
        "apply_pending_trial" => %{
          "type" => "boolean",
          "description" =>
            "Opt-in manual/eval path: consume one pending adaptation trial for this topic and merge its steering into the investigation"
        },
        "metadata" => %{
          "type" => "object",
          "description" =>
            "Optional metadata merged into :investigation_complete event payload (e.g. source_module, anomaly_type)"
        }
      },
      "required" => ["topic"]
    }
  end

  @impl true
  def execute(args) do
    args = maybe_apply_pending_trial_steering(args)

    topic = Map.get(args, "topic") || Map.get(args, :topic) || ""
    depth = Map.get(args, "depth") || Map.get(args, :depth) || "standard"
    steering = Map.get(args, "steering") || Map.get(args, :steering) || ""
    caller_metadata = Map.get(args, "metadata") || Map.get(args, :metadata) || %{}

    topic = String.trim(to_string(topic))

    if topic == "" do
      {:error, "Missing topic"}
    else
      run_investigation(topic, depth, steering, caller_metadata)
    end
  end

  @doc false
  def maybe_apply_pending_trial_steering(args, trials_module \\ AdaptationTrials)
      when is_map(args) do
    topic = Map.get(args, "topic") || Map.get(args, :topic)
    steering = Map.get(args, "steering") || Map.get(args, :steering) || ""

    if apply_pending_trial?(args) and is_binary(topic) and String.trim(topic) != "" do
      case trials_module.consume_trial(topic) do
        {:ok, %{steering: trial_steering}}
        when is_binary(trial_steering) and trial_steering != "" ->
          merged = merge_manual_steering(steering, trial_steering)

          Logger.info(
            "[investigate] Manual trial steering applied — #{String.slice(trial_steering, 0, 80)}..."
          )

          Map.put(args, "steering", merged)

        _ ->
          args
      end
    else
      args
    end
  end

  # -- Main pipeline ---------------------------------------------------

  defp apply_pending_trial?(args) when is_map(args) do
    case Map.get(args, "apply_pending_trial") || Map.get(args, :apply_pending_trial) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp merge_manual_steering("", trial_steering), do: trial_steering
  defp merge_manual_steering(existing, ""), do: existing
  defp merge_manual_steering(existing, trial_steering), do: existing <> "\n\n" <> trial_steering

  defp run_investigation(topic, depth, steering, caller_metadata) do
    # DecisionJournal dedup — check if this investigation conflicts with in-flight work
    source = Map.get(caller_metadata, :source_module, :investigation)
    branch = investigation_branch(topic)

    case Daemon.Intelligence.DecisionJournal.propose(source, :investigate, %{
           topic: topic,
           branch: branch
         }) do
      {:conflict, reason} ->
        Logger.info("[investigate] DecisionJournal conflict: #{reason}")
        blocked_reason = "conflict: #{reason}"
        observe_trial_failure(topic, blocked_reason)
        {:ok, "Investigation skipped — #{blocked_reason}"}

      _ ->
        result =
          try do
            do_run_investigation(topic, depth, steering, caller_metadata)
          rescue
            e ->
              Logger.error("[investigate] Investigation raised: #{Exception.message(e)}")
              {:error, Exception.message(e)}
          catch
            kind, reason ->
              Logger.error("[investigate] Investigation #{kind}: #{inspect(reason)}")
              {:error, "#{kind}: #{inspect(reason)}"}
          end

        case result do
          {:error, reason} -> observe_trial_failure(topic, reason)
          _ -> :ok
        end

        # Always clear in-flight status so future investigations aren't blocked
        outcome =
          case result do
            {:ok, _} -> :success
            {:error, _} -> :failed
            _ -> :success
          end

        Daemon.Intelligence.DecisionJournal.record_outcome(branch, outcome, %{topic: topic})

        result
    end
  end

  defp do_run_investigation(topic, depth, steering, caller_metadata) do
    investigation_started_ms = monotonic_ms()

    :inets.start()
    :ssl.start()
    ensure_circuit_table()
    alphaxiv_enabled? = Daemon.Tools.Builtins.AlphaXivClient.auth_available?()

    # Start alphaXiv MCP in an unlinked process — the MCP client crash-loops
    # on auth failure (401) and sends EXIT to linked callers, killing the pipeline.
    # Trap exits for the duration of the start, then restore.
    old_trap = Process.flag(:trap_exit, true)

    try do
      if alphaxiv_enabled? do
        Daemon.Tools.Builtins.AlphaXivClient.start_link()

        # Drain any immediate EXIT from the MCP client crashing during handshake
        receive do
          {:EXIT, _pid, reason} ->
            Logger.warning("[investigate] alphaXiv MCP crashed during init: #{inspect(reason)}")
        after
          2_000 -> :ok
        end
      else
        Logger.info("[investigate] alphaXiv auth missing — skipping MCP startup")
      end
    catch
      :exit, reason ->
        Logger.warning("[investigate] alphaXiv MCP unavailable: #{inspect(reason)}")
    after
      Process.flag(:trap_exit, old_trap)
    end

    # 0. Create scorer cache ETS table upfront (owned by caller, visible to child tasks)
    ensure_scorer_cache()

    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 1a. CrashLearner is now supervised by AgentServices — just verify it's alive
    unless GenServer.whereis(:daemon_crash_learner) do
      Logger.warning("[investigate] CrashLearner not running — crash reporting will be skipped")
    end

    # 1b. Load prompt templates via Thompson Sampling selector
    {prompts, variant_id} =
      try do
        PromptSelector.select()
      rescue
        _ -> {PromptConfig.load(), "default"}
      end

    # 2. Extract search keywords from a normalized factual topic so wrapper
    # phrasing like "examine claims that ..." does not pollute retrieval.
    search_topic = normalized_search_topic(topic)
    keywords = extract_keywords(search_topic)

    # 2a. Load prior winning strategy for search/LLM params (scoring params tuned later by optimizer)
    #     Fallback chain: topic-specific → _global (Retrospector-optimized) → defaults
    prior_strategy =
      case StrategyStore.load_best(topic) do
        {:ok, strategy} ->
          Logger.info(
            "[investigate] Loaded prior strategy (gen #{strategy.generation}) for search params"
          )

          strategy

        :error ->
          case StrategyStore.load_best("_global") do
            {:ok, strategy} ->
              Logger.info(
                "[investigate] Loaded _global strategy (gen #{strategy.generation}) from Retrospector"
              )

              strategy

            :error ->
              Strategy.default()
          end
      end

    # 3. Prior knowledge search — fetch prior EVIDENCE, not conclusions
    case ensure_store_started() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[investigate] Knowledge store unavailable: #{inspect(reason)}")
    end

    store = store_ref()
    prior_evidence = fetch_prior_evidence_by_keywords(store, keywords)

    # 4. MULTI-SOURCE PAPER SEARCH: Semantic Scholar + OpenAlex + alphaXiv (parallel)
    #    Uses prior strategy's top_n_papers and per_query_limit for tuned search breadth
    {{all_papers, source_counts}, paper_search_ms} =
      timed(fn ->
        search_all_papers(search_topic, keywords, prior_strategy,
          alphaxiv_enabled?: alphaxiv_enabled?
        )
      end)

    Logger.info("[investigate] Papers: #{length(all_papers)} total (#{inspect(source_counts)})")

    # 5. Format papers context for LLM prompts
    papers_context = format_papers(all_papers, prompts)

    # 6. Prior evidence context (evidence only, no conclusions)
    prior_text =
      if prior_evidence == [] do
        ""
      else
        "\n\nPreviously investigated evidence on related topics:\n" <>
          Enum.join(prior_evidence, "\n") <> "\n"
      end

    # 6a. Fetch known failure pitfalls from CrashLearner
    pitfalls =
      try do
        {:ok, plist} = CrashLearner.get_pitfalls(:daemon_crash_learner)
        plist
      rescue
        _ -> []
      end

    pitfall_context =
      if pitfalls != [] do
        text = Enum.map(pitfalls, fn p -> "- #{p.summary}" end) |> Enum.join("
")
        "

Known failure patterns to avoid:
#{text}
"
      else
        ""
      end

    # 6b. Steering context from ActiveLearner bottleneck diagnosis
    steering_context =
      if is_binary(steering) and steering != "" do
        "\n\n" <> steering
      else
        ""
      end

    # 7. TWO ADVERSARIAL LLM CALLS (sequential for rate-limit safety)
    example_format = prompts["example_format"]

    for_prompt =
      PromptConfig.render(prompts["advocate_user_template"],
        position: "TRUE",
        direction: "",
        claim: topic,
        papers_context: papers_context,
        prior_text: prior_text,
        arg_type: "arguments",
        example_format: example_format,
        arg_word: "argument"
      ) <> "\n\n" <> adversarial_output_contract()

    against_prompt =
      PromptConfig.render(prompts["advocate_user_template"],
        position: "FALSE",
        direction: " AGAINST it",
        claim: topic,
        papers_context: papers_context,
        prior_text: prior_text,
        arg_type: "counterarguments",
        example_format: example_format,
        arg_word: "counterargument"
      ) <> "\n\n" <> adversarial_output_contract()

    for_messages = [
      %{role: "system", content: prompts["for_system"] <> pitfall_context <> steering_context},
      %{role: "user", content: for_prompt}
    ]

    against_messages = [
      %{
        role: "system",
        content: prompts["against_system"] <> pitfall_context <> steering_context
      },
      %{role: "user", content: against_prompt}
    ]

    timings = %{
      preflight_ms: max(0, elapsed_ms(investigation_started_ms) - paper_search_ms),
      paper_search_ms: paper_search_ms
    }

    model = preferred_utility_model()
    llm_opts = [temperature: prior_strategy.adversarial_temperature, max_tokens: 8192]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    # Run advocates sequentially — concurrent calls trigger rate limits on some
    # providers (Zhipu/GLM), and reasoning models need generous timeouts.
    {for_result, for_llm_ms} = timed(fn -> Providers.chat(for_messages, llm_opts) end)
    timings = Map.put(timings, :for_llm_ms, for_llm_ms)

    {against_result, against_llm_ms} =
      timed(fn -> Providers.chat(against_messages, llm_opts) end)

    timings = Map.put(timings, :against_llm_ms, against_llm_ms)

    # 8. Parse both sides
    supporting =
      case for_result do
        {:ok, %{content: response}} when is_binary(response) and response != "" ->
          parse_adversarial_response(response, "FOR")

        {:ok, %{content: ""}} ->
          Logger.warning(
            "[investigate] FOR-side LLM returned empty content (reasoning model token exhaustion?)"
          )

          []

        {:error, reason} ->
          Logger.warning("[investigate] FOR-side LLM call failed: #{inspect(reason)}")

          try do
            unless String.starts_with?(
                     topic,
                     Daemon.Investigation.SelfDiagnosis.self_diagnosis_prefix()
                   ) do
              CrashLearner.report_crash(
                :daemon_crash_learner,
                "investigate_for_#{short_hash(topic)}",
                inspect(reason),
                nil,
                %{topic: topic, side: "for", papers_count: length(all_papers)}
              )
            end
          rescue
            _ -> :ok
          end

          []

        _ ->
          Logger.warning("[investigate] FOR-side LLM call failed")
          []
      end

    opposing =
      case against_result do
        {:ok, %{content: response}} when is_binary(response) and response != "" ->
          parse_adversarial_response(response, "AGAINST")

        {:ok, %{content: ""}} ->
          Logger.warning(
            "[investigate] AGAINST-side LLM returned empty content (reasoning model token exhaustion?)"
          )

          []

        {:error, reason} ->
          Logger.warning("[investigate] AGAINST-side LLM call failed: #{inspect(reason)}")

          try do
            unless String.starts_with?(
                     topic,
                     Daemon.Investigation.SelfDiagnosis.self_diagnosis_prefix()
                   ) do
              CrashLearner.report_crash(
                :daemon_crash_learner,
                "investigate_against_#{short_hash(topic)}",
                inspect(reason),
                nil,
                %{topic: topic, side: "against", papers_count: length(all_papers)}
              )
            end
          rescue
            _ -> :ok
          end

          []

        _ ->
          Logger.warning("[investigate] AGAINST-side LLM call failed")
          []
      end

    trace_context =
      build_trace_context(
        topic,
        steering,
        for_messages,
        against_messages,
        for_result,
        against_result
      )

    # 8a. Build paper map for citation verification
    paper_map =
      all_papers
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {i, p} end)

    # 8b. Handle partial results honestly
    cond do
      supporting == [] and opposing == [] ->
        timings = complete_phase_timings(timings, investigation_started_ms)
        log_phase_timings(topic, timings)
        {:error, "Both adversarial LLM calls failed"}

      supporting == [] ->
        # Only AGAINST succeeded — verify what we have
        {{verified_opposing, verification_stats}, citation_verification_ms} =
          timed(fn -> verify_citations(opposing, paper_map, prompts) end)

        timings = Map.put(timings, :citation_verification_ms, citation_verification_ms)
        post_processing_started_ms = monotonic_ms()

        classified_opposing =
          classify_evidence_store(verified_opposing, paper_map, prior_strategy)

        result =
          "## Investigation: #{topic}\n\n" <>
            "**Status: PARTIAL** -- Only the case AGAINST was analyzed (FOR advocate failed)\n" <>
            "**Cannot determine direction from one-sided analysis**\n\n" <>
            format_verified_evidence(verified_opposing, "Case Against") <>
            "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)

        timings =
          complete_phase_timings(timings, investigation_started_ms, post_processing_started_ms)

        json_metadata =
          partial_completion_metadata(
            topic,
            [],
            classified_opposing,
            all_papers,
            source_counts,
            prior_strategy,
            variant_id,
            timings,
            verification_stats
          )

        trace_payload =
          build_boundary_trace(trace_context, %{
            parsed_supporting: supporting,
            parsed_opposing: opposing,
            verified_supporting: [],
            verified_opposing: classified_opposing,
            timings: timings,
            verification_stats: verification_stats,
            final_metadata: json_metadata
          })

        result =
          result_with_completion_artifacts(
            result,
            maybe_capture_trace(json_metadata, caller_metadata, trace_payload),
            caller_metadata
          )

        log_phase_timings(topic, timings)
        log_verification_stats(topic, verification_stats)
        {:ok, result}

      opposing == [] ->
        # Only FOR succeeded — verify what we have
        {{verified_supporting, verification_stats}, citation_verification_ms} =
          timed(fn -> verify_citations(supporting, paper_map, prompts) end)

        timings = Map.put(timings, :citation_verification_ms, citation_verification_ms)
        post_processing_started_ms = monotonic_ms()

        classified_supporting =
          classify_evidence_store(verified_supporting, paper_map, prior_strategy)

        result =
          "## Investigation: #{topic}\n\n" <>
            "**Status: PARTIAL** -- Only the case FOR was analyzed (AGAINST advocate failed)\n" <>
            "**Cannot determine direction from one-sided analysis**\n\n" <>
            format_verified_evidence(verified_supporting, "Case For") <>
            "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)

        timings =
          complete_phase_timings(timings, investigation_started_ms, post_processing_started_ms)

        json_metadata =
          partial_completion_metadata(
            topic,
            classified_supporting,
            [],
            all_papers,
            source_counts,
            prior_strategy,
            variant_id,
            timings,
            verification_stats
          )

        trace_payload =
          build_boundary_trace(trace_context, %{
            parsed_supporting: supporting,
            parsed_opposing: opposing,
            verified_supporting: classified_supporting,
            verified_opposing: [],
            timings: timings,
            verification_stats: verification_stats,
            final_metadata: json_metadata
          })

        result =
          result_with_completion_artifacts(
            result,
            maybe_capture_trace(json_metadata, caller_metadata, trace_payload),
            caller_metadata
          )

        log_phase_timings(topic, timings)
        log_verification_stats(topic, verification_stats)
        {:ok, result}

      true ->
        # Both succeeded — full analysis with citation verification
        run_full_analysis(
          topic,
          supporting,
          opposing,
          all_papers,
          paper_map,
          source_counts,
          keywords,
          prior_evidence,
          store,
          depth,
          prior_strategy,
          prompts,
          variant_id,
          trace_context,
          caller_metadata,
          timings,
          investigation_started_ms
        )
    end
  rescue
    e ->
      Logger.error(
        "[investigate] Investigation failed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- Full analysis (both sides succeeded) ------------------------------

  defp run_full_analysis(
         topic,
         supporting_raw,
         opposing_raw,
         all_papers,
         paper_map,
         source_counts,
         keywords,
         prior_evidence,
         store,
         depth,
         strategy,
         prompts,
         variant_id,
         trace_context,
         caller_metadata,
         timings,
         investigation_started_ms
       ) do
    # 9. CITATION VERIFICATION + PAPER TYPE CLASSIFICATION — the evidence quality step
    overlap_stats = cross_side_overlap_stats(supporting_raw, opposing_raw, paper_map)

    {{{verified_supporting, supporting_verification_stats},
      {verified_opposing, opposing_verification_stats}},
     citation_verification_ms} =
      timed(fn ->
        verify_citation_pairs(supporting_raw, opposing_raw, paper_map, prompts)
      end)

    timings = Map.put(timings, :citation_verification_ms, citation_verification_ms)
    post_processing_started_ms = monotonic_ms()

    verification_stats =
      merge_verification_stats([
        supporting_verification_stats,
        opposing_verification_stats
      ])
      |> Map.merge(overlap_stats)

    # 9.7 Re-score evidence with winning strategy's hierarchy weights
    verified_supporting = rescore_evidence(verified_supporting, strategy)
    verified_opposing = rescore_evidence(verified_opposing, strategy)

    # 9a. AEC TWO-STORE CLASSIFICATION (arxiv.org/abs/2602.03974)
    # Split into grounded (high-quality, determines verdict) and belief (context only)
    # Uses strategy's grounded_threshold and citation/publisher weights
    classified_supporting = classify_evidence_store(verified_supporting, paper_map, strategy)
    classified_opposing = classify_evidence_store(verified_opposing, paper_map, strategy)

    grounded_for = Enum.filter(classified_supporting, &(&1.evidence_store == :grounded))
    grounded_against = Enum.filter(classified_opposing, &(&1.evidence_store == :grounded))

    grounded_for_count = length(grounded_for)
    grounded_against_count = length(grounded_against)
    belief_for_count = length(classified_supporting) - grounded_for_count
    belief_against_count = length(classified_opposing) - grounded_against_count

    # 10. Compute direction from GROUNDED evidence only (AEC commitment gating)
    # Uses strategy's direction_ratio and belief_fallback_ratio
    verified_for = Enum.count(classified_supporting, & &1.verified)
    verified_against = Enum.count(classified_opposing, & &1.verified)

    grounded_for_score = Enum.sum(Enum.map(grounded_for, & &1.score))
    grounded_against_score = Enum.sum(Enum.map(grounded_against, & &1.score))
    total_for_score = Enum.sum(Enum.map(classified_supporting, & &1.score))
    total_against_score = Enum.sum(Enum.map(classified_opposing, & &1.score))

    for_total = total_for_score
    against_total = total_against_score

    # Direction uses grounded scores first (AEC commitment gating).
    # When grounded store is empty, falls back to belief-store consensus
    # (prefixed with "belief_") to avoid always returning "insufficient".
    direction =
      cond do
        # Both stores have grounded evidence — use grounded scores
        grounded_for_score > 0 and grounded_against_score > 0 ->
          cond do
            grounded_for_score > grounded_against_score * strategy.direction_ratio -> "supporting"
            grounded_against_score > grounded_for_score * strategy.direction_ratio -> "opposing"
            true -> "genuinely_contested"
          end

        # Asymmetric grounded evidence
        grounded_against_score == 0 and grounded_for_score > 0 ->
          "asymmetric_evidence_for"

        grounded_for_score == 0 and grounded_against_score > 0 ->
          "asymmetric_evidence_against"

        # No grounded evidence at all — fall back to belief store
        # This prevents the system from being permanently stuck on "insufficient"
        # when source quality thresholds filter out all papers
        for_total == 0 and against_total == 0 ->
          "insufficient_evidence"

        against_total > for_total * strategy.belief_fallback_ratio ->
          "belief_consensus_against"

        for_total > against_total * strategy.belief_fallback_ratio ->
          "belief_consensus_for"

        true ->
          "belief_contested"
      end

    # Rebind for downstream compatibility (classified versions are supersets)
    verified_supporting = classified_supporting
    verified_opposing = classified_opposing

    # Count fraudulent citations
    fraudulent_count =
      Enum.count(
        verified_supporting ++ verified_opposing,
        fn ev -> ev.verification == "unverified" end
      )

    reasoning_for =
      Enum.count(
        verified_supporting,
        fn ev -> ev.verification == "no_citation" end
      )

    reasoning_against =
      Enum.count(
        verified_opposing,
        fn ev -> ev.verification == "no_citation" end
      )

    # Record prompt feedback for the GEPA flywheel
    sourced_evidence =
      Enum.filter(
        verified_supporting ++ verified_opposing,
        fn ev -> ev.source_type == :sourced end
      )

    total_sourced = length(sourced_evidence)
    count_verified = Enum.count(sourced_evidence, fn ev -> ev.verification == "verified" end)
    count_partial = Enum.count(sourced_evidence, fn ev -> ev.verification == "partial" end)

    count_unverified_sourced =
      Enum.count(sourced_evidence, fn ev -> ev.verification == "unverified" end)

    {_prompt_feedback_result, timings} =
      capture_timed(timings, :prompt_feedback_ms, fn ->
        try do
          prompt_hash = PromptConfig.prompt_hash(prompts)

          PromptFeedback.record(prompt_hash, topic, %{
            total_sourced: total_sourced,
            verified: count_verified,
            partial: count_partial,
            unverified: count_unverified_sourced,
            verification_rate:
              if(total_sourced > 0, do: count_verified / total_sourced, else: 0.0)
          })

          # Update Thompson Sampling posterior for the selected prompt variant
          PromptSelector.update(variant_id, count_verified, count_unverified_sourced)
        rescue
          e ->
            Logger.warning(
              "[investigate] Failed to record prompt feedback: #{Exception.message(e)}"
            )
        end
      end)

    # Count paper types across all evidence
    all_evidence = verified_supporting ++ verified_opposing
    review_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :review end)
    trial_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :trial end)
    study_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :study end)

    # 11. Create claim and add evidence to ledger
    {{claim, supporting_records, opposing_records, belief, uncertainty}, timings} =
      capture_timed(timings, :ledger_persistence_ms, fn ->
        claim =
          EpistemicLedger.add_claim(
            [
              title: String.slice(topic, 0, 100),
              statement: topic,
              tags: ["investigate", "auto", "adversarial"]
            ],
            @ledger_name
          )

        # Add FOR arguments as supporting evidence (using hierarchy-weighted score)
        supporting_records = add_evidence_to_ledger(verified_supporting, claim, :support)

        # Add AGAINST arguments as BOTH attacks AND contradicting evidence
        _contra_records = add_evidence_to_ledger(verified_opposing, claim, :contradict)
        opposing_records = add_attacks_to_ledger(verified_opposing, claim)

        # Refresh claim to recompute metrics
        EpistemicLedger.refresh_claim(claim.id, @ledger_name)

        # Get ledger metrics for supplementary display
        metrics = EpistemicLedger.claim_metrics(claim.id, @ledger_name)
        belief = metrics["belief"]
        uncertainty = metrics["uncertainty"]

        # 12. Persist ledger to disk
        EpistemicLedger.save(@ledger_name)

        {claim, supporting_records, opposing_records, belief, uncertainty}
      end)

    # 12b. Emergent question synthesis — extract novel research questions from evidence tension
    {emergent_questions, timings} =
      capture_timed(timings, :emergent_questions_ms, fn ->
        extract_emergent_questions(
          topic,
          direction,
          verified_supporting,
          verified_opposing,
          uncertainty
        )
      end)

    # 13. Store in knowledge graph
    topic_id = "investigate:" <> short_hash(topic)
    claim_id = claim.id

    {conflicts, timings} =
      capture_timed(timings, :knowledge_graph_ms, fn ->
        triples = [
          {topic_id, "rdf:type", "vaos:Investigation"},
          {topic_id, "vaos:topic", topic},
          {topic_id, "vaos:direction", direction},
          {topic_id, "vaos:verified_for", Integer.to_string(verified_for)},
          {topic_id, "vaos:verified_against", Integer.to_string(verified_against)},
          {topic_id, "vaos:fraudulent_citations", Integer.to_string(fraudulent_count)},
          {topic_id, "vaos:claim_id", claim_id},
          {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
        ]

        keyword_triples =
          Enum.map(keywords, fn kw ->
            {topic_id, "vaos:keyword", kw}
          end)

        for triple <- triples ++ keyword_triples do
          MiosaKnowledge.assert(store, triple)
        end

        # Store helpful/harmful counters for supporting evidence
        Enum.each(supporting_records, fn ev ->
          ev_id = "evidence:" <> ev.id
          MiosaKnowledge.assert(store, {topic_id, "vaos:has_evidence", ev_id})
          MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", "0"})
          MiosaKnowledge.assert(store, {ev_id, "vaos:harmful_count", "0"})
          MiosaKnowledge.assert(store, {ev_id, "vaos:summary", ev.summary})
        end)

        # Store attack records in knowledge graph
        Enum.each(opposing_records, fn atk ->
          atk_id = "attack:" <> atk.id
          MiosaKnowledge.assert(store, {topic_id, "vaos:has_attack", atk_id})
          MiosaKnowledge.assert(store, {atk_id, "vaos:helpful_count", "0"})
          MiosaKnowledge.assert(store, {atk_id, "vaos:harmful_count", "0"})
          MiosaKnowledge.assert(store, {atk_id, "vaos:summary", atk.description})
        end)

        # Increment helpful counters for prior evidence that was independently regenerated
        increment_helpful_for_reused_evidence(
          store,
          prior_evidence,
          verified_supporting ++ verified_opposing
        )

        # 13a. OWL Reasoner bridge — materialize inferred triples and check for contradictions
        try do
          case MiosaKnowledge.Reasoner.materialize(store) do
            {:ok, rounds} when rounds > 0 ->
              Logger.info(
                "[investigate] OWL reasoner ran #{rounds} fixpoint round(s), inferred new triples"
              )

              # Check if any inferred contradictions relate to our investigation
              case MiosaKnowledge.sparql(
                     store,
                     "SELECT ?s ?p ?o WHERE { ?s vaos:contradicts ?o }"
                   ) do
                {:ok, results} when is_list(results) and results != [] ->
                  for r <- results do
                    Logger.info(
                      "[investigate] OWL-visible contradiction: #{r["s"]} contradicts #{r["o"]}"
                    )
                  end

                _ ->
                  :ok
              end

            {:ok, 0} ->
              Logger.debug("[investigate] OWL reasoner: no new inferences")

            _ ->
              :ok
          end
        rescue
          e -> Logger.warning("[investigate] OWL reasoner failed: #{Exception.message(e)}")
        end

        # 14. Cross-investigation contradiction detection
        detect_contradictions(store, topic_id, direction, keywords)
      end)

    conflict_note =
      if conflicts == [] do
        ""
      else
        conflict_lines =
          Enum.map(conflicts, fn c ->
            "  - #{c.prior_topic} (#{c.prior_id}): #{c.prior_direction} vs current #{direction}"
          end)

        "\n### Cross-Investigation Conflicts\n" <> Enum.join(conflict_lines, "\n") <> "\n"
      end

    # 15. Assess advocacy quality (flag unreliable advocates)
    quality_note = assess_advocacy_quality(verified_supporting, verified_opposing)

    # 15a. Check uncertainty and suggest iteration
    iteration_note = maybe_suggest_iteration(claim, @ledger_name)

    # 15b. Deep mode: run research pipeline if requested
    {deep_note, timings} =
      capture_timed(timings, :deep_research_ms, fn ->
        if depth == "deep" do
          deep_research_note(topic, claim, all_papers, store)
        else
          ""
        end
      end)

    # 16. Format result with verification status and evidence quality
    for_arguments =
      format_verified_evidence(
        verified_supporting,
        "Case For (grounded: #{Float.round(grounded_for_score * 1.0, 2)}, total: #{Float.round(for_total * 1.0, 2)})"
      )

    against_arguments =
      format_verified_evidence(
        verified_opposing,
        "Case Against (grounded: #{Float.round(grounded_against_score * 1.0, 2)}, total: #{Float.round(against_total * 1.0, 2)})"
      )

    paper_list = format_paper_list(all_papers)

    result =
      "## Investigation: #{topic}\n\n" <>
        "**Direction: #{direction}** (AEC grounded-only verdict)\n" <>
        "**Grounded score: #{Float.round(grounded_for_score * 1.0, 2)} for vs #{Float.round(grounded_against_score * 1.0, 2)} against**\n" <>
        "**Total score (incl. belief): #{Float.round(for_total * 1.0, 2)} for vs #{Float.round(against_total * 1.0, 2)} against**\n" <>
        "**Evidence stores: #{grounded_for_count + grounded_against_count} grounded, #{belief_for_count + belief_against_count} belief**\n" <>
        "**Verified citations for: #{verified_for} | Verified citations against: #{verified_against}**\n" <>
        "**Fraudulent citations detected: #{fraudulent_count}**\n" <>
        "**Evidence quality: #{review_count} reviews, #{trial_count} trials, #{study_count} studies**\n" <>
        "**Ledger belief: #{Float.round(belief * 1.0, 3)}, uncertainty: #{Float.round(uncertainty * 1.0, 3)}**\n" <>
        "**Papers found:** #{length(all_papers)} (#{format_source_counts(source_counts)})\n\n" <>
        if(quality_note != "", do: quality_note <> "\n\n", else: "") <>
        "### #{for_arguments}\n\n" <>
        "### #{against_arguments}\n\n" <>
        "### Papers Consulted\n#{paper_list}\n" <>
        conflict_note <>
        if(prior_evidence != [],
          do:
            "\n### Prior Evidence (related topics)\n" <> Enum.join(prior_evidence, "\n") <> "\n",
          else: ""
        ) <>
        deep_note <>
        iteration_note <>
        "\n### Keywords\n  " <>
        Enum.join(keywords, ", ") <>
        "\n\n" <>
        "*Claim ID: #{claim_id} -- stored in knowledge graph as #{topic_id}*"

    # 16. Policy — suggest next investigations based on information gain
    {next_actions_text, timings} =
      capture_timed(timings, :policy_ranking_ms, fn ->
        try do
          next_actions = Policy.rank_actions(Process.whereis(@ledger_name), limit: 5)

          if next_actions != [] do
            suggestions =
              next_actions
              |> Enum.with_index(1)
              |> Enum.map(fn {action, i} ->
                gain_str = Float.round(action.expected_information_gain, 2) |> to_string()

                "  #{i}. #{action.action_type}: \"#{action.claim_title}\" (gain: #{gain_str}) — #{action.reason}"
              end)
              |> Enum.join("
")

            "

### Suggested Next Investigations
" <>
              "Based on where uncertainty is highest in the knowledge graph:
" <> suggestions
          else
            ""
          end
        rescue
          e ->
            Logger.warning("[investigate] Policy.rank_actions failed: #{Exception.message(e)}")
            ""
        end
      end)

    timings =
      complete_phase_timings(timings, investigation_started_ms, post_processing_started_ms)

    metadata_timings = timing_metadata(timings)

    json_metadata = %{
      topic: topic,
      claim_id: claim_id,
      direction: direction,
      strategy_hash: Strategy.param_hash(strategy),
      verified_for: verified_for,
      verified_against: verified_against,
      reasoning_for: reasoning_for,
      reasoning_against: reasoning_against,
      for_score: Float.round(for_total * 1.0, 3),
      against_score: Float.round(against_total * 1.0, 3),
      grounded_for_score: Float.round(grounded_for_score * 1.0, 3),
      grounded_against_score: Float.round(grounded_against_score * 1.0, 3),
      grounded_for_count: grounded_for_count,
      grounded_against_count: grounded_against_count,
      belief_for_count: belief_for_count,
      belief_against_count: belief_against_count,
      aec_methodology: "arxiv.org/abs/2602.03974",
      fraudulent_citations: fraudulent_count,
      belief: Float.round(belief * 1.0, 3),
      uncertainty: Float.round(uncertainty * 1.0, 3),
      duration_ms: metadata_timings.duration_ms,
      phase_timings_ms: metadata_timings.phase_timings_ms,
      verification_stats: verification_stats,
      evidence_quality: %{
        reviews: review_count,
        trials: trial_count,
        studies: study_count
      },
      supporting:
        Enum.map(verified_supporting, fn ev ->
          %{
            summary: ev.summary,
            score: ev.score,
            verified: ev.verified,
            verification: ev.verification,
            paper_type: Atom.to_string(ev.paper_type),
            citation_count: ev.citation_count,
            strength_display: ev.strength,
            source_quality: Map.get(ev, :source_quality, 0),
            source_type: ev.source_type,
            evidence_store: Atom.to_string(Map.get(ev, :evidence_store, :unknown))
          }
        end),
      opposing:
        Enum.map(verified_opposing, fn ev ->
          %{
            summary: ev.summary,
            score: ev.score,
            verified: ev.verified,
            verification: ev.verification,
            paper_type: Atom.to_string(ev.paper_type),
            citation_count: ev.citation_count,
            strength_display: ev.strength,
            source_quality: Map.get(ev, :source_quality, 0),
            source_type: ev.source_type,
            evidence_store: Atom.to_string(Map.get(ev, :evidence_store, :unknown))
          }
        end),
      papers_found: length(all_papers),
      source_counts: source_counts,
      papers_detail:
        Enum.map(all_papers, fn p ->
          %{
            title: p["title"],
            year: p["year"],
            citations: p["citation_count"] || p["citationCount"] || 0,
            source: p["source"] || "unknown",
            abstract: String.slice(to_string(p["abstract"] || ""), 0, 500)
          }
        end),
      investigation_id: topic_id,
      optimization: nil,
      suggested_next:
        try do
          Policy.rank_actions(@ledger_name, limit: 3)
          |> Enum.map(fn a ->
            %{
              action_type: a.action_type,
              claim_title: a.claim_title,
              information_gain: a.expected_information_gain,
              claim_id: a.claim_id,
              reason: a.reason
            }
          end)
        rescue
          _ -> []
        end,
      emergent_questions: emergent_questions,
      variant_id: variant_id
    }

    trace_payload =
      build_boundary_trace(trace_context, %{
        parsed_supporting: supporting_raw,
        parsed_opposing: opposing_raw,
        verified_supporting: verified_supporting,
        verified_opposing: verified_opposing,
        timings: timings,
        verification_stats: verification_stats,
        final_metadata: json_metadata
      })

    json_metadata = maybe_capture_trace(json_metadata, caller_metadata, trace_payload)

    json_result = emit_successful_investigation(json_metadata, caller_metadata, store: store)

    result = result <> next_actions_text <> "\n\n<!-- VAOS_JSON:#{json_result} -->"
    log_phase_timings(topic, timings)
    log_verification_stats(topic, verification_stats)

    {:ok, result}
  end

  @doc false
  def timing_metadata(timings) when is_map(timings) do
    %{
      duration_ms: Map.get(timings, :total_ms, 0),
      phase_timings_ms: timings
    }
  end

  defp grounded_evidence?(ev) do
    case Map.get(ev, :evidence_store) do
      :grounded -> true
      "grounded" -> true
      _ -> false
    end
  end

  @doc false
  def partial_completion_metadata(
        topic,
        verified_supporting,
        verified_opposing,
        all_papers,
        source_counts,
        %Strategy{} = strategy,
        variant_id,
        timings,
        verification_stats
      ) do
    metadata_timings = timing_metadata(timings)
    grounded_for = Enum.filter(verified_supporting, &grounded_evidence?/1)
    grounded_against = Enum.filter(verified_opposing, &grounded_evidence?/1)
    all_evidence = verified_supporting ++ verified_opposing
    for_total = Enum.sum(Enum.map(verified_supporting, &Map.get(&1, :score, 0.0)))
    against_total = Enum.sum(Enum.map(verified_opposing, &Map.get(&1, :score, 0.0)))
    grounded_for_score = Enum.sum(Enum.map(grounded_for, &Map.get(&1, :score, 0.0)))
    grounded_against_score = Enum.sum(Enum.map(grounded_against, &Map.get(&1, :score, 0.0)))

    direction =
      cond do
        verified_supporting != [] and verified_opposing == [] -> "partial_supporting_only"
        verified_opposing != [] and verified_supporting == [] -> "partial_opposing_only"
        true -> "partial"
      end

    %{
      topic: topic,
      claim_id: nil,
      direction: direction,
      strategy_hash: Strategy.param_hash(strategy),
      verified_for: Enum.count(verified_supporting, &Map.get(&1, :verified, false)),
      verified_against: Enum.count(verified_opposing, &Map.get(&1, :verified, false)),
      reasoning_for: Enum.count(verified_supporting, &(&1.verification == "no_citation")),
      reasoning_against: Enum.count(verified_opposing, &(&1.verification == "no_citation")),
      for_score: Float.round(for_total * 1.0, 3),
      against_score: Float.round(against_total * 1.0, 3),
      grounded_for_score: Float.round(grounded_for_score * 1.0, 3),
      grounded_against_score: Float.round(grounded_against_score * 1.0, 3),
      grounded_for_count: length(grounded_for),
      grounded_against_count: length(grounded_against),
      belief_for_count: length(verified_supporting) - length(grounded_for),
      belief_against_count: length(verified_opposing) - length(grounded_against),
      aec_methodology: "arxiv.org/abs/2602.03974",
      fraudulent_citations: Enum.count(all_evidence, &(&1.verification == "unverified")),
      belief: nil,
      uncertainty: 1.0,
      duration_ms: metadata_timings.duration_ms,
      phase_timings_ms: metadata_timings.phase_timings_ms,
      verification_stats: verification_stats,
      evidence_quality: %{
        reviews: Enum.count(all_evidence, &(&1.paper_type == :review)),
        trials: Enum.count(all_evidence, &(&1.paper_type == :trial)),
        studies: Enum.count(all_evidence, &(&1.paper_type == :study))
      },
      supporting: evidence_metadata(verified_supporting),
      opposing: evidence_metadata(verified_opposing),
      papers_found: length(all_papers),
      source_counts: source_counts,
      papers_detail: paper_details(all_papers),
      investigation_id: "investigate:" <> short_hash(topic),
      optimization: nil,
      suggested_next: [],
      emergent_questions: [],
      variant_id: variant_id,
      partial: true
    }
  end

  @doc false
  def merge_verification_stats(stats_list) when is_list(stats_list) do
    base = %{
      total_items: 0,
      llm_items: 0,
      no_llm_items: 0,
      unique_llm_items: 0,
      deduped_llm_items: 0,
      cache_hits: 0,
      cache_misses: 0,
      cache_lookup_ms: 0,
      llm_ms_total: 0,
      average_llm_ms: 0,
      slowest_llm_ms: 0,
      model: nil
    }

    models =
      stats_list
      |> Enum.map(&Map.get(&1, :model))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    merged =
      Enum.reduce(stats_list, base, fn stats, acc ->
        %{
          acc
          | total_items: acc.total_items + Map.get(stats, :total_items, 0),
            llm_items: acc.llm_items + Map.get(stats, :llm_items, 0),
            no_llm_items: acc.no_llm_items + Map.get(stats, :no_llm_items, 0),
            unique_llm_items: acc.unique_llm_items + Map.get(stats, :unique_llm_items, 0),
            deduped_llm_items: acc.deduped_llm_items + Map.get(stats, :deduped_llm_items, 0),
            cache_hits: acc.cache_hits + Map.get(stats, :cache_hits, 0),
            cache_misses: acc.cache_misses + Map.get(stats, :cache_misses, 0),
            cache_lookup_ms: acc.cache_lookup_ms + Map.get(stats, :cache_lookup_ms, 0),
            llm_ms_total: acc.llm_ms_total + Map.get(stats, :llm_ms_total, 0),
            slowest_llm_ms: max(acc.slowest_llm_ms, Map.get(stats, :slowest_llm_ms, 0))
        }
      end)

    model =
      case models do
        [single] -> single
        [] -> nil
        list -> Enum.join(list, ",")
      end

    merged
    |> Map.put(:model, model)
    |> finalize_verification_stats()
  end

  @doc false
  def cross_side_overlap_stats(supporting_raw, opposing_raw, paper_map)
      when is_list(supporting_raw) and is_list(opposing_raw) and is_map(paper_map) do
    supporting_pairs = overlap_pair_lookup(supporting_raw, paper_map)
    opposing_pairs = overlap_pair_lookup(opposing_raw, paper_map)

    shared_keys =
      MapSet.intersection(
        MapSet.new(Map.keys(supporting_pairs)),
        MapSet.new(Map.keys(opposing_pairs))
      )

    supporting_unique = map_size(supporting_pairs)
    opposing_unique = map_size(opposing_pairs)
    shared_count = MapSet.size(shared_keys)
    union_count = supporting_unique + opposing_unique - shared_count

    overlap_examples =
      shared_keys
      |> Enum.map(&Map.fetch!(supporting_pairs, &1))
      |> Enum.sort_by(fn %{paper_ref: paper_ref, claim: claim} -> {paper_ref || 0, claim} end)
      |> Enum.take(3)

    %{
      supporting_unique_llm_items: supporting_unique,
      opposing_unique_llm_items: opposing_unique,
      cross_side_unique_llm_items: union_count,
      cross_side_overlap_items: shared_count,
      cross_side_overlap_rate: ratio(shared_count, union_count),
      supporting_overlap_rate: ratio(shared_count, supporting_unique),
      opposing_overlap_rate: ratio(shared_count, opposing_unique),
      cross_side_overlap_examples: overlap_examples
    }
  end

  defp timed(fun) when is_function(fun, 0) do
    started_ms = monotonic_ms()
    {fun.(), elapsed_ms(started_ms)}
  end

  defp capture_timed(timings, key, fun)
       when is_map(timings) and is_atom(key) and is_function(fun, 0) do
    {result, elapsed} = timed(fun)
    {result, Map.put(timings, key, elapsed)}
  end

  defp complete_phase_timings(
         timings,
         investigation_started_ms,
         post_processing_started_ms \\ nil
       ) do
    timings =
      if is_integer(post_processing_started_ms) do
        Map.put(timings, :post_processing_ms, elapsed_ms(post_processing_started_ms))
      else
        timings
      end

    Map.put(timings, :total_ms, elapsed_ms(investigation_started_ms))
  end

  defp log_phase_timings(topic, timings) do
    Logger.info(
      "[investigate] Timings topic=#{String.slice(topic, 0, 80)} " <>
        "preflight=#{Map.get(timings, :preflight_ms, 0)}ms " <>
        "search=#{Map.get(timings, :paper_search_ms, 0)}ms " <>
        "for_llm=#{Map.get(timings, :for_llm_ms, 0)}ms " <>
        "against_llm=#{Map.get(timings, :against_llm_ms, 0)}ms " <>
        "verify=#{Map.get(timings, :citation_verification_ms, 0)}ms " <>
        "feedback=#{Map.get(timings, :prompt_feedback_ms, 0)}ms " <>
        "ledger=#{Map.get(timings, :ledger_persistence_ms, 0)}ms " <>
        "questions=#{Map.get(timings, :emergent_questions_ms, 0)}ms " <>
        "kg=#{Map.get(timings, :knowledge_graph_ms, 0)}ms " <>
        "deep=#{Map.get(timings, :deep_research_ms, 0)}ms " <>
        "policy=#{Map.get(timings, :policy_ranking_ms, 0)}ms " <>
        "post=#{Map.get(timings, :post_processing_ms, 0)}ms " <>
        "total=#{Map.get(timings, :total_ms, 0)}ms"
    )
  end

  defp log_verification_stats(topic, stats) do
    Logger.info(
      "[investigate] Verification topic=#{String.slice(topic, 0, 80)} " <>
        "model=#{Map.get(stats, :model, "unknown")} " <>
        "items=#{Map.get(stats, :total_items, 0)} " <>
        "llm=#{Map.get(stats, :llm_items, 0)} " <>
        "unique=#{Map.get(stats, :unique_llm_items, 0)} " <>
        "deduped=#{Map.get(stats, :deduped_llm_items, 0)} " <>
        "hits=#{Map.get(stats, :cache_hits, 0)} " <>
        "misses=#{Map.get(stats, :cache_misses, 0)} " <>
        "cross_overlap=#{Map.get(stats, :cross_side_overlap_items, 0)}/#{Map.get(stats, :cross_side_unique_llm_items, 0)} " <>
        "cross_rate=#{format_pct(Map.get(stats, :cross_side_overlap_rate, 0.0))} " <>
        "for_overlap=#{format_pct(Map.get(stats, :supporting_overlap_rate, 0.0))} " <>
        "against_overlap=#{format_pct(Map.get(stats, :opposing_overlap_rate, 0.0))} " <>
        "llm_total=#{Map.get(stats, :llm_ms_total, 0)}ms " <>
        "avg_llm=#{Map.get(stats, :average_llm_ms, 0)}ms " <>
        "slowest_llm=#{Map.get(stats, :slowest_llm_ms, 0)}ms"
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started_ms), do: max(monotonic_ms() - started_ms, 0)

  # -- Citation Verification + Paper Type Classification ------------------

  defp verify_citations(evidence_list, paper_map, prompts) do
    # Split into items that need LLM verification and those that don't
    {need_llm, no_llm} =
      Enum.split_with(evidence_list, fn ev ->
        case extract_paper_ref(ev.summary) do
          nil -> false
          n -> Map.has_key?(paper_map, n)
        end
      end)

    # Handle non-LLM items immediately
    no_llm_verified =
      Enum.map(no_llm, fn ev ->
        case extract_paper_ref(ev.summary) do
          nil ->
            build_verified_evidence(ev, :no_citation, :reasoning, 0)

          _n ->
            build_verified_evidence(ev, :invalid_ref, :other, 0)
        end
      end)

    verification_inputs =
      Enum.map(need_llm, fn ev ->
        paper_num = extract_paper_ref(ev.summary)
        paper = Map.fetch!(paper_map, paper_num)

        %{
          key: verification_key(ev),
          evidence: ev,
          paper: paper,
          citation_count: paper["citation_count"] || paper["citationCount"] || 0
        }
      end)

    unique_inputs = Enum.uniq_by(verification_inputs, & &1.key)

    verification_stats = %{
      total_items: length(evidence_list),
      llm_items: length(need_llm),
      no_llm_items: length(no_llm),
      unique_llm_items: length(unique_inputs),
      deduped_llm_items: length(verification_inputs) - length(unique_inputs),
      cache_hits: 0,
      cache_misses: 0,
      cache_lookup_ms: 0,
      llm_ms_total: 0,
      average_llm_ms: 0,
      slowest_llm_ms: 0,
      model: preferred_verification_model()
    }

    # Run LLM verification sequentially — even with a faster utility-tier model,
    # OpenAI-compatible providers can rate limit aggressively under concurrency.
    {llm_lookup, verification_stats} =
      Enum.reduce(unique_inputs, {%{}, verification_stats}, fn input, {lookup, stats} ->
        {{cache_status, {verification, paper_type}}, duration_ms} =
          timed(fn -> cached_verify(input.evidence, input.paper, prompts) end)

        stats = update_verification_stats(stats, cache_status, duration_ms)

        verified_evidence =
          build_verified_evidence(
            input.evidence,
            verification,
            paper_type,
            input.citation_count
          )

        {Map.put(lookup, input.key, verified_evidence), stats}
      end)

    # Recombine in original order by matching on summary
    verified_lookup =
      Map.merge(
        Map.new(no_llm_verified, fn ev -> {verification_key(ev), ev} end),
        llm_lookup
      )

    verified =
      Enum.map(evidence_list, fn ev ->
        Map.get(verified_lookup, verification_key(ev), ev)
      end)

    {verified, finalize_verification_stats(verification_stats)}
  end

  defp extract_paper_ref(summary) do
    [~r/\[Paper (\d+)\]/i, ~r/\bPaper (\d+)\b/i]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, summary) do
        [_, num] -> String.to_integer(num)
        _ -> nil
      end
    end)
  end

  defp verify_single_citation(evidence, paper, prompts) do
    abstract = Map.get(paper, "abstract", "") || ""
    title = Map.get(paper, "title", "") || ""
    claim = verification_claim_text(evidence.summary)

    prompt =
      case prompts["verify_prompt"] do
        template when is_binary(template) ->
          PromptConfig.render(template,
            paper_title: title,
            paper_abstract: String.slice(to_string(abstract), 0, 2000),
            claim: claim
          )

        _ ->
          # Fallback to inline (should not happen with proper config)
          """
          Return ONLY the classification on the first line using exactly two uppercase words.
          First word: VERIFIED / PARTIAL / UNVERIFIED
          Second word: REVIEW / TRIAL / STUDY / OTHER
          Do not write analysis before the first line. If needed, explanation may follow after it.

          Paper title: #{title}
          Paper abstract: #{String.slice(to_string(abstract), 0, 2000)}

          Claim: #{claim}

          Example first line: VERIFIED STUDY
          """
      end

    messages = [
      %{role: "system", content: verification_system_prompt()},
      %{role: "user", content: prompt}
    ]

    model = preferred_verification_model()
    verify_opts = verification_request_opts(model)

    case Providers.chat(messages, verify_opts) do
      {:ok, %{content: response}} when is_binary(response) and response != "" ->
        parse_verification_response(response)

      {:ok, %{content: ""}} ->
        Logger.warning(
          "[investigate] verify_citation: empty content (reasoning model token exhaustion)"
        )

        {:unverified, :other}

      {:error, reason} ->
        Logger.warning("[investigate] verify_citation failed: #{inspect(reason)}")
        {:unverified, :other}

      other ->
        Logger.warning(
          "[investigate] verify_citation unexpected: #{inspect(other) |> String.slice(0, 200)}"
        )

        {:unverified, :other}
    end
  end

  defp build_verified_evidence(ev, verification, paper_type, citation_count) do
    verification_atom =
      case verification do
        value when value in [:verified, :partial, :unverified] -> value
        :no_citation -> :unverified
        :invalid_ref -> :unverified
        _ -> :unverified
      end

    score =
      case verification do
        :no_citation -> 0.15
        :invalid_ref -> 0.0
        _ -> compute_evidence_score(verification_atom, paper_type, citation_count)
      end

    verified = verification_atom in [:verified, :partial]

    %{
      ev
      | verified: verified,
        verification: Atom.to_string(verification),
        paper_type: paper_type,
        citation_count: citation_count,
        score: score
    }
  end

  defp verification_key(ev), do: {extract_paper_ref(ev.summary), ev.summary}

  defp overlap_pair_lookup(evidence_list, paper_map) do
    Enum.reduce(evidence_list, %{}, fn evidence, acc ->
      case overlap_pair_entry(evidence, paper_map) do
        nil -> acc
        entry -> Map.put(acc, {entry.claim, entry.paper_title}, entry)
      end
    end)
  end

  defp overlap_pair_entry(evidence, paper_map) do
    summary = map_value(evidence, :summary)

    with summary when is_binary(summary) <- summary,
         paper_ref when not is_nil(paper_ref) <- extract_paper_ref(summary),
         %{} = paper <- Map.get(paper_map, paper_ref),
         claim when is_binary(claim) <- verification_claim_text(summary),
         false <- claim == "" do
      %{
        paper_ref: paper_ref,
        paper_title: to_string(Map.get(paper, "title", "")),
        claim: claim
      }
    else
      _ -> nil
    end
  end

  defp update_verification_stats(stats, :hit, duration_ms) do
    %{
      stats
      | cache_hits: stats.cache_hits + 1,
        cache_lookup_ms: stats.cache_lookup_ms + duration_ms
    }
  end

  defp update_verification_stats(stats, :miss, duration_ms) do
    %{
      stats
      | cache_misses: stats.cache_misses + 1,
        llm_ms_total: stats.llm_ms_total + duration_ms,
        slowest_llm_ms: max(stats.slowest_llm_ms, duration_ms)
    }
  end

  defp finalize_verification_stats(stats) do
    average_llm_ms =
      if stats.cache_misses > 0 do
        round(stats.llm_ms_total / stats.cache_misses)
      else
        0
      end

    Map.put(stats, :average_llm_ms, average_llm_ms)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 3)

  defp format_pct(value) when is_number(value) do
    "#{Float.round(value * 100.0, 1)}%"
  end

  # -- Evidence hierarchy scoring -----------------------------------------

  defp compute_evidence_score(verification, paper_type, citation_count) do
    compute_evidence_score(verification, paper_type, citation_count, Strategy.default())
  end

  defp compute_evidence_score(verification, paper_type, citation_count, %Strategy{} = strategy) do
    # Base score from verification
    base =
      case verification do
        :verified -> 1.0
        :partial -> 0.5
        :unverified -> 0.0
      end

    # Evidence hierarchy weight (from strategy)
    type_weight =
      case paper_type do
        :review -> strategy.review_weight
        :trial -> strategy.trial_weight
        :study -> strategy.study_weight
        _ -> 1.0
      end

    # Citation count bonus (log scale, base from strategy)
    citation_bonus = :math.log10(max(citation_count, strategy.citation_bonus_base))

    # Final score
    base * type_weight * citation_bonus
  end

  # -- AEC Two-Store: Verification-Aware Classification (VAC) ----------------
  # Per arxiv.org/abs/2602.03974 — Active Epistemic Control
  # Only grounded (high-quality) evidence can determine the verdict.
  # Belief (low-quality) evidence provides context but cannot flip direction.
  # Classification uses BOTH LLM verification status AND source quality via
  # SourceScoring.classify/3 — unverified evidence never enters grounded.

  defp classify_evidence_store(verified_evidence, paper_map, %Strategy{} = strategy) do
    Enum.map(verified_evidence, fn ev ->
      source_quality =
        case ev.paper_ref do
          nil ->
            0.15

          n ->
            case Map.get(paper_map, n) do
              nil -> 0.1
              paper -> SourceScoring.score(paper, strategy)
            end
        end

      store = SourceScoring.classify(ev.verification, source_quality, strategy)
      Map.merge(ev, %{source_quality: source_quality, evidence_store: store})
    end)
  end

  # -- Format papers for LLM context -----------------------------------

  # -- Re-score evidence with optimized strategy params ------------------

  defp rescore_evidence(evidence, %Strategy{} = strategy) do
    Enum.map(evidence, fn ev ->
      verification_atom =
        case ev.verification do
          "verified" -> :verified
          "partial" -> :partial
          _ -> :unverified
        end

      new_score =
        compute_evidence_score(verification_atom, ev.paper_type, ev.citation_count, strategy)

      %{ev | score: new_score}
    end)
  end

  defp format_papers([], prompts) do
    prompts["no_papers_fallback"] ||
      "No relevant papers found. Base your arguments on your training knowledge, but mark everything as [REASONING]."
  end

  defp format_papers(papers, prompts) do
    papers_text =
      papers
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        citations = p["citation_count"] || p["citationCount"] || 0
        source = p["source"] || "unknown"
        abstract = String.slice(to_string(p["abstract"] || ""), 0, 2000)

        "[Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})\nAbstract: #{abstract}"
      end)
      |> Enum.join("\n\n")

    citation_instructions =
      prompts["citation_instructions"] ||
        "\n\nPapers are sorted by relevance. Citation counts are shown for each paper." <>
          "\nWhen citing papers, only claim what the abstract actually states. Do NOT infer findings beyond what is written." <>
          "\nIf a paper's abstract doesn't explicitly support your claim, use [REASONING] instead of citing it." <>
          "\nYou MUST cite specific papers by number [Paper N] when your arguments are based on them."

    "RELEVANT PAPERS FOUND:\n" <> papers_text <> citation_instructions
  end

  # -- Adversarial evidence parsing ------------------------------------

  defp parse_adversarial_evidence(text), do: AdversarialParser.parse(text)

  # -- Add evidence to ledger ------------------------------------------

  defp add_evidence_to_ledger(evidence_list, claim, direction) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_strength = ev.score

      case EpistemicLedger.add_evidence(
             [
               claim_id: claim.id,
               summary: ev.summary,
               direction: direction,
               strength: ledger_strength,
               confidence: ledger_strength,
               source_type: Atom.to_string(ev.source_type)
             ],
             @ledger_name
           ) do
        %Models.Evidence{} = record ->
          [record]

        {:error, reason} ->
          Logger.warning("[investigate] Failed to add evidence: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Add attacks to ledger (AGAINST arguments = falsification attempts) --

  defp add_attacks_to_ledger(evidence_list, claim) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_severity = ev.score
      source = if ev.source_type == :sourced, do: "paper", else: "llm_reasoning"

      case EpistemicLedger.add_attack(
             [
               claim_id: claim.id,
               description: ev.summary,
               target_kind: "claim",
               target_id: claim.id,
               severity: ledger_severity,
               status: :open,
               metadata: %{
                 "source" => source,
                 "source_type" => Atom.to_string(ev.source_type),
                 "raw_strength" => ev.strength,
                 "verified" => ev.verified,
                 "verification" => ev.verification,
                 "paper_type" => Atom.to_string(ev.paper_type),
                 "citation_count" => ev.citation_count,
                 "score" => ev.score
               }
             ],
             @ledger_name
           ) do
        %Models.Attack{} = record ->
          [record]

        {:error, reason} ->
          Logger.warning("[investigate] Failed to add attack: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Format verified evidence for display -----------------------------

  defp format_verified_evidence([], _heading), do: "(none)"

  defp format_verified_evidence(evidence, heading) do
    lines =
      evidence
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        type_tag = ev.paper_type |> Atom.to_string() |> String.upcase()
        cite_count = ev.citation_count
        score_str = Float.round(ev.score * 1.0, 1) |> to_string()

        store_label =
          case Map.get(ev, :evidence_store) do
            :grounded -> "GROUNDED"
            :belief -> "BELIEF"
            _ -> ""
          end

        {status_icon, detail} =
          case ev.verification do
            "verified" ->
              paper_info =
                case ev.paper_ref do
                  nil -> ""
                  n -> "Paper #{n}, "
                end

              cite_str = format_citation_count(cite_count)
              {"VERIFIED \u2713 #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}

            "partial" ->
              paper_info =
                case ev.paper_ref do
                  nil -> ""
                  n -> "Paper #{n}, "
                end

              cite_str = format_citation_count(cite_count)
              {"PARTIAL ~ #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}

            "unverified" ->
              paper_info =
                case ev.paper_ref do
                  nil -> ""
                  n -> "Paper #{n}, "
                end

              cite_str = format_citation_count(cite_count)

              {"UNVERIFIED \u2717",
               "(#{paper_info}#{cite_str}, score: #{score_str}) -- FRAUDULENT CITATION"}

            "no_citation" ->
              {"NO CITATION", "(reasoning only, score: #{score_str})"}

            "invalid_ref" ->
              {"INVALID REF", "(score: 0.0 -- cited paper doesn't exist)"}

            _ ->
              {"PENDING", "(score: #{score_str})"}
          end

        store_tag = if store_label != "", do: " [#{store_label}]", else: ""
        "  #{i}. [#{status_icon}]#{store_tag} #{detail} #{ev.summary}"
      end)
      |> Enum.join("\n")

    "#{heading}\n#{lines}"
  end

  defp format_citation_count(count) when count >= 1000 do
    "#{Float.round(count / 1000.0, 1)}k citations"
  end

  defp format_citation_count(count), do: "#{count} citations"

  # -- Code execution callback (Crucible or local fallback) ----------------

  defp build_code_fn do
    crucible_url = System.get_env("VAOS_CRUCIBLE_GRPC_URL")

    if crucible_url do
      # Production: use vas-crucible sandbox via HTTP proxy
      fn code, opts ->
        language = Keyword.get(opts, :language, "python")
        kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"

        # Get JWT for sandbox auth
        agent_id = "osa"

        intent_hash =
          :crypto.hash(:sha256, code) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        jwt =
          case Daemon.Kernel.Client.request_token(agent_id, intent_hash, "execute") do
            {:ok, token} -> token
            _ -> nil
          end

        if jwt do
          body = Jason.encode!(%{code: code, language: language, jwt: jwt})

          case Req.post("#{crucible_url}/execute",
                 body: body,
                 headers: [{"content-type", "application/json"}],
                 receive_timeout: 30_000
               ) do
            {:ok, %{status: 200, body: resp}} ->
              {:ok, %{stdout: resp["stdout"] || "", stderr: resp["stderr"] || ""}}

            {:ok, %{status: status, body: body}} ->
              {:error, "Crucible returned #{status}: #{inspect(body)}"}

            {:error, reason} ->
              {:error, "Crucible unreachable: #{inspect(reason)}"}
          end
        else
          {:error, "No JWT available for sandbox auth"}
        end
      end
    else
      # Local fallback: run Python in a restricted tmpdir (dev mode only)
      fn code, opts ->
        language = Keyword.get(opts, :language, "python")

        if language != "python" do
          {:error, "Local fallback only supports Python"}
        else
          work_dir = System.tmp_dir!() |> Path.join("crucible_#{:rand.uniform(999_999)}")
          File.mkdir_p!(work_dir)
          script_path = Path.join(work_dir, "script.py")
          File.write!(script_path, code)

          try do
            {output, exit_code} =
              System.cmd("python3", [script_path],
                cd: work_dir,
                stderr_to_stdout: true,
                env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
              )

            if exit_code == 0 do
              {:ok, %{stdout: output, stderr: ""}}
            else
              {:ok, %{stdout: "", stderr: output}}
            end
          rescue
            e -> {:error, "Local exec failed: #{Exception.message(e)}"}
          after
            File.rm_rf!(work_dir)
          end
        end
      end
    end
  end

  # -- Format paper list for display -----------------------------------

  defp format_paper_list(all_papers) do
    all_papers
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} ->
      citations = p["citation_count"] || p["citationCount"] || 0
      source = p["source"] || "unknown"

      doi_suffix =
        case p["doi"] do
          doi when is_binary(doi) and doi != "" -> " | https://doi.org/#{doi}"
          _ -> ""
        end

      "  [Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})#{doi_suffix}"
    end)
    |> Enum.join("\n")
  end

  # -- Helpful counter increment (compound loop) -----------------------

  defp increment_helpful_for_reused_evidence(store, prior_evidence_texts, current_evidence) do
    # Only increment helpful counter when prior evidence is independently regenerated
    Enum.each(prior_evidence_texts, fn prior_text ->
      # Check if any current evidence covers the same ground
      was_reused =
        Enum.any?(current_evidence, fn ev ->
          prior_words = significant_words(prior_text)
          ev_words = significant_words(ev.summary)
          set1 = MapSet.new(prior_words)
          set2 = MapSet.new(ev_words)
          intersection = MapSet.intersection(set1, set2) |> MapSet.size()
          union_size = MapSet.union(set1, set2) |> MapSet.size()
          union_size > 0 and intersection * 1.0 / union_size >= 0.3
        end)

      if was_reused do
        case Regex.run(~r/\(id:\s*(investigate:[a-f0-9]+)\)/, prior_text) do
          [_, prior_id] ->
            query =
              "SELECT ?ev ?count WHERE { <#{prior_id}> vaos:has_evidence ?ev . ?ev vaos:helpful_count ?count }"

            case MiosaKnowledge.sparql(store, query) do
              {:ok, results} when is_list(results) ->
                for r <- results do
                  ev_id = Map.get(r, "ev", "")
                  old_count_str = Map.get(r, "count", "0")

                  old_count =
                    case Integer.parse(old_count_str) do
                      {n, _} -> n
                      :error -> 0
                    end

                  MiosaKnowledge.retract(store, {ev_id, "vaos:helpful_count", old_count_str})

                  MiosaKnowledge.assert(
                    store,
                    {ev_id, "vaos:helpful_count", Integer.to_string(old_count + 1)}
                  )

                  Logger.debug(
                    "[investigate] Incremented helpful count for #{ev_id} to #{old_count + 1}"
                  )
                end

              _ ->
                :ok
            end

          _ ->
            :ok
        end
      end
    end)
  end

  defp significant_words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(10)
  end

  # -- Keyword extraction ----------------------------------------------

  defp extract_keywords(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.flat_map(fn word ->
      stem =
        word
        |> String.replace(~r/ing$/, "")
        |> String.replace(~r/tion$/, "t")
        |> String.replace(~r/ness$/, "")
        |> String.replace(~r/ment$/, "")
        |> String.replace(~r/able$/, "")
        |> String.replace(~r/ible$/, "")
        |> String.replace(~r/ly$/, "")
        |> String.replace(~r/ed$/, "")
        |> String.replace(~r/er$/, "")
        |> String.replace(~r/es$/, "")
        |> String.replace(~r/s$/, "")

      if stem != word and String.length(stem) >= 3, do: [word, stem], else: [word]
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  # -- Prior knowledge search — fetches EVIDENCE, not conclusions ------

  defp fetch_prior_evidence_by_keywords(store, keywords) do
    # Find prior investigations that match keywords
    topic_query =
      "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"

    kw_query = "SELECT ?s ?kw WHERE { ?s vaos:keyword ?kw . ?s rdf:type vaos:Investigation }"

    topic_results =
      case MiosaKnowledge.sparql(store, topic_query) do
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    kw_results =
      case MiosaKnowledge.sparql(store, kw_query) do
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    kw_matched_ids =
      kw_results
      |> Enum.filter(fn bindings ->
        stored_kw = Map.get(bindings, "kw", "") |> to_string() |> String.downcase()

        Enum.any?(keywords, fn kw ->
          kw == stored_kw or String.contains?(stored_kw, kw) or String.contains?(kw, stored_kw)
        end)
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)
      |> MapSet.new()

    matched_ids =
      topic_results
      |> Enum.filter(fn bindings ->
        s = Map.get(bindings, "s", "") |> to_string()
        topic_val = Map.get(bindings, "topic", Map.get(bindings, :topic, ""))
        topic_lower = String.downcase(to_string(topic_val))
        topic_match = Enum.any?(keywords, fn kw -> String.contains?(topic_lower, kw) end)
        kw_match = MapSet.member?(kw_matched_ids, s)
        topic_match or kw_match
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)

    # For each matched investigation, fetch the EVIDENCE summaries (not conclusions)
    Enum.flat_map(matched_ids, fn inv_id ->
      ev_query =
        "SELECT ?ev ?summary WHERE { <#{inv_id}> vaos:has_evidence ?ev . ?ev vaos:summary ?summary }"

      case MiosaKnowledge.sparql(store, ev_query) do
        {:ok, results} when is_list(results) ->
          Enum.map(results, fn r ->
            summary = Map.get(r, "summary", "")
            "  - #{summary} (id: #{inv_id})"
          end)

        _ ->
          []
      end
    end)
    # Limit keyword-matched to 10
    |> Enum.take(10)
    |> then(fn keyword_results ->
      # Widen: also search ALL evidence summaries for term overlap with topic
      broad_results = fetch_broad_evidence(store, keywords)
      # Merge, deduplicate by summary text
      seen = MapSet.new(Enum.map(keyword_results, fn line -> String.trim(line) end))

      additional =
        Enum.reject(broad_results, fn line -> MapSet.member?(seen, String.trim(line)) end)

      keyword_results ++ Enum.take(additional, 10)
    end)
  rescue
    e ->
      Logger.warning(
        "[investigate] fetch_prior_evidence_by_keywords failed: #{Exception.message(e)}"
      )

      []
  end

  defp fetch_broad_evidence(store, keywords) do
    # Search ALL evidence summaries across ALL investigations for term overlap
    all_ev_query = "SELECT ?ev ?summary WHERE { ?ev vaos:summary ?summary }"

    case MiosaKnowledge.sparql(store, all_ev_query) do
      {:ok, results} when is_list(results) ->
        kw_set = MapSet.new(keywords)

        results
        |> Enum.filter(fn r ->
          summary = Map.get(r, "summary", "") |> to_string() |> String.downcase()
          summary_words = String.split(summary, ~r/\s+/, trim: true) |> MapSet.new()
          overlap = MapSet.intersection(kw_set, summary_words) |> MapSet.size()
          # At least 2 keyword matches
          overlap >= 2
        end)
        |> Enum.map(fn r ->
          summary = Map.get(r, "summary", "")
          ev_id = Map.get(r, "ev", "")
          "  - #{summary} (id: #{ev_id})"
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # -- Source Circuit Breaker ---------------------------------------------------
  # ETS-based per-source circuit breaker. Prevents wasting 30s on APIs that are
  # consistently down — the single biggest performance blocker for investigations.

  defp ensure_circuit_table do
    case :ets.whereis(@circuit_table) do
      :undefined ->
        :ets.new(@circuit_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def circuit_check(source) when source in @circuit_sources do
    ensure_circuit_table()

    case :ets.lookup(@circuit_table, source) do
      [{^source, %{state: :open, tripped_at: tripped_at}}] ->
        elapsed = System.monotonic_time(:millisecond) - tripped_at

        if elapsed >= @circuit_cooldown_ms do
          # Cooldown expired → half-open: allow one probe request
          :ets.insert(
            @circuit_table,
            {source, %{state: :half_open, consecutive_failures: 0, tripped_at: tripped_at}}
          )

          Logger.info("[investigate] Circuit half-open for #{source} — probing")
          :ok
        else
          remaining = div(@circuit_cooldown_ms - elapsed, 1_000)

          Logger.debug(
            "[investigate] Circuit OPEN for #{source} — skipping (#{remaining}s remaining)"
          )

          :skip
        end

      [{^source, %{state: :half_open}}] ->
        # Already half-open, one probe in flight — skip additional queries
        :skip

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp circuit_record_success(source) do
    ensure_circuit_table()

    prev_state =
      case :ets.lookup(@circuit_table, source) do
        [{^source, %{state: s}}] -> s
        _ -> :closed
      end

    :ets.insert(
      @circuit_table,
      {source, %{state: :closed, consecutive_failures: 0, tripped_at: nil}}
    )

    if prev_state in [:half_open, :open] do
      Logger.info("[investigate] Circuit CLOSED for #{source} — recovered")
    end
  rescue
    _ -> :ok
  end

  defp circuit_record_failure(source) do
    ensure_circuit_table()

    entry =
      case :ets.lookup(@circuit_table, source) do
        [{^source, %{state: :half_open}}] ->
          # Half-open probe failed → back to open with fresh cooldown
          Logger.info("[investigate] Circuit re-OPENED for #{source} — probe failed")

          %{
            state: :open,
            consecutive_failures: @circuit_failure_threshold,
            tripped_at: System.monotonic_time(:millisecond)
          }

        [{^source, %{consecutive_failures: n} = entry}] ->
          new_count = n + 1

          if new_count >= @circuit_failure_threshold and entry.state != :open do
            Logger.warning(
              "[investigate] Circuit OPENED for #{source} — #{new_count} consecutive failures"
            )

            %{
              state: :open,
              consecutive_failures: new_count,
              tripped_at: System.monotonic_time(:millisecond)
            }
          else
            %{entry | consecutive_failures: new_count}
          end

        _ ->
          %{state: :closed, consecutive_failures: 1, tripped_at: nil}
      end

    :ets.insert(@circuit_table, {source, entry})
  rescue
    _ -> :ok
  end

  defp circuit_trip(source, reason) do
    ensure_circuit_table()

    Logger.warning("[investigate] Circuit OPENED for #{source} — #{reason}")

    :ets.insert(
      @circuit_table,
      {source,
       %{
         state: :open,
         consecutive_failures: @circuit_failure_threshold,
         tripped_at: System.monotonic_time(:millisecond)
       }}
    )
  rescue
    _ -> :ok
  end

  @doc "Get circuit breaker status for all sources"
  def circuit_status do
    ensure_circuit_table()

    Enum.map(@circuit_sources, fn source ->
      case :ets.lookup(@circuit_table, source) do
        [{^source, entry}] -> {source, entry}
        _ -> {source, %{state: :closed, consecutive_failures: 0}}
      end
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  # -- Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv --

  @doc false
  def run_semantic_scholar_queries(queries, http_fn, per_query, api_key \\ nil) do
    result =
      Enum.reduce_while(Enum.with_index(queries), %{results: [], terminal_failure?: false}, fn
        {{label, query, opts}, idx}, acc ->
          if idx > 0 and is_nil(api_key), do: Process.sleep(1_500)

          search_opts = Keyword.merge([limit: per_query], opts)

          search_opts =
            if api_key, do: Keyword.put(search_opts, :api_key, api_key), else: search_opts

          case Literature.search_semantic_scholar(query, http_fn, search_opts) do
            {:ok, papers} ->
              {:cont, %{acc | results: [{:"ss_#{label}", papers} | acc.results]}}

            {:error, reason} ->
              next = %{acc | results: [{:"ss_#{label}", []} | acc.results]}

              if semantic_scholar_terminal_error?(reason) do
                Logger.info(
                  "[investigate] Semantic Scholar terminal failure on #{label} — skipping remaining queries"
                )

                {:halt, %{next | terminal_failure?: true}}
              else
                {:cont, next}
              end
          end
      end)

    {Enum.reverse(result.results), result.terminal_failure?}
  end

  @doc false
  def semantic_scholar_terminal_error?({:semantic_scholar_failed, reason}),
    do: semantic_scholar_terminal_error?(reason)

  def semantic_scholar_terminal_error?(reason) when is_binary(reason) do
    String.contains?(reason, "HTTP 429") or
      String.contains?(reason, "HTTP 401") or
      String.contains?(reason, "HTTP 403")
  end

  def semantic_scholar_terminal_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&semantic_scholar_terminal_error?/1)
  end

  def semantic_scholar_terminal_error?(reason) when is_atom(reason) do
    reason in [:rate_limited, :unauthorized, :forbidden]
  end

  def semantic_scholar_terminal_error?(_), do: false

  defp search_all_papers(topic, keywords, strategy),
    do: search_all_papers(topic, keywords, strategy, [])

  defp search_all_papers(topic, keywords, strategy, opts) do
    http_fn = literature_http_fn()
    plan = search_query_plan(topic, keywords)
    normalized_topic = plan.normalized_topic
    semantic_seed = semantic_search_seed(plan)
    {ss_queries, oa_queries} = {plan.ss_queries, plan.oa_queries}
    per_query = strategy.per_query_limit
    alphaxiv_enabled? = Keyword.get(opts, :alphaxiv_enabled?, true)

    # Log circuit breaker state for observability (read-only peek, no state transitions)
    ensure_circuit_table()

    open_circuits =
      @circuit_sources
      |> Enum.filter(fn s ->
        case :ets.lookup(@circuit_table, s) do
          [{^s, %{state: :open}}] -> true
          _ -> false
        end
      end)

    if open_circuits != [] do
      Logger.info(
        "[investigate] Circuit breakers OPEN: #{Enum.join(open_circuits, ", ")} — skipping"
      )
    end

    # -- Circuit breaker gated source dispatch --
    # Each source is checked against its circuit breaker before launching tasks.
    # This prevents wasting 30s on APIs that are consistently down.

    # SS: sequential with 1.5s delay — unauthenticated rate limit is ~1 req/s.
    ss_api_key = Application.get_env(:daemon, :semantic_scholar_api_key)

    {ss_results, ss_terminal_failure?} =
      if circuit_check(:semantic_scholar) == :ok do
        run_semantic_scholar_queries(ss_queries, http_fn, per_query, ss_api_key)
      else
        {[], false}
      end

    if ss_results != [] or ss_terminal_failure? do
      any_papers = Enum.any?(ss_results, fn {_label, papers} -> papers != [] end)

      cond do
        any_papers ->
          circuit_record_success(:semantic_scholar)

        ss_terminal_failure? ->
          circuit_trip(:semantic_scholar, "terminal rate/auth failure")

        true ->
          circuit_record_failure(:semantic_scholar)
      end
    end

    # OA: parallel queries — circuit breaker gates the entire batch
    oa_tasks =
      if circuit_check(:openalex) == :ok do
        Enum.map(oa_queries, fn {label, query, opts} ->
          search_opts = Keyword.merge([limit: per_query], opts)

          Task.async(fn ->
            case Literature.search_openalex(query, http_fn, search_opts) do
              {:ok, papers} -> {:"oa_#{label}", papers}
              _ -> {:"oa_#{label}", []}
            end
          end)
        end)
      else
        []
      end

    # alphaXiv embedding search
    alphaxiv_task =
      if alphaxiv_enabled? and circuit_check(:alphaxiv) == :ok do
        Task.async(fn ->
          alias Daemon.Tools.Builtins.AlphaXivClient

          case AlphaXivClient.embedding_search(semantic_seed) do
            {:ok, papers} when papers != [] ->
              Logger.debug("[investigate] alphaXiv returned #{length(papers)} papers")
              {:alphaxiv, papers}

            _ ->
              Logger.debug("[investigate] alphaXiv unavailable")
              {:alphaxiv, []}
          end
        end)
      else
        nil
      end

    if not alphaxiv_enabled? do
      Logger.debug("[investigate] alphaXiv disabled — auth not configured")
    end

    # HuggingFace Papers search (ML/AI papers from arXiv via HF Hub API)
    hf_task =
      if circuit_check(:huggingface) == :ok do
        Task.async(fn ->
          alias Daemon.Tools.Builtins.HFPapersClient

          case HFPapersClient.search(semantic_seed, limit: 10) do
            {:ok, papers} when papers != [] ->
              Logger.debug("[investigate] HuggingFace returned #{length(papers)} papers")
              {:huggingface, papers}

            _ ->
              Logger.debug("[investigate] HuggingFace Papers unavailable")
              {:huggingface, []}
          end
        end)
      else
        nil
      end

    # yield_many — gracefully handle timeouts, then record circuit results
    all_tasks = (oa_tasks ++ [alphaxiv_task, hf_task]) |> Enum.reject(&is_nil/1)
    yielded = Task.yield_many(all_tasks, 30_000)

    # Track per-source success/failure for circuit breaker
    oa_task_set = MapSet.new(oa_tasks)

    async_results =
      Enum.flat_map(yielded, fn
        {_task, {:ok, result}} ->
          # Record circuit success based on source
          case result do
            {:alphaxiv, papers} ->
              if papers != [],
                do: circuit_record_success(:alphaxiv),
                else: circuit_record_failure(:alphaxiv)

            {:huggingface, papers} ->
              if papers != [],
                do: circuit_record_success(:huggingface),
                else: circuit_record_failure(:huggingface)

            {oa_label, _papers} when is_atom(oa_label) ->
              # OA success tracked after all OA tasks complete (below)
              :ok

            _ ->
              :ok
          end

          [result]

        {_task, {:exit, reason}} ->
          Logger.warning("[investigate] Paper search task crashed: #{inspect(reason)}")
          []

        {task, nil} ->
          Logger.warning("[investigate] Paper search task timed out — proceeding without")
          # Record timeout as failure for the source
          if MapSet.member?(oa_task_set, task) do
            # Don't record per-task — we'll batch record OA below
            :ok
          else
            # Must be alphaxiv or huggingface
            # Can't easily determine which without extra tracking, but timeouts are rare for these
            :ok
          end

          Task.shutdown(task, :brutal_kill)
          []
      end)

    # Batch-record OA circuit result: success if ANY OA query returned papers
    if oa_tasks != [] do
      oa_results =
        Enum.filter(async_results, fn
          {label, _} when is_atom(label) -> String.starts_with?(Atom.to_string(label), "oa_")
          _ -> false
        end)

      oa_any_papers = Enum.any?(oa_results, fn {_label, papers} -> papers != [] end)
      oa_all_timed_out = length(oa_results) == 0 and length(oa_tasks) > 0

      cond do
        oa_any_papers -> circuit_record_success(:openalex)
        oa_all_timed_out -> circuit_record_failure(:openalex)
        true -> circuit_record_failure(:openalex)
      end
    end

    results = ss_results ++ async_results

    # Collect source counts
    source_counts =
      Enum.reduce(results, %{}, fn {source, papers}, acc ->
        source_key = source |> Atom.to_string() |> source_category()
        Map.update(acc, source_key, length(papers), &(&1 + length(papers)))
      end)

    # Collect raw papers and ensure atom keys for rank_papers compatibility
    all_raw =
      Enum.flat_map(results, fn {_source, papers} ->
        Enum.map(papers, &ensure_atom_keys/1)
      end)

    # Dedup by title similarity (works on both atom and string keys)
    deduped = merge_papers_raw(all_raw)

    # Rank by relevance BEFORE normalizing (papers have atom keys)
    ranked = Literature.rank_papers(deduped, normalized_topic)
    reranked = rerank_retrieval_candidates(ranked, plan)

    # Filter out irrelevant papers (zero topic-term overlap)
    {relevant, dropped} = filter_relevant(reranked, plan)

    if dropped > 0 do
      Logger.info("[investigate] Filtered out #{dropped} irrelevant papers")
    end

    # Normalize to string-key format and take top N (tuned by strategy)
    sorted =
      relevant
      |> Enum.map(&normalize_paper_format/1)
      |> Enum.take(strategy.top_n_papers)

    {sorted, source_counts}
  end

  @doc false
  def normalized_search_topic(topic) do
    ClaimFamily.normalize_topic(topic)
  end

  @doc false
  def search_query_plan(topic, keywords \\ []) do
    normalized_topic = normalized_search_topic(topic)
    normalized_keywords = search_keywords(normalized_topic, keywords)
    terms = topic_terms(normalized_topic)
    claim_family = ClaimFamily.match(normalized_topic, normalized_keywords, terms)
    profile = ClaimFamily.search_profile(normalized_topic, normalized_keywords, terms)
    evidence_profile = ClaimFamily.evidence_profile(normalized_topic, normalized_keywords, terms)

    {ss_queries, oa_queries} =
      build_search_queries(
        normalized_topic,
        normalized_keywords,
        terms,
        profile,
        evidence_profile
      )

    %{
      normalized_topic: normalized_topic,
      keywords: normalized_keywords,
      claim_family: claim_family && claim_family.kind,
      profile: profile,
      evidence_profile: evidence_profile,
      ss_queries: ss_queries,
      oa_queries: oa_queries
    }
  end

  @doc false
  def rerank_retrieval_candidates(
        papers,
        %{profile: :general, normalized_topic: topic, evidence_profile: evidence_profile}
      )
      when is_list(papers) do
    topic_terms = distinctive_topic_terms(topic)

    papers
    |> Enum.with_index()
    |> Enum.sort_by(fn {paper, index} ->
      {-retrieval_directness_score(paper, topic_terms, evidence_profile), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def rerank_retrieval_candidates(papers, _plan) when is_list(papers), do: papers

  # Build search queries split by API. SS gets 3 queries (rate limit safe),
  # OA gets the broader query family. Returns {ss_queries, oa_queries}.
  defp build_search_queries(topic, keywords, terms, _profile, evidence_profile) do
    topic_words = topic_terms(topic) |> MapSet.new()
    keyword_topic = keyword_query_topic(topic, keywords)

    novel_keywords =
      Enum.reject(keywords, fn kw -> MapSet.member?(topic_words, kw) end) |> Enum.take(3)

    {ss_queries, oa_queries} =
      ClaimFamily.search_queries(topic, keywords, terms, evidence_profile)

    oa_queries =
      if novel_keywords != [] do
        oa_queries ++
          [{:keywords_augmented, "#{keyword_topic} #{Enum.join(novel_keywords, " ")}", []}]
      else
        oa_queries
      end

    {ss_queries, oa_queries}
  end

  # Categorize source labels into summary keys
  defp source_category("alphaxiv"), do: :alphaxiv
  defp source_category("huggingface"), do: :huggingface
  defp source_category("ss_" <> _), do: :semantic_scholar
  defp source_category("oa_" <> _), do: :openalex
  defp source_category(_other), do: :other

  # Dedup raw papers (handles both atom-key and string-key formats)
  defp merge_papers_raw(papers) when is_list(papers) do
    Enum.uniq_by(papers, fn p ->
      title =
        case p do
          %{title: t} -> t
          %{"title" => t} -> t
          _ -> ""
        end

      title
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 4))
      |> Enum.sort()
      |> Enum.take(5)
      |> Enum.join(" ")
    end)
  end

  # Filter papers by topic-term overlap. Returns {relevant_papers, dropped_count}.
  # Requires the MOST SPECIFIC term (longest word) to appear in title or abstract.
  # This prevents generic words like "effectiveness" from matching unrelated papers
  # (e.g. "Effectiveness of treatments for firework fears in dogs").
  defp filter_relevant(papers, %{
         profile: :general,
         normalized_topic: topic,
         evidence_profile: evidence_profile
       })
       when is_map(evidence_profile) do
    specific_terms = Map.get(evidence_profile, :required_terms, [])
    subject_terms = Map.get(evidence_profile, :subject_terms, [])

    {relevant, dropped} =
      Enum.split_with(papers, fn paper ->
        paper_text = paper_search_text(paper)

        subject_hit =
          subject_terms == [] or Enum.any?(subject_terms, &String.contains?(paper_text, &1))

        evidence_hit = Enum.any?(specific_terms, &String.contains?(paper_text, &1))
        subject_hit and evidence_hit
      end)

    if relevant == [] do
      filter_relevant(papers, %{normalized_topic: topic})
    else
      {relevant, length(dropped)}
    end
  end

  defp filter_relevant(papers, %{normalized_topic: topic}) do
    distinctive_terms = distinctive_topic_terms(topic)

    # Generic modifiers that appear across many domains — never use as primary filter term
    generic_modifiers =
      ~w(effectiveness effective efficacy efficient analysis review evidence impact treatment treatments outcomes study studies comparison)

    # Primary term: first non-generic term, or longest term as fallback
    primary_term =
      Enum.find(distinctive_terms, fn t -> t not in generic_modifiers end) ||
        Enum.max_by(distinctive_terms, &String.length/1, fn -> nil end)

    # If no distinctive terms found, skip filtering entirely
    if primary_term == nil do
      {papers, 0}
    else
      {relevant, dropped} =
        Enum.split_with(papers, fn paper ->
          {title, abstract} =
            case paper do
              %{title: t, abstract: a} -> {t, a}
              %{"title" => t, "abstract" => a} -> {t, a}
              _ -> {"", ""}
            end

          paper_text =
            "#{title} #{abstract}"
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9\s\-]/, " ")

          # Primary (most specific) term MUST appear in title or abstract
          String.contains?(paper_text, primary_term)
        end)

      {relevant, length(dropped)}
    end
  end

  # Normalize Literature module structs (atom keys) to the string-key format
  # used throughout investigate.ex
  defp normalize_paper_format(%{title: t, source: src} = paper) do
    %{
      "title" => to_string(t || "Unknown"),
      "abstract" => to_string(paper[:abstract] || ""),
      "year" => to_string(paper[:year] || "unknown"),
      "citation_count" => paper[:citation_count] || 0,
      "citationCount" => paper[:citation_count] || 0,
      "source" => to_string(src),
      "authors" =>
        case paper[:authors] do
          list when is_list(list) -> Enum.join(list, ", ")
          str when is_binary(str) -> str
          _ -> ""
        end,
      "paper_id" => to_string(paper[:paper_id] || ""),
      "url" => to_string(paper[:url] || ""),
      "doi" => to_string(paper[:doi] || ""),
      "publicationTypes" => paper[:publication_types] || []
    }
  end

  # Already string-keyed (from alphaXiv, HuggingFace, or legacy formats)
  defp normalize_paper_format(%{"title" => _} = paper) do
    Map.merge(
      %{
        "citation_count" => 0,
        "citationCount" => 0,
        "source" => "unknown",
        "authors" => "",
        "abstract" => "",
        "year" => "unknown",
        "publicationTypes" => []
      },
      paper
    )
    |> Map.update("citation_count", 0, fn v -> v || 0 end)
    |> Map.update("citationCount", 0, fn v -> v || 0 end)
  end

  defp normalize_paper_format(other) do
    Logger.warning(
      "[investigate] Unknown paper format: #{inspect(other) |> String.slice(0, 200)}"
    )

    %{
      "title" => "Unknown",
      "abstract" => "",
      "year" => "unknown",
      "citation_count" => 0,
      "citationCount" => 0,
      "source" => "unknown"
    }
  end

  defp search_keywords(topic, keywords) do
    base_keywords =
      case keywords do
        list when is_list(list) and list != [] -> list
        _ -> extract_keywords(topic)
      end

    base_keywords
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(&1 in @search_relation_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp keyword_query_topic(topic, keywords) do
    case keywords do
      [] -> topic
      _ -> Enum.join(keywords, " ")
    end
  end

  defp distinctive_topic_terms(topic) do
    topic
    |> topic_terms()
    |> Enum.reject(&(String.length(&1) < 4))
  end

  defp topic_terms(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(&1 in @search_relation_words))
  end

  defp retrieval_directness_score(paper, topic_terms, evidence_profile) do
    evidence_profile = evidence_profile || %{}

    {title, abstract} =
      case paper do
        %{title: t, abstract: a} -> {t, a}
        %{"title" => t, "abstract" => a} -> {t, a}
        _ -> {"", ""}
      end

    title_text = normalize_search_text(title)
    paper_text = normalize_search_text("#{title} #{abstract}")

    title_hits = Enum.count(topic_terms, &String.contains?(title_text, &1))
    topic_hits = Enum.count(topic_terms, &String.contains?(paper_text, &1))
    discourse_hits = Enum.count(@retrieval_discourse_terms, &String.contains?(paper_text, &1))

    evidence_hits =
      evidence_profile
      |> Map.get(:required_terms, [])
      |> Enum.count(&String.contains?(paper_text, &1))

    stable_hits =
      evidence_profile
      |> Map.get(:stable_terms, [])
      |> Enum.count(&String.contains?(paper_text, &1))

    citation_count =
      case paper do
        %{citation_count: count} when is_number(count) -> count
        %{"citation_count" => count} when is_number(count) -> count
        %{"citationCount" => count} when is_number(count) -> count
        _ -> 0
      end

    citation_bonus =
      citation_count
      |> Kernel.+(1)
      |> :math.log10()
      |> Kernel.*(1.5)

    title_hits * 4 + topic_hits * 2 + evidence_hits * 3 + stable_hits * 4 + citation_bonus -
      discourse_hits * 3
  end

  defp semantic_search_seed(%{evidence_profile: %{semantic_seed: seed}})
       when is_binary(seed) and seed != "" do
    seed
  end

  defp semantic_search_seed(%{normalized_topic: topic}), do: topic

  defp normalize_search_text(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
  end

  defp paper_search_text(paper) do
    {title, abstract} =
      case paper do
        %{title: t, abstract: a} -> {t, a}
        %{"title" => t, "abstract" => a} -> {t, a}
        _ -> {"", ""}
      end

    normalize_search_text("#{title} #{abstract}")
  end

  # Convert string-keyed papers (e.g. from alphaXiv) to atom keys for rank_papers compatibility
  defp ensure_atom_keys(%{title: _} = paper), do: paper

  defp ensure_atom_keys(%{"title" => _} = paper) do
    %{
      title: paper["title"] || "",
      abstract: paper["abstract"] || "",
      year: parse_year(paper["year"]),
      citation_count: paper["citation_count"] || paper["citationCount"] || 0,
      source: safe_to_atom(paper["source"] || "alphaxiv"),
      authors: paper["authors"] || [],
      paper_id: paper["paper_id"] || paper["paperId"] || "",
      url: paper["url"] || "",
      doi: paper["doi"] || nil,
      publication_types: paper["publicationTypes"] || []
    }
  end

  defp ensure_atom_keys(other), do: other

  # Safe atom conversion for known source values
  defp safe_to_atom(s) when is_atom(s), do: s
  defp safe_to_atom("semantic_scholar"), do: :semantic_scholar
  defp safe_to_atom("openalex"), do: :openalex
  defp safe_to_atom("alphaxiv"), do: :alphaxiv
  defp safe_to_atom("huggingface"), do: :huggingface
  defp safe_to_atom(_), do: :unknown

  defp parse_year(nil), do: nil
  defp parse_year(y) when is_integer(y), do: y

  defp parse_year(y) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_year(_), do: nil

  # HTTP adapter for vaos-ledger Literature module — uses Req
  # - OpenAlex polite pool: injects mailto param for faster server routing
  # - Explicit connect timeout: prevents TCP hangs on unreachable hosts
  # - User-Agent: identifies daemon for API providers
  defp literature_http_fn do
    fn url, opts ->
      params = Keyword.get(opts, :params, [])
      headers = Keyword.get(opts, :headers, [])

      # Inject mailto for OpenAlex polite pool — routed to faster servers
      # See: https://docs.openalex.org/how-to-use-the-api/rate-limits-and-authentication
      params =
        if String.contains?(url, "openalex.org") do
          params ++ [{"mailto", @openalex_mailto}]
        else
          params
        end

      # Build query string from params
      query_string =
        case params do
          [] ->
            ""

          kv_list ->
            kv_list
            |> Enum.map(fn
              {k, v} ->
                "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"

              other ->
                to_string(other)
            end)
            |> Enum.join("&")
        end

      full_url = if query_string == "", do: url, else: "#{url}?#{query_string}"

      req_headers = [
        {"user-agent", "VAOS-Daemon/1.0 (#{@openalex_mailto})"}
        | Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
      ]

      # retry: false — investigation pipeline handles failures via circuit breaker;
      # Req's default transient retry adds 15-20s per attempt, pushing past yield_many timeout.
      # pool_timeout: 5s — prevent Finch connection pool queuing when pool is saturated.
      case Req.get(full_url,
             headers: req_headers,
             receive_timeout: 15_000,
             connect_options: [timeout: 5_000],
             pool_timeout: 5_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            err -> {:error, {:json_decode_failed, err}}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[investigate] HTTP #{status} from #{url}: #{inspect(body) |> String.slice(0, 200)}"
          )

          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.warning("[investigate] HTTP request failed for #{url}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp format_source_counts(counts) do
    counts
    |> Enum.map(fn {source, count} -> "#{count} via #{source}" end)
    |> Enum.join(", ")
  end

  # -- Cross-investigation contradiction detection ---------------------

  defp detect_contradictions(store, current_id, current_direction, current_keywords) do
    case MiosaKnowledge.sparql(
           store,
           "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"
         ) do
      {:ok, results} when is_list(results) ->
        results
        |> Enum.reject(fn r -> Map.get(r, "s") == current_id end)
        |> Enum.filter(fn r ->
          prior_topic = Map.get(r, "topic", "") |> String.downcase()
          Enum.any?(current_keywords, fn kw -> String.contains?(prior_topic, kw) end)
        end)
        |> Enum.flat_map(fn r ->
          prior_id = Map.get(r, "s", "")
          prior_topic = Map.get(r, "topic", "")

          case MiosaKnowledge.sparql(
                 store,
                 "SELECT ?dir WHERE { <#{prior_id}> vaos:direction ?dir }"
               ) do
            {:ok, [prior | _]} ->
              prior_direction = Map.get(prior, "dir", "unknown")

              is_conflict =
                (current_direction == "supporting" and
                   prior_direction in ["opposing", "genuinely_contested"]) or
                  (current_direction == "opposing" and
                     prior_direction in ["supporting", "genuinely_contested"]) or
                  (current_direction != prior_direction and
                     current_direction != "genuinely_contested" and
                     prior_direction != "genuinely_contested")

              if is_conflict do
                MiosaKnowledge.assert(store, {current_id, "vaos:contradicts", prior_id})
                MiosaKnowledge.assert(store, {prior_id, "vaos:contradictedBy", current_id})

                Logger.warning(
                  "[investigate] Epistemic tension: #{current_id} contradicts #{prior_id}"
                )

                [
                  %{
                    prior_id: prior_id,
                    prior_topic: prior_topic,
                    prior_direction: prior_direction
                  }
                ]
              else
                []
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # -- Cached citation verification (uses Scorer ETS table) -----------

  defp cached_verify(evidence, paper, prompts) do
    # Use the same ETS table as Vaos.Ledger.Experiment.Scorer for caching
    ensure_scorer_cache()
    cache_key = :erlang.phash2({verification_claim_text(evidence.summary), paper["title"]})

    case :ets.lookup(:scorer_cache, {:verify, cache_key}) do
      [{{:verify, ^cache_key}, result}] ->
        Logger.debug("[investigate] Cache hit for citation verification")
        {:hit, result}

      [] ->
        result = verify_single_citation(evidence, paper, prompts)
        :ets.insert(:scorer_cache, {{:verify, cache_key}, result})
        {:miss, result}
    end
  end

  defp ensure_scorer_cache do
    if :ets.whereis(:scorer_cache) == :undefined do
      try do
        :ets.new(:scorer_cache, [:set, :public, :named_table])
      rescue
        # Another process created it between whereis and new
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # -- Advocacy quality assessment (Referee-inspired) -----------------

  defp assess_advocacy_quality(supporting, opposing) do
    for_fraud_rate =
      if supporting == [] do
        0.0
      else
        Enum.count(supporting, fn ev -> ev.verification == "unverified" end) / length(supporting)
      end

    against_fraud_rate =
      if opposing == [] do
        0.0
      else
        Enum.count(opposing, fn ev -> ev.verification == "unverified" end) / length(opposing)
      end

    cond do
      for_fraud_rate > 0.5 ->
        "### Advocacy Quality Warning\n" <>
          "FOR advocate had #{round(for_fraud_rate * 100)}% fraudulent citations -- arguments are poorly grounded"

      against_fraud_rate > 0.5 ->
        "### Advocacy Quality Warning\n" <>
          "AGAINST advocate had #{round(against_fraud_rate * 100)}% fraudulent citations -- arguments are poorly grounded"

      for_fraud_rate > 0.3 or against_fraud_rate > 0.3 ->
        "### Advocacy Quality Note\n" <>
          "Some citations were not supported by paper abstracts -- interpret with caution " <>
          "(FOR: #{round(for_fraud_rate * 100)}% unverified, AGAINST: #{round(against_fraud_rate * 100)}% unverified)"

      true ->
        ""
    end
  end

  # -- Uncertainty iteration hint (Experiment.Loop-inspired) ----------

  defp maybe_suggest_iteration(claim, ledger_name) do
    try do
      metrics = EpistemicLedger.claim_metrics(claim.id, ledger_name)
      uncertainty = metrics["uncertainty"]

      if uncertainty > @high_uncertainty_threshold do
        "\n### Iteration Suggested\n" <>
          "High uncertainty detected (#{Float.round(uncertainty * 1.0, 3)}). " <>
          "Consider re-investigating with more specific sub-questions to reduce epistemic uncertainty.\n"
      else
        ""
      end
    rescue
      _ -> ""
    end
  end

  # -- Deep research mode (Pipeline integration) ----------------------
  #
  # Runner (Vaos.Ledger.ML.Runner) is available for code-execution
  # investigations in a future "experimental" depth mode.
  # When depth: "experimental":
  #   alias Vaos.Ledger.ML.Runner
  #   Runner.start_link(trial_id: topic_id, experiment_fn: fn config -> ... end,
  #                     max_steps: 100, max_seconds: 120)
  #   This would execute Python/Elixir code to test hypotheses empirically,
  #   with Referee (Vaos.Ledger.ML.Referee) monitoring trials and killing
  #   underperformers via early stopping.

  defp deep_research_note(topic, claim, _all_papers, _store) do
    try do
      Logger.info("[investigate] Running deep research pipeline for: #{topic}")

      # Build an LLM callback compatible with Pipeline
      llm_fn = fn prompt ->
        model = preferred_utility_model()
        llm_opts = [temperature: 0.3, max_tokens: 8192]
        llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts
        messages = [%{role: "user", content: prompt}]

        case Providers.chat(messages, llm_opts) do
          {:ok, %{content: response}} when is_binary(response) -> {:ok, response}
          {:ok, other} -> {:error, {:unexpected_response, other}}
          {:error, reason} -> {:error, reason}
        end
      end

      # Build an HTTP callback for literature search
      http_fn = literature_http_fn()

      # Generate hypotheses from the investigation topic
      hypotheses = generate_research_hypotheses(topic, claim, llm_fn)

      if hypotheses == [] do
        ""
      else
        # Run lightweight pipeline passes for each hypothesis (idea -> method -> literature)
        # Code execution via Crucible sandbox (or local fallback in dev)
        results =
          hypotheses
          |> Enum.take(3)
          |> Enum.map(fn hypothesis ->
            try do
              case Pipeline.run(
                     ledger: ensure_ledger_pid(),
                     llm_fn: llm_fn,
                     code_fn: build_code_fn(),
                     input: hypothesis,
                     http_fn: http_fn,
                     max_iterations: 1,
                     target_score: 0.5
                   ) do
                {:ok, pipeline_state} ->
                  research = pipeline_state.research
                  summary = String.slice(research.idea || "", 0, 200)
                  method_summary = String.slice(research.methodology || "", 0, 200)

                  # Determine direction from hypothesis/summary content
                  research_direction =
                    cond do
                      Regex.match?(
                        ~r/\b(refut|contra|disprove|against|fail|negat|not\s+support)\b/i,
                        hypothesis <> " " <> summary
                      ) ->
                        :oppose

                      true ->
                        :support
                    end

                  # Add finding as new evidence to the ledger
                  EpistemicLedger.add_evidence(
                    [
                      claim_id: claim.id,
                      summary: "Deep research finding: #{summary}",
                      direction: research_direction,
                      strength: 0.3,
                      confidence: 0.3,
                      source_type: "research_pipeline",
                      metadata: %{"hypothesis" => hypothesis, "method" => method_summary}
                    ],
                    @ledger_name
                  )

                  {:ok, %{hypothesis: hypothesis, idea: summary, method: method_summary}}

                {:error, reason} ->
                  {:error, %{hypothesis: hypothesis, reason: inspect(reason)}}
              end
            rescue
              e -> {:error, %{hypothesis: hypothesis, reason: Exception.message(e)}}
            end
          end)

        # Refresh claim metrics after adding new evidence
        EpistemicLedger.refresh_claim(claim.id, @ledger_name)
        EpistemicLedger.save(@ledger_name)

        # Format results
        ok_results = Enum.filter(results, fn {status, _} -> status == :ok end)
        err_results = Enum.filter(results, fn {status, _} -> status == :error end)

        if ok_results == [] do
          "\n### Deep Research\nPipeline attempted #{length(hypotheses)} hypotheses but all failed.\n"
        else
          lines =
            ok_results
            |> Enum.with_index(1)
            |> Enum.map(fn {{:ok, r}, i} ->
              "  #{i}. **Hypothesis:** #{r.hypothesis}\n" <>
                "     **Idea:** #{r.idea}\n" <>
                "     **Method:** #{r.method}"
            end)
            |> Enum.join("\n\n")

          err_note =
            if err_results != [] do
              "\n  (#{length(err_results)} hypothesis pipeline(s) failed)"
            else
              ""
            end

          "\n### Deep Research (Pipeline)\n" <>
            "Generated #{length(hypotheses)} hypotheses, ran #{length(ok_results)} successfully:\n\n" <>
            lines <> err_note <> "\n"
        end
      end
    rescue
      e ->
        Logger.warning("[investigate] Deep research failed: #{Exception.message(e)}")
        "\n### Deep Research\nPipeline failed: #{Exception.message(e)}\n"
    end
  end

  defp generate_research_hypotheses(topic, _claim, llm_fn) do
    prompt = """
    Given this research topic, generate 3 testable hypotheses that could advance
    understanding. Each hypothesis should be specific, falsifiable, and distinct.

    Topic: #{topic}

    Respond with one hypothesis per line, numbered 1-3. Just the hypothesis text, nothing else.
    """

    case llm_fn.(prompt) do
      {:ok, response} ->
        response
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          line
          |> String.replace(~r/^\d+\.\s*/, "")
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(3)

      {:error, _} ->
        []
    end
  end

  defp ensure_ledger_pid do
    case Process.whereis(@ledger_name) do
      nil ->
        {:ok, pid} = EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name)
        pid

      pid ->
        pid
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp result_with_completion_artifacts(result, json_metadata, caller_metadata) do
    json_result = emit_successful_investigation(json_metadata, caller_metadata)
    result <> "\n\n<!-- VAOS_JSON:#{json_result} -->"
  end

  @doc false
  def build_boundary_trace(trace_context, attrs \\ %{})
      when is_map(trace_context) and is_map(attrs) do
    final_metadata = Map.get(attrs, :final_metadata, %{})
    parsed_supporting = Map.get(attrs, :parsed_supporting, [])
    parsed_opposing = Map.get(attrs, :parsed_opposing, [])
    verified_supporting = Map.get(attrs, :verified_supporting, [])
    verified_opposing = Map.get(attrs, :verified_opposing, [])

    %{
      steering: text_snapshot(Map.get(trace_context, :steering, "")),
      prompts: %{
        for_system: text_snapshot(message_content(Map.get(trace_context, :for_messages, []), 0)),
        for_user: text_snapshot(message_content(Map.get(trace_context, :for_messages, []), 1)),
        against_system:
          text_snapshot(message_content(Map.get(trace_context, :against_messages, []), 0)),
        against_user:
          text_snapshot(message_content(Map.get(trace_context, :against_messages, []), 1))
      },
      llm: %{
        for: normalize_chat_result(Map.get(trace_context, :for_result)),
        against: normalize_chat_result(Map.get(trace_context, :against_result))
      },
      parsed: %{
        supporting_count: length(parsed_supporting),
        opposing_count: length(parsed_opposing),
        supporting: evidence_trace(parsed_supporting),
        opposing: evidence_trace(parsed_opposing)
      },
      verified: %{
        supporting_count: length(verified_supporting),
        opposing_count: length(verified_opposing),
        supporting: evidence_trace(verified_supporting),
        opposing: evidence_trace(verified_opposing)
      },
      classification: %{
        grounded_for_count: map_value(final_metadata, :grounded_for_count) || 0,
        grounded_against_count: map_value(final_metadata, :grounded_against_count) || 0,
        belief_for_count: map_value(final_metadata, :belief_for_count) || 0,
        belief_against_count: map_value(final_metadata, :belief_against_count) || 0
      },
      outcome: %{
        direction: map_value(final_metadata, :direction),
        partial: map_value(final_metadata, :partial) || false,
        verified_for: map_value(final_metadata, :verified_for) || 0,
        verified_against: map_value(final_metadata, :verified_against) || 0,
        fraudulent_citations: map_value(final_metadata, :fraudulent_citations) || 0
      },
      timings: Map.get(attrs, :timings, %{}),
      verification_stats: Map.get(attrs, :verification_stats, %{})
    }
  end

  @doc false
  def maybe_capture_trace(json_metadata, caller_metadata, trace_payload)
      when is_map(json_metadata) and is_map(caller_metadata) and is_map(trace_payload) do
    if trace_requested?(caller_metadata) do
      label = trace_label(caller_metadata)
      topic = map_value(json_metadata, :topic) || "investigation"

      payload = %{
        trace_label: label,
        captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        topic: topic,
        investigation_id: map_value(json_metadata, :investigation_id),
        direction: map_value(json_metadata, :direction),
        partial: map_value(json_metadata, :partial) || false,
        trace: trace_payload
      }

      case write_trace_payload(topic, label, payload) do
        {:ok, path} ->
          json_metadata
          |> Map.put(:trace_label, label)
          |> Map.put(:trace_path, path)

        {:error, reason} ->
          Logger.warning("[investigate] Failed to persist trace payload: #{inspect(reason)}")
          Map.put(json_metadata, :trace_error, inspect(reason))
      end
    else
      json_metadata
    end
  end

  defp emit_successful_investigation(json_metadata, caller_metadata, opts \\ []) do
    json_result = Jason.encode!(json_metadata)

    try do
      bundle = Daemon.Receipt.Bundle.from_investigation(json_metadata)
      Daemon.Receipt.Emitter.emit_async(bundle)
    catch
      _, _ -> :ok
    end

    case {Keyword.get(opts, :store), payload_value(json_metadata, :investigation_id)} do
      {store, investigation_id} when not is_nil(store) and is_binary(investigation_id) ->
        MiosaKnowledge.assert(store, {investigation_id, "vaos:json_result", json_result})

      _ ->
        :ok
    end

    json_metadata = Map.merge(json_metadata, caller_metadata)

    try do
      Daemon.Events.Bus.emit(:investigation_complete, json_metadata)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    json_result
  end

  defp observe_trial_failure(topic, reason) when is_binary(topic) do
    reason =
      case reason do
        value when is_binary(value) -> value
        value -> inspect(value)
      end

    AdaptationTrials.observe_failure(topic, reason)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp evidence_metadata(evidence) do
    Enum.map(evidence, fn ev ->
      %{
        summary: ev.summary,
        score: ev.score,
        verified: ev.verified,
        verification: ev.verification,
        paper_type: stringify_term(ev.paper_type),
        citation_count: ev.citation_count,
        strength_display: ev.strength,
        source_quality: Map.get(ev, :source_quality, 0),
        source_type: stringify_term(Map.get(ev, :source_type)),
        evidence_store: stringify_term(Map.get(ev, :evidence_store, :unknown))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp build_trace_context(
         topic,
         steering,
         for_messages,
         against_messages,
         for_result,
         against_result
       ) do
    %{
      topic: topic,
      steering: steering,
      for_messages: for_messages,
      against_messages: against_messages,
      for_result: for_result,
      against_result: against_result
    }
  end

  defp evidence_trace(evidence) when is_list(evidence) do
    Enum.map(evidence, fn ev ->
      summary = map_value(ev, :summary)

      %{
        summary: summary,
        verification_claim: verification_claim_text(to_string(summary || "")),
        paper_ref: extract_paper_ref(to_string(summary || "")),
        score: map_value(ev, :score),
        verified: map_value(ev, :verified),
        verification: stringify_term(map_value(ev, :verification)),
        paper_type: stringify_term(map_value(ev, :paper_type)),
        source_type: stringify_term(map_value(ev, :source_type)),
        evidence_store: stringify_term(map_value(ev, :evidence_store)),
        citation_count: map_value(ev, :citation_count)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp normalize_chat_result({:ok, %{content: content}}) when is_binary(content) do
    %{status: "ok", content: text_snapshot(content)}
  end

  defp normalize_chat_result({:error, reason}) do
    %{status: "error", reason: inspect(reason)}
  end

  defp normalize_chat_result(other) do
    %{status: "other", value: inspect(other)}
  end

  @doc false
  def verification_claim_text(summary) when is_binary(summary) do
    summary
    |> strip_evidence_prefix()
    |> normalize_verification_whitespace()
    |> prefer_followup_reported_sentence()
    |> first_citation_sentence()
    |> trim_after_other_paper_ref()
    |> prefer_quote_after_inline_paper_definition()
    |> prefer_quote_before_followup_reporting()
    |> trim_after_last_quote()
    |> strip_verification_markup()
    |> strip_leading_attribution_clause()
    |> strip_leading_reporting_clause()
    |> strip_subject_reporting_clause()
    |> strip_abstract_reporting_subject()
    |> strip_leading_context_clause()
    |> rewrite_reporting_fragments()
    |> trim_trailing_inference_clause()
    |> prefer_complete_quote_after_ellipsis()
    |> strip_drawback_wrapper_before_quote()
    |> prefer_reported_subclause()
    |> prefer_definition_quote()
    |> prefer_subject_plus_quoted_predicate()
    |> ClaimFamily.normalize_verification_claim()
    |> String.trim()
  end

  def verification_claim_text(nil), do: ""
  def verification_claim_text(other), do: verification_claim_text(to_string(other))

  defp message_content(messages, index) when is_list(messages) and is_integer(index) do
    case Enum.at(messages, index) do
      %{content: content} when is_binary(content) -> content
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp trace_requested?(caller_metadata) do
    case map_value(caller_metadata, :trace_capture) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp trace_label(caller_metadata) do
    case map_value(caller_metadata, :trace_label) do
      label when is_binary(label) and label != "" -> label
      _ -> "investigate"
    end
  end

  defp write_trace_payload(topic, label, payload) do
    safe_label = sanitize_trace_label(label)

    trace_name =
      "vaos-investigate-trace-#{short_hash(topic)}-#{safe_label}-#{System.system_time(:millisecond)}.json"

    path = Path.join(System.tmp_dir!(), trace_name)
    File.write(path, Jason.encode_to_iodata!(payload, pretty: true))
    {:ok, path}
  rescue
    error -> {:error, error}
  end

  defp sanitize_trace_label(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "investigate"
      sanitized -> sanitized
    end
  end

  defp text_snapshot(text) when is_binary(text) do
    trimmed = String.trim(text)

    %{
      bytes: byte_size(trimmed),
      sha256: short_hash(trimmed),
      preview: String.slice(trimmed, 0, 800),
      tail: tail_slice(trimmed, 240)
    }
  end

  defp text_snapshot(nil), do: nil
  defp text_snapshot(other), do: text_snapshot(to_string(other))

  defp tail_slice(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    length = String.length(text)

    if length <= limit do
      text
    else
      String.slice(text, length - limit, limit)
    end
  end

  defp strip_evidence_prefix(summary) do
    summary
    |> String.replace(
      ~r/^\s*[*_`#\s]*(?:#+\s*)?\d+[\.\)]?\s*\[(?:SOURCED|REASONING)\]\s*\((?:strength|score)\s*:\s*\d+(?:\/\d+)?\)\s*/iu,
      ""
    )
    |> String.replace(
      ~r/^\s*[*_`]*(?:\d+[\.\)]\s*)?\[(?:SOURCED|REASONING)\]\s*\((?:strength|score)\s*:\s*\d+(?:\/\d+)?\)\s*/iu,
      ""
    )
  end

  defp normalize_verification_whitespace(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp prefer_followup_reported_sentence(summary) when is_binary(summary) do
    case extract_paper_ref(summary) do
      nil ->
        summary

      paper_ref ->
        sentences =
          summary
          |> protect_sentence_abbreviation_periods()
          |> then(&Regex.split(~r/(?<=[.!?])\s+/, &1, trim: true))
          |> Enum.map(&restore_sentence_abbreviation_periods/1)

        citation_index = Enum.find_index(sentences, &contains_paper_ref?(&1, paper_ref))

        candidate =
          if is_integer(citation_index) do
            sentences
            |> Enum.drop(citation_index + 1)
            |> Enum.take_while(&(not contains_any_paper_ref?(&1)))
            |> Enum.find(&followup_reported_sentence?(&1))
          end

        candidate || summary
    end
  end

  defp prefer_followup_reported_sentence(summary), do: summary

  defp first_citation_sentence(summary) do
    case extract_paper_ref(summary) do
      nil ->
        summary

      paper_ref ->
        sentences =
          summary
          |> protect_sentence_abbreviation_periods()
          |> then(&Regex.split(~r/(?<=[.!?])\s+/, &1, trim: true))
          |> Enum.map(&restore_sentence_abbreviation_periods/1)

        sentence_index = Enum.find_index(sentences, &contains_paper_ref?(&1, paper_ref))

        case sentence_index do
          nil ->
            summary

          index ->
            sentence = Enum.at(sentences, index, summary)
            previous = if index > 0, do: Enum.at(sentences, index - 1), else: nil

            cond do
              citation_sentence_is_ref_only?(sentence, paper_ref) and is_binary(previous) ->
                previous

              true ->
                preceding_quoted_context(previous, sentence, paper_ref) || sentence
            end
        end
    end
  end

  defp contains_paper_ref?(summary, paper_ref) when is_integer(paper_ref) do
    Regex.match?(~r/(?:\[Paper\s+#{paper_ref}\]|\bPaper\s+#{paper_ref}\b)/i, summary)
  end

  defp preceding_quoted_context(previous, citation_sentence, paper_ref)
       when is_binary(previous) and is_binary(citation_sentence) do
    cond do
      contains_paper_ref?(previous, paper_ref) ->
        nil

      contains_any_paper_ref?(previous) ->
        nil

      not citation_sentence_reports_paper?(citation_sentence, paper_ref) ->
        nil

      true ->
        case Regex.run(~r/["“]([^"”]+)["”]/u, previous, capture: :all_but_first) do
          [quoted] ->
            ~s("#{String.trim(quoted)}")

          _ ->
            nil
        end
    end
  end

  defp preceding_quoted_context(_, _, _), do: nil

  defp contains_any_paper_ref?(summary) when is_binary(summary) do
    Regex.match?(~r/(?:\[Paper\s+\d+\]|\bPaper\s+\d+\b)/i, summary)
  end

  defp citation_sentence_reports_paper?(sentence, paper_ref) when is_binary(sentence) do
    Regex.match?(
      ~r/^\s*(?:\[Paper\s+#{paper_ref}\]|\bPaper\s+#{paper_ref}\b)\s+(?:(?:explicitly|clearly|directly|specifically)\s+)?(?:#{reporting_verbs_pattern()})\b/iu,
      sentence
    )
  end

  defp citation_sentence_is_ref_only?(sentence, paper_ref) when is_binary(sentence) do
    Regex.match?(
      ~r/^\s*(?:[\[(])?\s*Paper\s+#{paper_ref}\s*(?:[\])])?\s*[.?!:;,-]*\s*$/iu,
      sentence
    )
  end

  defp protect_sentence_abbreviation_periods(summary) do
    summary
    |> String.replace("...", "__VAOS_ELLIPSIS__")
    |> String.replace("…", "__VAOS_ELLIPSIS__")
    |> String.replace(~r/\bvs\./iu, "vs__VAOS_DOT__")
    |> String.replace(~r/\be\.g\./iu, "e__VAOS_DOT__g__VAOS_DOT__")
    |> String.replace(~r/\bi\.e\./iu, "i__VAOS_DOT__e__VAOS_DOT__")
    |> String.replace(~r/\bet al\./iu, "et al__VAOS_DOT__")
  end

  defp restore_sentence_abbreviation_periods(summary) do
    summary
    |> String.replace("__VAOS_DOT__", ".")
    |> String.replace("__VAOS_ELLIPSIS__", "...")
  end

  defp trim_after_other_paper_ref(summary) do
    case extract_paper_ref(summary) do
      nil ->
        summary

      current_ref ->
        case Enum.find(paper_ref_mentions(summary), &(&1.ref != current_ref)) do
          nil ->
            summary

          %{start: start} ->
            summary
            |> String.slice(0, start)
            |> String.replace(~r/(?:\s|[,;:()-])*(?:and|but|while|whereas)\s*$/iu, "")
            |> String.trim()
        end
    end
  end

  defp paper_ref_mentions(summary) when is_binary(summary) do
    regex = ~r/\[Paper\s+\d+\]|\bPaper\s+\d+\b/i

    Regex.scan(regex, summary)
    |> Enum.zip(Regex.scan(regex, summary, return: :index))
    |> Enum.map(fn {[match], [{start, _length}]} ->
      %{ref: extract_paper_ref(match), start: start}
    end)
  end

  defp trim_after_last_quote(summary) do
    quote_indexes =
      summary
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.filter(fn {char, _index} -> char == "\"" end)

    case quote_indexes do
      [] ->
        summary

      indexes when rem(length(indexes), 2) == 1 ->
        summary

      _ ->
        {_quote, last_index} = List.last(quote_indexes)

        if last_index < String.length(summary) - 1 do
          String.slice(summary, 0, last_index + 1)
        else
          summary
        end
    end
  end

  defp strip_verification_markup(summary) do
    summary
    |> String.replace(~r/\[Paper\s+\d+\]/i, "")
    |> String.replace(~r/[*_`]+/, "")
    |> String.replace(~r/\bAccording to\s*,/i, "According to")
    |> String.replace(~r/\s+([,.;:!?])/, "\\1")
    |> String.replace(~r/\(\s+/, "(")
    |> String.replace(~r/\s+\)/, ")")
    |> normalize_verification_whitespace()
  end

  defp strip_leading_attribution_clause(summary) do
    summary
    |> String.replace(~r/^\s*According to(?:\s+Paper\s+\d+)?\s*,?\s*/iu, "")
    |> normalize_verification_whitespace()
  end

  defp strip_leading_reporting_clause(summary) do
    lead_in =
      ~r/^\s*(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\s+/iu

    summary
    |> String.replace(
      ~r/^\s*(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\s+that\s*,?\s+/iu,
      ""
    )
    |> String.replace(lead_in, "")
    |> String.replace(~r/^\s*,\s*/, "")
    |> String.replace(~r/^\s*how\s+/iu, "")
    |> normalize_verification_whitespace()
  end

  defp rewrite_reporting_fragments(summary) do
    case Regex.run(~r/^\s*([^,.;:]+?)\s+as\s+involving\s+(.+)$/iu, summary) do
      [_, subject, rest] ->
        "#{subject} involves #{rest}"

      _ ->
        summary
    end
    |> normalize_verification_whitespace()
  end

  defp prefer_reported_subclause(summary) do
    case Regex.run(
           ~r/["”]?\s*,?\s*(?:noting|showing|finding|demonstrating|indicating|observing)\s+that\s+(.+)/iu,
           summary
         ) do
      [_, clause] ->
        clause = String.trim(clause)

        if String.contains?(clause, "\"") do
          clause
        else
          summary
        end

      _ ->
        summary
    end
    |> normalize_verification_whitespace()
  end

  defp strip_subject_reporting_clause(summary) when is_binary(summary) do
    summary
    |> String.replace(
      ~r/^\s*(?:[A-Z][^.;:"]{0,180}?)\s+(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\s+that\s+/u,
      ""
    )
    |> normalize_verification_whitespace()
  end

  defp strip_abstract_reporting_subject(summary) when is_binary(summary) do
    summary
    |> String.replace(
      ~r/^\s*(?:the\s+)?(?:abstract|paper|study|article)\s+(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\s+/iu,
      ""
    )
    |> String.replace(~r/^\s*how\s+/iu, "")
    |> normalize_verification_whitespace()
  end

  defp trim_trailing_inference_clause(summary) when is_binary(summary) do
    if String.contains?(summary, "\"") or String.contains?(summary, "“") do
      normalize_verification_whitespace(summary)
    else
      summary
      |> String.replace(
        ~r/,\s*(?:demonstrating|showing|meaning|indicating|implying|which\s+means|which\s+shows)\s+that\s+.+$/iu,
        ""
      )
      |> String.replace(
        ~r/\s*[—-]\s*(?:explicitly|meaning|indicating|showing|demonstrating).+$/iu,
        ""
      )
      |> normalize_verification_whitespace()
    end
  end

  defp strip_leading_context_clause(summary) when is_binary(summary) do
    case Regex.run(
           ~r/^\s*(?:under|within|using|with|according\s+to|based\s+on|in)\b[^,]{0,120},\s*(.+)$/iu,
           summary,
           capture: :all_but_first
         ) do
      [remainder] ->
        normalize_verification_whitespace(remainder)

      _ ->
        summary
    end
  end

  defp prefer_complete_quote_after_ellipsis(summary) when is_binary(summary) do
    quotes =
      Regex.scan(~r/["“]([^"”]+)["”]/u, summary, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim/1)

    case quotes do
      [first, second | _rest] ->
        cond do
          String.contains?(first, "...") and second != "" ->
            ~s("#{second}")

          true ->
            summary
        end

      _ ->
        summary
    end
  end

  defp strip_drawback_wrapper_before_quote(summary) when is_binary(summary) do
    case Regex.run(
           ~r/^\s*[^"“]*?\bsuffer(?:s|ed)?\s+from\s+(?:the\s+)?drawback\s+that\s+["“]([^"”]+)["”]/iu,
           summary
         ) do
      [_, quoted] ->
        ~s("#{String.trim(quoted)}")

      _ ->
        summary
    end
  end

  defp reporting_verbs_pattern do
    "present|presents|presented|define|defines|defined|describes|documents|notes|explains|reports|reported|finds|found|shows|showed|demonstrates|demonstrated|discusses|states|stated|establishes|established|derives|derived|argues|argued|observes|observed|indicates|indicated|identifies|identified|mentions|mentioned|writes|wrote|proposes|proposed|details|detailed"
  end

  defp prefer_quote_after_inline_paper_definition(summary) when is_binary(summary) do
    case extract_paper_ref(summary) do
      nil ->
        summary

      paper_ref ->
        case Regex.run(
               ~r/^(.*?)((?:\[Paper\s+#{paper_ref}\]|\bPaper\s+#{paper_ref}\b)[^"“”]{0,220}?\b(?:states?|defines?)\b[^"“”]{0,160}?["“]([^"”]+)["”])/iu,
               summary,
               capture: :all_but_first
             ) do
          [before_paper, _clause, quoted] ->
            if String.contains?(before_paper, "\"") or String.contains?(before_paper, "“") do
              ~s("#{String.trim(quoted)}")
            else
              summary
            end

          _ ->
            summary
        end
    end
  end

  defp prefer_definition_quote(summary) when is_binary(summary) do
    case Regex.run(~r/^(.*?)["“]([^"”]+)["”]?(.*)$/u, summary) do
      [_, before_quote, quoted, _after_quote] ->
        before_quote = normalize_verification_whitespace(before_quote)
        quoted = String.trim(quoted)

        if quoted != "" and
             Regex.match?(
               ~r/\bas\s+(?:the\s+)?(?:science|study|discipline|field|process|method|framework|system)\b/iu,
               before_quote
             ) do
          quoted
        else
          summary
        end

      _ ->
        summary
    end
  end

  defp prefer_quote_before_followup_reporting(summary) when is_binary(summary) do
    case Regex.run(~r/^(.*?)["“]([^"”]+)["”](.*)$/u, summary) do
      [_, _before_quote, quoted, after_quote] ->
        if quoted != "" and
             Regex.match?(
               ~r/^\s*(?:\[Paper\s+\d+\]|\bPaper\s+\d+\b)\s+(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\b/iu,
               String.trim_leading(after_quote)
             ) do
          ~s("#{quoted}")
        else
          summary
        end

      _ ->
        summary
    end
  end

  defp prefer_subject_plus_quoted_predicate(summary) do
    case Regex.run(~r/^(.*?)["“]([^"”]+)["”]?(.*)$/u, summary) do
      [_, before_quote, quoted, _after_quote] ->
        subject =
          before_quote
          |> String.split(~r/,\s*/)
          |> List.last()
          |> to_string()
          |> String.replace(~r/\b(?:and\s+that|that)\s*$/iu, "")
          |> String.trim()

        quoted = String.trim(quoted)

        if (quoted_predicate?(quoted) or subject_completes_quoted_fragment?(subject, quoted)) and
             subject != "" do
          "#{subject} #{quoted}"
          |> normalize_verification_whitespace()
        else
          summary
        end

      _ ->
        summary
    end
  end

  defp quoted_predicate?(quoted) when is_binary(quoted) do
    Regex.match?(
      ~r/^(?:ought|is|are|was|were|has|have|had|can|could|will|would|should|must|may|might|does|do|did)\b/iu,
      String.trim_leading(quoted)
    )
  end

  defp subject_completes_quoted_fragment?(subject, quoted)
       when is_binary(subject) and is_binary(quoted) do
    Regex.match?(
      ~r/\b(?:is|are|was|were|be|been|being|can|could|will|would|should|must|may|might)\s*$/iu,
      String.trim(subject)
    ) and
      Regex.match?(~r/^(?:of|to|for|from|that|how|why|whether|where|when|which)\b/iu, quoted)
  end

  defp followup_reported_sentence?(sentence) when is_binary(sentence) do
    Regex.match?(
      ~r/^\s*(?:the\s+)?(?:abstract|paper|study|article)\s+(?:(?:explicitly|clearly|directly|specifically|\w+ly)\s+)?(?:#{reporting_verbs_pattern()})\b/iu,
      sentence
    )
  end

  defp adversarial_output_contract do
    """
    Output contract:
    - Return ONLY a numbered list with 3-5 items. No headings, no preamble, no conclusion.
    - Use exactly this shape for every item: `1. [SOURCED] (strength: 8) ...` or `1. [REASONING] (strength: 3) ...`
    - Every `[SOURCED]` item MUST include a specific citation like `[Paper 2]`. If you cannot cite a paper, use `[REASONING]` instead.
    - In the cited sentence, lead with the paper's directly supported claim or quote. Move your interpretation to a following sentence or mark it as `[REASONING]`.
    - If the side is weak, still provide the strongest available arguments in the required format with lower strengths.
    - Do not say that you cannot make the case. Just output the best structured arguments available.
    """
  end

  defp paper_details(all_papers) do
    Enum.map(all_papers, fn p ->
      %{
        title: p["title"],
        year: p["year"],
        citations: p["citation_count"] || p["citationCount"] || 0,
        source: p["source"] || "unknown",
        abstract: String.slice(to_string(p["abstract"] || ""), 0, 500)
      }
    end)
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp map_value(payload, key) when is_map(payload) do
    cond do
      Map.has_key?(payload, key) -> Map.get(payload, key)
      Map.has_key?(payload, Atom.to_string(key)) -> Map.get(payload, Atom.to_string(key))
      true -> nil
    end
  end

  defp map_value(_, _), do: nil

  defp stringify_term(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_term(value), do: value

  defp investigation_branch(topic) do
    "investigate:" <> short_hash(topic)
  end

  @doc false
  def preferred_utility_model do
    Application.get_env(:daemon, :utility_model) ||
      ModelSelection.current_model() ||
      utility_tier_model(ModelSelection.current_provider())
  end

  @doc false
  def preferred_verification_model do
    provider = ModelSelection.current_provider()

    Application.get_env(:daemon, :investigate_verification_model) ||
      Application.get_env(:daemon, :utility_model) ||
      utility_tier_model(provider) ||
      ModelSelection.current_model(provider)
  end

  @doc false
  def verification_request_opts(model \\ preferred_verification_model()) do
    max_tokens =
      case Application.get_env(:daemon, :investigate_verify_max_tokens) do
        value when is_integer(value) and value > 0 ->
          value

        _ ->
          default_verification_max_tokens(model, ModelSelection.current_provider())
      end

    opts = [temperature: 0.0, max_tokens: max_tokens]
    if model, do: Keyword.put(opts, :model, model), else: opts
  end

  @doc false
  def parse_verification_response(response) when is_binary(response) do
    response_clean = String.trim(response) |> String.upcase()

    verification =
      response_clean
      |> extract_keyword(
        [
          ~r/ANSWER\s+SHOULD\s+BE\s+["“]?(UNVERIFIED|PARTIAL|VERIFIED)\b/u,
          ~r/CLASSIF(?:Y|IES|IED)(?:\s+IT)?\s+AS\s+["“]?(UNVERIFIED|PARTIAL|VERIFIED)\b/u
        ],
        ~w(UNVERIFIED PARTIAL VERIFIED)
      )
      |> normalize_verification_keyword(response_clean)

    paper_type =
      response_clean
      |> extract_keyword(
        [
          ~r/FALLS\s+UNDER\s+["“]?(REVIEW|TRIAL|STUDY|OTHER)\b/u,
          ~r/TYPE(?:\s+SHOULD\s+BE|\s+IS)?\s+["“]?(REVIEW|TRIAL|STUDY|OTHER)\b/u,
          ~r/CLASSIF(?:Y|IES|IED)(?:\s+IT)?\s+AS\s+["“]?(REVIEW|TRIAL|STUDY|OTHER)\b/u
        ],
        ~w(REVIEW TRIAL STUDY OTHER)
      )
      |> normalize_paper_type_keyword(response_clean)

    {verification, paper_type}
  end

  def parse_verification_response(_), do: {:unverified, :other}

  defp utility_tier_model(provider) when is_atom(provider) do
    try do
      Daemon.Agent.Tier.model_for(:utility, provider)
    rescue
      _ -> nil
    end
  end

  defp utility_tier_model(_), do: nil

  defp default_verification_max_tokens(model, provider) do
    if provider == :zhipu and is_binary(model) and
         String.starts_with?(String.downcase(model), "glm-") do
      256
    else
      64
    end
  end

  defp verification_system_prompt do
    """
    You are a strict citation-verification classifier.
    Reply with the classification on the first line using exactly two uppercase words.
    First word must be VERIFIED, PARTIAL, or UNVERIFIED.
    Second word must be REVIEW, TRIAL, STUDY, or OTHER.
    Judge ONLY whether the abstract text states or supports the claim.
    Do NOT require the full paper or methods to classify a claim as VERIFIED.
    Do not put analysis before the first line.
    """
  end

  defp normalize_verification_keyword(keyword, response_clean) do
    case keyword do
      "UNVERIFIED" ->
        if abstract_support_overrides_unverified?(response_clean),
          do: :verified,
          else: :unverified

      "PARTIAL" ->
        :partial

      "VERIFIED" ->
        :verified

      _ ->
        infer_verification_from_reasoning(response_clean)
    end
  end

  defp normalize_paper_type_keyword("REVIEW", _response_clean), do: :review
  defp normalize_paper_type_keyword("TRIAL", _response_clean), do: :trial
  defp normalize_paper_type_keyword("STUDY", _response_clean), do: :study
  defp normalize_paper_type_keyword("OTHER", _response_clean), do: :other

  defp normalize_paper_type_keyword(_missing, response_clean),
    do: infer_paper_type_from_reasoning(response_clean)

  defp infer_verification_from_reasoning(response_clean) when is_binary(response_clean) do
    cond do
      Regex.match?(
        ~r/\b(?:DOES\s+NOT|DOESN'T|NOT)\s+(?:DIRECTLY\s+)?SUPPORT\b|\bNOT\s+SPECIFICALLY\b|\bONLY\s+UNDER\b|\bDEPENDS\s+ON\b/u,
        response_clean
      ) ->
        :unverified

      Regex.match?(
        ~r/\bPARTIALLY\b|\bSUPPORTS\s+PART\b|\bSUPPORTS\s+SOME\b|\bGENERAL\s+CONNECTION\b/u,
        response_clean
      ) ->
        :partial

      Regex.match?(
        ~r/\bDIRECTLY\s+SUPPORTS(?:\s+THE\s+CLAIM)?\b|\bDIRECTLY\s+STATE[SD]?(?:\s+THIS\s+CLAIM|\s+THE\s+CLAIM)?\b|\bEXPLICITLY\s+STATE[SD]?\b|\bFULLY\s+SUPPORT(?:ED|S)\b|\bMATCHES\s+THE\s+CLAIM\b|\bMATCHES\s+ALMOST\s+WORD[-\s]?FOR[-\s]?WORD\b|\bWORD[-\s]?FOR[-\s]?WORD\b|\bAPPEARS\s+TO\s+BE\s+DIRECTLY\s+STATED\b|\b(?:CLEARLY|EXPLICITLY)\s+IDENTIF(?:IES|IED|YING)\b|\bDOES\s+INDEED\s+EXPLICITLY\s+IDENTIFY\b|\bEXACTLY\s+THE\b.+\bMENTIONED\s+IN\s+THE\s+CLAIM\b/u,
        response_clean
      ) ->
        :verified

      true ->
        :unverified
    end
  end

  defp abstract_support_overrides_unverified?(response_clean) when is_binary(response_clean) do
    abstract_support? =
      Regex.match?(
        ~r/\b(?:THE\s+ABSTRACT|THE\s+PAPER|SO\s+THE\s+PAPER)\s+DIRECTLY\s+(?:STATE[SD]?|SUPPORTS?)\s+(?:THIS\s+CLAIM|THE\s+CLAIM)\b|\bTHE\s+PAPER\s+DIRECTLY\s+STATES\s+THIS\s+CLAIM\s+IN\s+ITS\s+ABSTRACT\b|\bTHE\s+ABSTRACT\s+CLEARLY\s+IDENTIF(?:IES|Y)\b/u,
        response_clean
      )

    abstract_scope_hedge? =
      Regex.match?(
        ~r/\bONLY\s+(?:HAVE\s+ACCESS\s+TO|HAVE)\s+THE\s+ABSTRACT\b|\bONLY\s+THE\s+ABSTRACT\b|\bCANNOT\s+VERIFY\b.{0,120}\b(?:METHODS?|FULL\s+PAPER|RIGOROUSLY\s+JUSTIFY)\b|\bHAVE\s+NOT\s+READ\s+THE\s+FULL\s+PAPER\b/u,
        response_clean
      )

    abstract_support? and abstract_scope_hedge?
  end

  defp abstract_support_overrides_unverified?(_response_clean), do: false

  defp infer_paper_type_from_reasoning(response_clean) when is_binary(response_clean) do
    cond do
      Regex.match?(
        ~r/\bSYSTEMATIC\s+REVIEW\b|\bMETA[\s-]?ANALYSIS\b|\bREVIEW\s+ARTICLE\b/u,
        response_clean
      ) ->
        :review

      Regex.match?(~r/\bRANDOMI[ZS]ED\b|\bTRIAL\b|\bEXPERIMENT\b/u, response_clean) ->
        :trial

      Regex.match?(~r/\bOBSERVATIONAL\b|\bSINGLE\s+STUDY\b|\bSTUDY\b/u, response_clean) ->
        :study

      true ->
        :other
    end
  end

  defp last_keyword(text, keywords) when is_binary(text) and is_list(keywords) do
    pattern =
      keywords
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")
      |> then(&~r/\b(?:#{&1})\b/u)

    case Regex.scan(pattern, text) do
      [] -> nil
      matches -> matches |> List.last() |> List.first()
    end
  end

  defp last_quoted_keyword(text, keywords) when is_binary(text) and is_list(keywords) do
    pattern =
      keywords
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")
      |> then(&~r/["“](#{&1})["”]?/u)

    case Regex.scan(pattern, text) do
      [] -> nil
      matches -> matches |> List.last() |> List.last()
    end
  end

  defp extract_keyword(text, patterns, keywords) when is_binary(text) do
    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [_, keyword] -> keyword
        _ -> nil
      end
    end) || last_quoted_keyword(text, keywords) || last_keyword(text, keywords)
  end

  defp parse_adversarial_response(response, side) do
    evidence = parse_adversarial_evidence(response)

    if evidence == [] do
      preview =
        response
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 240)

      Logger.warning(
        "[investigate] #{side}-side adversarial response was unparseable: #{preview}"
      )
    end

    evidence
  end

  defp short_hash(topic) do
    Base.encode16(:crypto.hash(:sha256, topic), case: :lower) |> String.slice(0, 16)
  end

  defp ensure_ledger_started do
    case Process.whereis(@ledger_name) do
      nil ->
        case EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name) do
          {:ok, _pid} -> :ok
          # Another process started it between whereis and start_link
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  # ── Emergent Question Synthesis ────────────────────────────────────
  # After each investigation, ask the LLM to identify 1-2 genuinely novel
  # research questions that emerge from the TENSION between evidence.
  # These questions don't exist in the ledger — they're forward-looking.

  @doc false
  def verify_citation_pairs(supporting_raw, opposing_raw, paper_map, prompts, verify_fun \\ nil)

  def verify_citation_pairs(supporting_raw, opposing_raw, paper_map, prompts, nil) do
    verify_citation_pairs(supporting_raw, opposing_raw, paper_map, prompts, &verify_citations/3)
  end

  def verify_citation_pairs(supporting_raw, opposing_raw, paper_map, prompts, verify_fun)
      when is_function(verify_fun, 3) do
    # Keep each side's verifier semantics unchanged, but overlap the two independent passes.
    supporting_task = Task.async(fn -> verify_fun.(supporting_raw, paper_map, prompts) end)
    opposing_task = Task.async(fn -> verify_fun.(opposing_raw, paper_map, prompts) end)

    {
      Task.await(supporting_task, :infinity),
      Task.await(opposing_task, :infinity)
    }
  end

  @doc false
  def emergent_question_generation_enabled?(direction, supporting, opposing, uncertainty)
      when is_list(supporting) and is_list(opposing) do
    supporting != [] and opposing != [] and
      ((is_binary(direction) and direction in @emergent_question_contested_directions) or
         (is_number(uncertainty) and uncertainty > @high_uncertainty_threshold))
  end

  def emergent_question_generation_enabled?(_, _, _, _), do: false

  defp extract_emergent_questions(topic, direction, supporting, opposing, uncertainty) do
    if emergent_question_generation_enabled?(direction, supporting, opposing, uncertainty) do
      uncertainty_value = if is_number(uncertainty), do: uncertainty * 1.0, else: 1.0

      for_summaries =
        supporting
        |> Enum.take(3)
        |> Enum.map(fn ev -> "- FOR: #{ev.summary}" end)
        |> Enum.join("\n")

      against_summaries =
        opposing
        |> Enum.take(3)
        |> Enum.map(fn ev -> "- AGAINST: #{ev.summary}" end)
        |> Enum.join("\n")

      prompt = """
      You just completed an investigation on: "#{topic}"

      Direction: #{direction} (uncertainty: #{Float.round(uncertainty_value, 2)})

      Key evidence FOR:
      #{for_summaries}

      Key evidence AGAINST:
      #{against_summaries}

      Based on the TENSION between these findings, generate exactly 2 novel research questions that:
      1. Are NOT the same as the original topic
      2. Emerge from contradictions, gaps, or surprising connections in the evidence
      3. Would advance understanding of the broader field
      4. Are specific and investigable (not vague)

      Respond with ONLY a JSON array of objects, nothing else:
      [{"title": "question text", "reason": "why this emerges from the evidence tension"}]
      """

      messages = [
        %{
          role: "system",
          content: "You are a research question generator. Output ONLY valid JSON."
        },
        %{role: "user", content: prompt}
      ]

      model = preferred_utility_model()
      opts = [temperature: 0.7, max_tokens: 1024]
      opts = if model, do: Keyword.put(opts, :model, model), else: opts

      case Providers.chat(messages, opts) do
        {:ok, %{content: response}} when is_binary(response) and response != "" ->
          parse_emergent_questions(response)

        _ ->
          Logger.debug("[investigate] Emergent question extraction failed or empty")
          []
      end
    else
      Logger.debug(
        "[investigate] Skipping emergent question extraction due to low evidence tension"
      )

      []
    end
  rescue
    e ->
      Logger.warning("[investigate] Emergent question extraction error: #{Exception.message(e)}")
      []
  catch
    :exit, _ -> []
  end

  defp parse_emergent_questions(response) do
    # Strip markdown code fences if present
    cleaned =
      response
      |> String.replace(~r/^```json?\s*/m, "")
      |> String.replace(~r/```\s*$/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, questions} when is_list(questions) ->
        questions
        |> Enum.take(2)
        |> Enum.map(fn q ->
          %{
            title: Map.get(q, "title", ""),
            reason: Map.get(q, "reason", ""),
            information_gain: 0.90
          }
        end)
        |> Enum.reject(fn q -> q.title == "" end)

      _ ->
        Logger.debug(
          "[investigate] Failed to parse emergent questions JSON: #{String.slice(cleaned, 0, 200)}"
        )

        []
    end
  rescue
    _ -> []
  end

  defp store_ref, do: "osa_default"

  defp ensure_store_started do
    case Vaos.Knowledge.open("osa_default") do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.error("[investigate] Failed to start knowledge store: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
