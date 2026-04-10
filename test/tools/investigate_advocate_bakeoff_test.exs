defmodule Daemon.Tools.InvestigateAdvocateBakeoffTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.InvestigateAdvocateBakeoff

  test "normalize_explicit_lanes ignores empty list values from task opts" do
    assert InvestigateAdvocateBakeoff.normalize_explicit_lanes(lane: []) == []

    assert InvestigateAdvocateBakeoff.normalize_explicit_lanes(
             lane: [],
             lane: ["openai:gpt-4o-mini", " ", "zhipu:glm-4.5-flash"]
           ) == ["openai:gpt-4o-mini", "zhipu:glm-4.5-flash"]
  end

  test "summarize_lane_result totals success, parse, source, and latency metrics" do
    summary =
      InvestigateAdvocateBakeoff.summarize_lane_result(%{
        lane: %{provider: :openai, model: "gpt-4o-mini", label: "openai:gpt-4o-mini"},
        for: %{status: "ok", elapsed_ms: 2_000, parsed_items: 4, sourced_items: 3},
        against: %{status: "error", elapsed_ms: 3_000, parsed_items: 0, sourced_items: 0}
      })

    assert summary.success_sides == 1
    assert summary.parsed_items == 4
    assert summary.sourced_items == 3
    assert summary.structured_sides == 1
    assert summary.total_latency_ms == 5_000
    assert summary.selection_score == 142
    assert summary.viable
  end

  test "pick_winner prefers reliable sourced output over lower latency" do
    slow_but_good =
      InvestigateAdvocateBakeoff.summarize_lane_result(%{
        lane: %{provider: :openai, model: "gpt-4o-mini", label: "openai:gpt-4o-mini"},
        for: %{status: "ok", elapsed_ms: 4_500, parsed_items: 4, sourced_items: 3},
        against: %{status: "ok", elapsed_ms: 4_200, parsed_items: 3, sourced_items: 2}
      })

    fast_but_empty =
      InvestigateAdvocateBakeoff.summarize_lane_result(%{
        lane: %{provider: :zhipu, model: "glm-4.5-flash", label: "zhipu:glm-4.5-flash"},
        for: %{status: "error", elapsed_ms: 1_000, parsed_items: 0, sourced_items: 0},
        against: %{status: "ok", elapsed_ms: 1_200, parsed_items: 1, sourced_items: 0}
      })

    assert InvestigateAdvocateBakeoff.pick_winner([fast_but_empty, slow_but_good]).lane.label ==
             "openai:gpt-4o-mini"
  end

  test "pick_winner returns nil when no lane produced usable output" do
    failed_lanes = [
      InvestigateAdvocateBakeoff.summarize_lane_result(%{
        lane: %{provider: :zhipu, model: "glm-4.5-flash", label: "zhipu:glm-4.5-flash"},
        for: %{status: "error", elapsed_ms: 7_000, parsed_items: 0, sourced_items: 0},
        against: %{status: "error", elapsed_ms: 7_100, parsed_items: 0, sourced_items: 0}
      }),
      InvestigateAdvocateBakeoff.summarize_lane_result(%{
        lane: %{
          provider: :google,
          model: "gemini-2.0-flash-lite",
          label: "google:gemini-2.0-flash-lite"
        },
        for: %{status: "empty", elapsed_ms: 300, parsed_items: 0, sourced_items: 0},
        against: %{status: "empty", elapsed_ms: 250, parsed_items: 0, sourced_items: 0}
      })
    ]

    refute Enum.any?(failed_lanes, & &1.viable)
    assert InvestigateAdvocateBakeoff.pick_winner(failed_lanes) == nil
  end
end
