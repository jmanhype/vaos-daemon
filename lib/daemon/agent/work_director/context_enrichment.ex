defmodule Daemon.Agent.WorkDirector.ContextEnrichment do
  @moduledoc """
  Stage 0.5: Context enrichment for WorkDirector dispatches.
  
  Extracted from Pipeline module to separate concerns. This module builds
  the pre-research context that gets injected into the implementation prompt.
  """
  
  require Logger
  
  alias Daemon.Agent.WorkDirector.Backlog.WorkItem
  alias Daemon.Agent.WorkDirector.DispatchIntelligence
  alias Daemon.Vault
  alias Daemon.Agent.Appraiser
  alias Daemon.Agent.Roster
  alias Daemon.Agent.CodeIntrospector
  alias Daemon.Agent.ActiveLearner

  # -- Feature Flags (runtime config via Application.get_env(:daemon, :work_director_flags, %{})) --
  @enable_vault_context true
  @enable_knowledge_context true
  @enable_investigation_pre true
  @enable_appraiser true
  @enable_specialist_routing true
  @enable_introspector_feed true
  @enable_impact_analysis true
  @enable_production_context true

  # Helper to get flags from runtime config
  defp get_flag(flag_name, default) do
    Application.get_env(:daemon, :work_director_flags, %{})
    |> Map.get(flag_name, default)
  end

  @doc """
  Build the complete pre-research context for a dispatch.
  
  Returns a string containing all enabled context sections.
  """
  def build(item, repo_path, session_id) do
    sections = []

    # Failure context from prior attempts (Reflexion)
    sections = sections ++ failure_context_section(item)

    # Vault: prior dispatch memories
    sections = sections ++ vault_context_section(item)

    # Knowledge Store: codebase patterns
    sections = sections ++ knowledge_context_section(item)

    # Appraiser: complexity estimate
    sections = sections ++ appraiser_section(item)

    # Specialist hints: what agents match this task
    sections = sections ++ specialist_hints_section(item)

    # Autonomous loop insights: CodeIntrospector + ActiveLearner findings
    sections = sections ++ introspector_section(item)

    # Impact analysis: reverse dependency tracing
    sections = sections ++ impact_analysis_section(item, repo_path)

    # Production context: telemetry + provider health
    sections = sections ++ production_context_section()

    # Investigation: deep research (expensive, only for high-priority/complex tasks)
    sections = sections ++ investigation_section(item, session_id)

    # Dispatch judgment context (Phase 2): confidence, PR conflicts, hot zones
    sections = sections ++ judgment_context_section()

    context = Enum.join(sections, "\n")

    if context != "" do
      Logger.info("[ContextEnrichment] Pre-research enriched prompt (#{String.length(context)} chars)")
    end

    context
  end

  defp failure_context_section(%WorkItem{attempt_count: 0}), do: []
  defp failure_context_section(%WorkItem{last_failure_class: nil}), do: []
  defp failure_context_section(%WorkItem{attempt_count: n, last_failure_class: class, last_failure_reason: reason}) do
    ["""
    ## WARNING: Previous Attempt Failed (attempt #{n} of 3)
    Failure type: #{class}
    Reason: #{String.slice(inspect(reason), 0, 500)}

    DO NOT repeat the same approach. Address the specific failure above.
    """]
  end

  defp vault_context_section(item) do
    if get_flag(:enable_vault_context, @enable_vault_context) do
      try do
        recalls = Vault.recall(item.title, limit: 5)

        if recalls != [] do
          formatted =
            Enum.map_join(recalls, "\n", fn {cat, path, _score} ->
              case File.read(path) do
                {:ok, content} ->
                  body = content |> String.split("\n") |> Enum.take(8) |> Enum.join("\n")
                  "- [#{cat}] #{String.slice(body, 0, 300)}"

                _ ->
                  ""
              end
            end)

          Logger.info("[ContextEnrichment] Injecting #{length(recalls)} vault memories")
          ["\n## Prior Context (learn from previous attempts)\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp knowledge_context_section(item) do
    if get_flag(:enable_knowledge_context, @enable_knowledge_context) do
      try do
        store = "osa_default"
        keywords = item.title |> String.split(~r/\s+/) |> Enum.take(5)

        triples =
          Enum.flat_map(keywords, fn kw ->
            case Vaos.Knowledge.query(store, subject: kw) do
              {:ok, results} -> Enum.take(results, 3)
              _ -> []
            end
          end)
          |> Enum.uniq()
          |> Enum.take(10)

        if triples != [] do
          formatted =
            Enum.map_join(triples, "\n", fn {s, p, o} ->
              "- #{s} —[#{p}]→ #{o}"
            end)

          Logger.info("[ContextEnrichment] #{length(triples)} knowledge triples")
          ["\n## Codebase Knowledge\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp appraiser_section(item) do
    if get_flag(:enable_appraiser, @enable_appraiser) do
      try do
        complexity =
          cond do
            String.length(item.description || "") > 500 -> 7
            String.length(item.description || "") > 200 -> 5
            true -> 3
          end

        estimate = Appraiser.estimate(complexity, :backend)

        section = """

        ## Task Estimate
        - Complexity: #{estimate.complexity}/10
        - Estimated hours: #{estimate.estimated_hours}
        - Confidence: #{Float.round(estimate.confidence * 100, 0)}%
        - Scale: #{if estimate.estimated_hours > 8, do: "LARGE — break into smaller pieces", else: "manageable"}
        """

        Logger.info("[ContextEnrichment] Appraiser estimates #{estimate.estimated_hours}h")
        [section]
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp specialist_hints_section(item) do
    if get_flag(:enable_specialist_routing, @enable_specialist_routing) do
      try do
        scored = Roster.select_for_task_scored(item.title)
        top = Enum.take(scored, 3)

        if top != [] do
          formatted =
            Enum.map_join(top, "\n", fn {name, score} ->
              "- #{name} (score: #{Float.round(score, 2)})"
            end)

          Logger.info("[ContextEnrichment] Top specialists: #{inspect(Enum.map(top, &elem(&1, 0)))}")
          ["\n## Recommended Specialists\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp introspector_section(_item) do
    if get_flag(:enable_introspector_feed, @enable_introspector_feed) do
      try do
        sections = []

        sections =
          try do
            %{recent_findings: findings} = CodeIntrospector.stats()

            if findings != [] do
              formatted =
                findings
                |> Enum.take(3)
                |> Enum.map_join("\n", fn f ->
                  "- [#{f.anomaly_type}] #{inspect(f.result) |> String.slice(0, 200)}"
                end)

              sections ++ ["\n## Recent System Anomalies\n#{formatted}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        sections =
          try do
            %{bottleneck: bottleneck} = ActiveLearner.stats()

            if bottleneck do
              sections ++ ["\n## System Bottleneck: #{bottleneck.bottleneck}\n#{bottleneck.prescription}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        sections
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp investigation_section(item, session_id) do
    if get_flag(:enable_investigation_pre, @enable_investigation_pre) and item.base_priority >= 0.7 do
      try do
        Logger.info("[ContextEnrichment] Running pre-dispatch investigation for '#{item.title}'")
        investigate_tool = Daemon.Tools.Builtins.Investigate

        case investigate_tool.execute(%{
               "topic" => "How to implement: #{item.title}",
               "depth" => "standard",
               "metadata" => %{"source_module" => "WorkDirector", "session_id" => session_id}
             }) do
          {:ok, result} ->
            summary = result |> String.split("\n") |> Enum.take(30) |> Enum.join("\n")
            Logger.info("[ContextEnrichment] Investigation complete (#{String.length(result)} chars)")
            ["\n## Research Findings\n#{String.slice(summary, 0, 2000)}\n"]

          {:error, reason} ->
            Logger.warning("[ContextEnrichment] Investigation failed: #{reason}")
            []
        end
      rescue
        e ->
          Logger.warning("[ContextEnrichment] Investigation error: #{Exception.message(e)}")
          []
      catch
        :exit, r ->
          Logger.warning("[ContextEnrichment] Investigation exit: #{inspect(r)}")
          []
      end
    else
      []
    end
  end

  defp judgment_context_section do
    case Process.get(:dispatch_judgment_context) do
      %{confidence: confidence} = ctx ->
        pct = round((confidence[:score] || confidence.score) * 100)
        level = confidence[:level] || confidence.level

        confidence_text =
          if level == :medium do
            "## Dispatch Confidence: #{pct}%\nThis task has MEDIUM confidence. Pay extra attention to edge cases and test thoroughly."
          else
            "## Dispatch Confidence: #{pct}%"
          end

        pr_conflicts = ctx[:pr_conflicts] || %{}
        open_conflicts = pr_conflicts[:open_pr_conflicts] || []

        conflict_section =
          if open_conflicts != [] do
            conflict_lines =
              Enum.map_join(open_conflicts, "\n", fn c ->
                overlap = if c.overlapping_files != [], do: " (overlapping: #{Enum.join(c.overlapping_files, ", ")})", else: ""
                "- PR ##{c.number}: #{c.title} (similarity: #{Float.round(c.title_similarity, 2)})#{overlap}"
              end)

            ["\n## Active PR Conflicts\nThese open PRs may conflict with your changes:\n#{conflict_lines}\n"]
          else
            []
          end

        hot_zones = pr_conflicts[:hot_zones] || []

        hot_zone_section =
          if hot_zones != [] do
            zone_lines =
              Enum.map_join(hot_zones, "\n", fn hz ->
                "- `#{hz.file}` — modified by #{hz.modification_count} recent PRs"
              end)

            ["\n## Hot Zones\nThese files are frequently modified and may cause merge conflicts:\n#{zone_lines}\n"]
          else
            []
          end

        ["\n#{confidence_text}\n"] ++ conflict_section ++ hot_zone_section

      _ ->
        []
    end
  end

  defp impact_analysis_section(item, repo_path) do
    if get_flag(:enable_impact_analysis, @enable_impact_analysis) do
      try do
        enrichment = get_or_compute_enrichment(item, repo_path)
        file_paths = enrichment |> Map.get(:relevant_files, []) |> Enum.map(& &1.path) |> Enum.take(5)

        if file_paths == [] do
          []
        else
          impact = DispatchIntelligence.compute_impact(file_paths, repo_path)

          formatted =
            impact
            |> Enum.filter(fn {_path, deps} -> deps != [] end)
            |> Enum.map(fn {path, deps} ->
              rel_path = Path.relative_to(path, repo_path)
              dep_list = deps |> Enum.take(5) |> Enum.map(&Path.relative_to(&1, repo_path)) |> Enum.join(", ")
              "- `#{rel_path}` — #{length(deps)} dependents: #{dep_list}"
            end)
            |> Enum.join("\n")

          if formatted != "" do
            total_deps = impact |> Map.values() |> List.flatten() |> Enum.uniq() |> length()
            Logger.info("[ContextEnrichment] Impact analysis — #{total_deps} total dependents")
            ["\n## Impact Analysis (blast radius)\n#{formatted}\nTotal unique dependents: #{total_deps}\n"]
          else
            []
          end
        end
      rescue
        e ->
          Logger.warning("[ContextEnrichment] Impact analysis error: #{Exception.message(e)}")
          []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp production_context_section do
    if get_flag(:enable_production_context, @enable_production_context) do
      try do
        sections = []

        sections =
          try do
            summary = Daemon.Telemetry.Metrics.get_summary()

            provider_stats =
              (summary[:provider_calls] || %{})
              |> Enum.map(fn {provider, count} ->
                latency = get_in(summary, [:provider_latency, provider])
                avg = if latency, do: "avg=#{latency[:avg] || "?"}ms", else: ""
                p99 = if latency, do: "p99=#{latency[:p99] || "?"}ms", else: ""
                "- #{provider}: #{count} calls #{avg} #{p99}"
              end)
              |> Enum.join("\n")

            if provider_stats != "" do
              token_info = "Tokens used: #{summary[:token_stats][:total] || "unknown"}"
              sections ++ ["\n## Production Context\n#{provider_stats}\n#{token_info}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        sections =
          try do
            health_state = Daemon.Providers.HealthChecker.state()

            degraded =
              health_state
              |> Enum.filter(fn {_provider, state} -> state.circuit != :closed end)
              |> Enum.map(fn {provider, state} ->
                "- #{provider}: circuit=#{state.circuit}" <>
                  if(state[:rate_limited], do: " (rate limited)", else: "")
              end)

            if degraded != [] do
              sections ++ ["\n## Provider Health (degraded)\n#{Enum.join(degraded, "\n")}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        sections
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp get_or_compute_enrichment(item, repo_path) do
    case Process.get(:dispatch_intelligence_cache) do
      nil ->
        case DispatchIntelligence.enrich(item.title, item.description || "", repo_path) do
          {:ok, result} ->
            Process.put(:dispatch_intelligence_cache, result)
            result

          _ ->
            %{}
        end

      cached ->
        cached
    end
  end
end
