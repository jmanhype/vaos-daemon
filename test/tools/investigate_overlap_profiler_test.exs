defmodule Daemon.Tools.InvestigateOverlapProfilerTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.InvestigateOverlapProfiler

  test "extract_metadata decodes embedded VAOS_JSON payload" do
    output = """
    ## Investigation

    <!-- VAOS_JSON:{"topic":"test topic","investigation_id":"investigate:test","verification_stats":{"cross_side_overlap_items":1}} -->
    """

    assert {:ok, metadata} = InvestigateOverlapProfiler.extract_metadata(output)
    assert metadata["topic"] == "test topic"
    assert metadata["verification_stats"]["cross_side_overlap_items"] == 1
  end

  test "extract_metadata recognizes investigation skip output without VAOS_JSON" do
    assert {:skip, "Investigation skipped — conflict: topic already active"} =
             InvestigateOverlapProfiler.extract_metadata(
               "Investigation skipped — conflict: topic already active"
             )
  end

  test "overlap_snapshot keeps overlap telemetry and normalized examples" do
    snapshot =
      InvestigateOverlapProfiler.overlap_snapshot(%{
        "topic" => "test topic",
        "investigation_id" => "investigate:test",
        "direction" => "genuinely_contested",
        "trace_path" => "/tmp/trace.json",
        "verification_stats" => %{
          "total_items" => 8,
          "llm_items" => 6,
          "cross_side_overlap_items" => 2,
          "cross_side_unique_llm_items" => 5,
          "cross_side_overlap_rate" => 0.4,
          "supporting_overlap_rate" => 0.5,
          "opposing_overlap_rate" => 0.667,
          "cross_side_overlap_examples" => [
            %{"paper_ref" => 3, "claim" => "shared claim", "summary" => "Quoted line"}
          ]
        }
      })

    assert snapshot.status == "ok"
    assert snapshot.topic == "test topic"
    assert snapshot.cross_side_overlap_items == 2
    assert snapshot.cross_side_unique_llm_items == 5
    assert snapshot.cross_side_overlap_rate == 0.4
    assert snapshot.supporting_overlap_rate == 0.5
    assert snapshot.opposing_overlap_rate == 0.667

    assert snapshot.cross_side_overlap_examples == [
             %{paper_ref: 3, claim: "shared claim", summary: "Quoted line"}
           ]
  end

  test "summarize aggregates overlap rates and repeated examples" do
    summary =
      InvestigateOverlapProfiler.summarize([
        %{
          status: "ok",
          topic: "topic one",
          cross_side_overlap_items: 0,
          cross_side_unique_llm_items: 8,
          cross_side_overlap_rate: 0.0,
          supporting_overlap_rate: 0.0,
          opposing_overlap_rate: 0.0,
          cross_side_overlap_examples: []
        },
        %{
          status: "ok",
          topic: "topic two",
          cross_side_overlap_items: 2,
          cross_side_unique_llm_items: 6,
          cross_side_overlap_rate: 0.333,
          supporting_overlap_rate: 0.5,
          opposing_overlap_rate: 0.333,
          cross_side_overlap_examples: [
            %{paper_ref: 4, claim: "shared claim", summary: "Shared evidence"}
          ]
        },
        %{
          status: "ok",
          topic: "topic three",
          cross_side_overlap_items: 1,
          cross_side_unique_llm_items: 5,
          cross_side_overlap_rate: 0.2,
          supporting_overlap_rate: 0.25,
          opposing_overlap_rate: 0.2,
          cross_side_overlap_examples: [
            %{paper_ref: 4, claim: "shared claim", summary: "Shared evidence"}
          ]
        },
        %{
          status: "investigate_error",
          topic: "topic four",
          error: "timeout"
        }
      ])

    assert summary.run_count == 3
    assert summary.zero_overlap_runs == 1
    assert summary.zero_overlap_rate == 0.333
    assert summary.total_cross_overlap_items == 3
    assert summary.total_cross_side_unique_llm_items == 19
    assert summary.aggregate_cross_side_overlap_rate == 0.158
    assert summary.average_cross_side_overlap_rate == 0.178
    assert summary.topics_with_overlap == ["topic two", "topic three"]

    assert summary.top_overlap_examples == [
             %{paper_ref: 4, claim: "shared claim", summary: "Shared evidence", count_runs: 2}
           ]

    assert summary.failures == [
             %{topic: "topic four", status: "investigate_error", error: "timeout"}
           ]
  end
end
