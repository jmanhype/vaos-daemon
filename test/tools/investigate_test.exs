defmodule Daemon.Tools.Builtins.InvestigateTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.Strategy
  alias Daemon.Tools.Builtins.Investigate

  defmodule TrialStub do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{responses: %{}, calls: []} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{responses: %{}, calls: []} end)
    end

    def expect(topic, response) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:responses, topic], response)
      end)
    end

    def consume_trial(topic) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.responses, topic, :none)

        next_state = %{
          state
          | responses: Map.delete(state.responses, topic),
            calls: [topic | state.calls]
        }

        {response, next_state}
      end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end
  end

  setup do
    keys = [
      :default_provider,
      :default_model,
      :utility_model,
      :investigate_verification_model,
      :investigate_verify_max_tokens
    ]

    original =
      Enum.into(keys, %{}, fn key ->
        {key, Application.get_env(:daemon, key, :__missing__)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, :__missing__} -> Application.delete_env(:daemon, key)
        {key, value} -> Application.put_env(:daemon, key, value)
      end)
    end)

    case Process.whereis(TrialStub) do
      nil -> start_supervised!(TrialStub)
      _pid -> TrialStub.reset()
    end

    :ok
  end

  test "preferred_verification_model prefers utility-tier model over default reasoning model" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.delete_env(:daemon, :utility_model)
    Application.delete_env(:daemon, :investigate_verification_model)

    assert Investigate.preferred_verification_model() == "glm-4.5-flash"
  end

  test "preferred_verification_model honors explicit override" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.put_env(:daemon, :utility_model, "glm-4.5-flash")
    Application.put_env(:daemon, :investigate_verification_model, "glm-custom-verify")

    assert Investigate.preferred_verification_model() == "glm-custom-verify"
  end

  test "merge_verification_stats aggregates counts and averages" do
    merged =
      Investigate.merge_verification_stats([
        %{
          total_items: 3,
          llm_items: 2,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 0,
          cache_hits: 1,
          cache_misses: 1,
          cache_lookup_ms: 4,
          llm_ms_total: 80,
          average_llm_ms: 80,
          slowest_llm_ms: 80,
          model: "glm-4.5-flash"
        },
        %{
          total_items: 4,
          llm_items: 3,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 1,
          cache_hits: 0,
          cache_misses: 2,
          cache_lookup_ms: 3,
          llm_ms_total: 100,
          average_llm_ms: 50,
          slowest_llm_ms: 60,
          model: "glm-4.5-flash"
        }
      ])

    assert merged.total_items == 7
    assert merged.llm_items == 5
    assert merged.no_llm_items == 2
    assert merged.unique_llm_items == 4
    assert merged.deduped_llm_items == 1
    assert merged.cache_hits == 1
    assert merged.cache_misses == 3
    assert merged.cache_lookup_ms == 7
    assert merged.llm_ms_total == 180
    assert merged.average_llm_ms == 60
    assert merged.slowest_llm_ms == 80
    assert merged.model == "glm-4.5-flash"
  end

  test "maybe_apply_pending_trial_steering consumes a pending trial when opted in" do
    TrialStub.expect(
      "manual pilot topic",
      {:ok, %{steering: "TRIAL STEERING: Treat this investigation as a pivot pass."}}
    )

    args =
      Investigate.maybe_apply_pending_trial_steering(
        %{
          "topic" => "manual pilot topic",
          "steering" => "BASE STEERING",
          "apply_pending_trial" => true
        },
        TrialStub
      )

    assert args["steering"] ==
             "BASE STEERING\n\nTRIAL STEERING: Treat this investigation as a pivot pass."

    assert TrialStub.calls() == ["manual pilot topic"]
  end

  test "maybe_apply_pending_trial_steering leaves args unchanged without opt-in" do
    TrialStub.expect(
      "manual pilot topic",
      {:ok, %{steering: "TRIAL STEERING: Treat this investigation as a pivot pass."}}
    )

    args =
      Investigate.maybe_apply_pending_trial_steering(
        %{
          "topic" => "manual pilot topic",
          "steering" => "BASE STEERING"
        },
        TrialStub
      )

    assert args["steering"] == "BASE STEERING"
    assert TrialStub.calls() == []
  end

  test "partial_completion_metadata preserves classified evidence for one-sided successes" do
    supporting = [
      %{
        summary: "Creatine improved task performance [Paper 1]",
        score: 2.4,
        verified: true,
        verification: "verified",
        paper_type: :review,
        citation_count: 24,
        strength: "strong",
        source_quality: 0.9,
        source_type: :sourced,
        evidence_store: :grounded
      },
      %{
        summary: "Mechanistic rationale without direct sourcing",
        score: 0.3,
        verified: false,
        verification: "no_citation",
        paper_type: :other,
        citation_count: 0,
        strength: "weak",
        source_quality: 0.1,
        source_type: :belief,
        evidence_store: :belief
      }
    ]

    timings = %{
      preflight_ms: 10,
      paper_search_ms: 20,
      citation_verification_ms: 30,
      post_processing_ms: 40,
      total_ms: 100
    }

    verification_stats = %{
      total_items: 2,
      llm_items: 1,
      no_llm_items: 1,
      unique_llm_items: 1,
      deduped_llm_items: 0,
      cache_hits: 0,
      cache_misses: 1,
      cache_lookup_ms: 2,
      llm_ms_total: 30,
      average_llm_ms: 30,
      slowest_llm_ms: 30,
      model: "glm-4.5-flash"
    }

    metadata =
      Investigate.partial_completion_metadata(
        "creatine helps cognition",
        supporting,
        [],
        [%{"title" => "Creatine Review", "year" => 2024, "citation_count" => 24}],
        %{semantic_scholar: 1},
        Strategy.default(),
        "variant-123",
        timings,
        verification_stats
      )

    assert metadata.partial == true
    assert metadata.direction == "partial_supporting_only"
    assert metadata.verified_for == 1
    assert metadata.reasoning_for == 1
    assert metadata.grounded_for_count == 1
    assert metadata.belief_for_count == 1
    assert metadata.investigation_id =~ "investigate:"
    assert metadata.phase_timings_ms == timings
    assert metadata.verification_stats == verification_stats
    assert metadata.evidence_quality.reviews == 1
    assert metadata.variant_id == "variant-123"

    assert [
             %{
               source_type: "sourced",
               evidence_store: "grounded",
               paper_type: "review"
             },
             %{
               source_type: "belief",
               evidence_store: "belief",
               paper_type: "other"
             }
           ] =
             Enum.map(
               metadata.supporting,
               &Map.take(&1, [:source_type, :evidence_store, :paper_type])
             )

    assert metadata.opposing == []
  end
end
