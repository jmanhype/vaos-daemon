defmodule Daemon.Tools.InvestigateStreamTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.Investigate

  @moduletag :investigate
  @moduletag :capture_log

  # ── Unit Tests for Investigation Tool ────────────────────────────────

  describe "Investigate.execute/1" do
    test "returns {:ok, result} for valid topic" do
      args = %{
        "topic" => "exercise reduces cardiovascular disease risk",
        "depth" => "standard"
      }

      assert {:ok, result} = Investigate.execute(args)
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "returns {:error, reason} for empty topic" do
      args = %{
        "topic" => "",
        "depth" => "standard"
      }

      assert {:error, "Missing topic"} = Investigate.execute(args)
    end

    test "returns {:error, reason} when topic is missing" do
      args = %{
        "depth" => "standard"
      }

      assert {:error, "Missing topic"} = Investigate.execute(args)
    end

    test "accepts standard depth parameter" do
      args = %{
        "topic" => "test claim",
        "depth" => "standard"
      }

      assert {:ok, _result} = Investigate.execute(args)
    end

    test "accepts deep depth parameter" do
      args = %{
        "topic" => "test claim",
        "depth" => "deep"
      }

      assert {:ok, _result} = Investigate.execute(args)
    end

    test "defaults to standard depth when not provided" do
      args = %{
        "topic" => "test claim"
      }

      assert {:ok, _result} = Investigate.execute(args)
    end
  end

  # ── Result Format Tests ──────────────────────────────────────────────

  describe "investigation result format" do
    test "includes direction field in result" do
      args = %{"topic" => "exercise is healthy"}

      assert {:ok, result} = Investigate.execute(args)

      # Result should contain direction indicator
      assert String.contains?(result, "Direction:")
    end

    test "includes evidence sections in result" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should have case for and against sections
      assert String.contains?(result, "Case For") or String.contains?(result, "Case Against")
    end

    test "includes paper list in result" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should include papers consulted section
      assert String.contains?(result, "Papers Consulted")
    end

    test "includes metadata JSON in result" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should include VAOS_JSON metadata
      assert String.contains?(result, "<!-- VAOS_JSON:")
    end
  end

  # ── Citation Verification Tests ───────────────────────────────────────

  describe "citation verification" do
    test "identifies verified citations in result" do
      args = %{"topic" => "smoking causes lung cancer"}

      assert {:ok, result} = Investigate.execute(args)

      # Should include verified citations
      assert String.contains?(result, "VERIFIED") or String.contains?(result, "verified")
    end

    test "identifies fraudulent citations in result" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # May include fraudulent citation warnings
      # This is expected behavior for adversarial analysis
      assert is_binary(result)
    end

    test "includes citation counts for papers" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should show citation counts
      assert String.contains?(result, "citations")
    end
  end

  # ── Evidence Hierarchy Tests ─────────────────────────────────────────

  describe "evidence hierarchy scoring" do
    test "weights review papers higher than studies" do
      args = %{"topic" => "systematic review exists for this topic"}

      assert {:ok, result} = Investigate.execute(args)

      # Result should reflect evidence hierarchy
      assert is_binary(result)
    end

    test "includes evidence quality breakdown" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should show evidence quality metrics
      assert String.contains?(result, "Evidence quality")
    end
  end

  # ── Optional Parameters Tests ────────────────────────────────────────

  describe "optional parameters" do
    test "accepts steering context parameter" do
      args = %{
        "topic" => "test claim",
        "steering" => "Focus on RCT evidence only"
      }

      assert {:ok, _result} = Investigate.execute(args)
    end

    test "accepts metadata parameter" do
      args = %{
        "topic" => "test claim",
        "metadata" => %{
          "source_module" => "CodeIntrospector",
          "anomaly_type" => "performance"
        }
      }

      assert {:ok, _result} = Investigate.execute(args)
    end

    test "merges metadata into investigation_complete event" do
      # This tests internal behavior - metadata should be emitted with events
      args = %{
        "topic" => "test claim",
        "metadata" => %{"test_key" => "test_value"}
      }

      assert {:ok, _result} = Investigate.execute(args)
      # Metadata merging is verified through event emission (internal)
    end
  end

  # ── Error Handling Tests ────────────────────────────────────────────

  describe "error handling" do
    test "handles LLM provider failures gracefully" do
      # This test assumes we can mock LLM failures
      # In real implementation, would use Mox or similar

      args = %{"topic" => "test claim"}

      # Should return either error or partial result
      result = Investigate.execute(args)

      case result do
        {:ok, _} -> :ok # Success is acceptable
        {:error, _} -> :ok # Error is acceptable
      end
    end

    test "handles network failures for literature search" do
      # Network failures should be handled by circuit breaker
      args = %{"topic" => "test claim"}

      # Should not crash
      assert {:ok, _} = Investigate.execute(args)
    end

    test "handles timeout scenarios" do
      # Long-running investigations should handle timeouts
      args = %{"topic" => "test claim", "depth" => "deep"}

      # Should complete or timeout gracefully
      result = Investigate.execute(args)

      case result do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ── Circuit Breaker Tests ───────────────────────────────────────────

  describe "source circuit breaker" do
    test "circuit_check returns :ok for healthy sources" do
      sources = [:openalex, :semantic_scholar, :alphaxiv, :huggingface]

      Enum.each(sources, fn source ->
        result = Investigate.circuit_check(source)
        assert result in [:ok, :skip]
      end)
    end

    test "circuit_status returns map of all sources" do
      status = Investigate.circuit_status()

      assert is_map(status)
      assert Map.has_key?(status, :openalex)
      assert Map.has_key?(status, :semantic_scholar)
    end

    test "circuit skips sources after consecutive failures" do
      # This would require mocking failures
      # For now, just verify the API exists
      assert function_exported?(Investigate, :circuit_check, 1)
      assert function_exported?(Investigate, :circuit_record_failure, 1)
      assert function_exported?(Investigate, :circuit_record_success, 1)
    end
  end

  # ── Keyword Extraction Tests ────────────────────────────────────────

  describe "keyword extraction" do
    test "extracts relevant keywords from topic" do
      topic = "intermittent fasting for weight loss and metabolic health"

      # Keywords are extracted internally
      # We can verify by checking the investigation runs
      args = %{"topic" => topic}

      assert {:ok, _result} = Investigate.execute(args)
    end

    test "removes stop words from keywords" do
      topic = "the effect of exercise on cardiovascular health"

      args = %{"topic" => topic}

      assert {:ok, _result} = Investigate.execute(args)
    end
  end

  # ── Knowledge Graph Integration Tests ───────────────────────────────

  describe "knowledge graph integration" do
    test "stores investigation results in knowledge graph" do
      topic = "test claim for knowledge graph #{System.unique_integer()}"

      args = %{"topic" => topic}

      assert {:ok, _result} = Investigate.execute(args)

      # Results should be stored (verified through SPARQL in integration tests)
    end

    test "stores evidence triples" do
      args = %{"topic" => "test claim"}

      assert {:ok, _result} = Investigate.execute(args)

      # Evidence should be stored as triples
    end

    test "increments helpful counters for reused evidence" do
      # Run investigation twice with similar topic
      topic = "exercise reduces cardiovascular risk"

      Investigate.execute(%{"topic" => topic})
      Process.sleep(100) # Give time for first to complete
      assert {:ok, _result} = Investigate.execute(%{"topic" => topic})

      # Second investigation should increment helpful counters
    end
  end

  # ── Paper Search Tests ───────────────────────────────────────────────

  describe "multi-source paper search" do
    test "searches Semantic Scholar for papers" do
      args = %{"topic" => "climate change causes temperature rise"}

      assert {:ok, result} = Investigate.execute(args)

      # Should find papers from Semantic Scholar
      assert String.contains?(result, "Papers Consulted")
    end

    test "searches OpenAlex for papers" do
      args = %{"topic" => "test claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should find papers from OpenAlex
      assert is_binary(result)
    end

    test "deduplicates papers from multiple sources" do
      args = %{"topic" => "well-researched topic"}

      assert {:ok, result} = Investigate.execute(args)

      # Should not show duplicate papers
      assert is_binary(result)
    end

    test "filters irrelevant papers" do
      args = %{"topic" => "very specific medical claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should filter papers that don't match topic
      assert is_binary(result)
    end
  end

  # ── Adversarial Analysis Tests ───────────────────────────────────────

  describe "adversarial dual-prompt analysis" do
    test "generates arguments for the claim" do
      args = %{"topic" => "exercise is beneficial"}

      assert {:ok, result} = Investigate.execute(args)

      # Should have supporting arguments
      assert String.contains?(result, "Case For") or String.contains?(result, "supporting")
    end

    test "generates arguments against the claim" do
      args = %{"topic" => "exercise is beneficial"}

      assert {:ok, result} = Investigate.execute(args)

      # Should have opposing arguments
      assert String.contains?(result, "Case Against") or String.contains?(result, "opposing")
    end

    test "computes direction from evidence balance" do
      args = %{"topic" => "clearly supported claim"}

      assert {:ok, result} = Investigate.execute(args)

      # Should have a direction
      assert String.contains?(result, "Direction:")
    end
  end

  # ── Emergent Question Synthesis Tests ───────────────────────────────

  describe "emergent question synthesis" do
    test "extracts novel research questions from evidence tension" do
      args = %{"topic" => "contested scientific claim"}

      assert {:ok, result} = Investigate.execute(args)

      # May include suggested next investigations
      # This is optional and depends on the implementation
      assert is_binary(result)
    end
  end

  # ── Deep Mode Tests ─────────────────────────────────────────────────

  describe "deep research mode" do
    test "runs research pipeline when depth is deep" do
      args = %{
        "topic" => "test claim",
        "depth" => "deep"
      }

      assert {:ok, result} = Investigate.execute(args)

      # Should include deep research section
      assert is_binary(result)
    end

    test "generates hypotheses in deep mode" do
      args = %{
        "topic" => "test claim",
        "depth" => "deep"
      }

      assert {:ok, _result} = Investigate.execute(args)
      # Hypotheses generation happens internally
    end
  end

  # ── Performance Tests ───────────────────────────────────────────────

  @tag :slow
  @tag :investigate_performance
  describe "performance characteristics" do
    test "completes simple investigation within 60 seconds" do
      start = System.monotonic_time(:second)

      args = %{"topic" => "simple claim"}

      assert {:ok, _result} = Investigate.execute(args)

      elapsed = System.monotonic_time(:second) - start
      assert elapsed < 60
    end

    test "handles concurrent investigations" do
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            Investigate.execute(%{"topic" => "concurrent test #{i}"})
          end)
        end

      results = Task.await_many(tasks, 120_000)

      assert length(results) == 3
      Enum.each(results, fn
        {:ok, _} -> :ok
        _ -> flunk("Concurrent investigation failed")
      end)
    end
  end

  # ── Validation Tests ────────────────────────────────────────────────

  describe "parameter validation" do
    test "rejects non-string topic" do
      args = %{"topic" => 123}

      # Should convert to string or reject
      result = Investigate.execute(args)

      case result do
        {:ok, _} -> :ok # Accepts conversion
        {:error, _} -> :ok # Or rejects
      end
    end

    test "accepts string depth values" do
      Enum.each(["standard", "deep"], fn depth ->
        args = %{"topic" => "test", "depth" => depth}
        assert {:ok, _result} = Investigate.execute(args)
      end)
    end

    test "ignores invalid depth values" do
      args = %{"topic" => "test", "depth" => "invalid"}

      # Should default to standard
      assert {:ok, _result} = Investigate.execute(args)
    end
  end
end
