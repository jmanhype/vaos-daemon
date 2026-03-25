defmodule Daemon.Vault.FactExtractorTest do
  use ExUnit.Case, async: true

  alias Daemon.Vault.FactExtractor

  describe "extract/1" do
    test "extracts decision facts" do
      facts = FactExtractor.extract("We decided to use PostgreSQL for the primary database")
      assert Enum.any?(facts, fn f -> f.type == "decision" end)
    end

    test "extracts 'going with' pattern as decision" do
      facts = FactExtractor.extract("We're going with Redis for the cache layer")
      assert Enum.any?(facts, fn f -> f.type == "decision" and f.value =~ "Redis" end)
    end

    test "extracts preference facts" do
      facts = FactExtractor.extract("I prefer to use Elixir for backend services")
      assert Enum.any?(facts, fn f -> f.type == "preference" end)
    end

    test "extracts style convention preference" do
      facts = FactExtractor.extract("style: snake_case for all function names")
      assert Enum.any?(facts, fn f -> f.type == "preference" and f.value =~ "snake_case" end)
    end

    test "extracts technical facts with 'uses'" do
      facts = FactExtractor.extract("The system uses Docker for containerization")
      assert Enum.any?(facts, fn f -> f.type == "fact" end)
    end

    test "extracts version facts" do
      facts = FactExtractor.extract("We are on version 3.14.1 of the framework")
      version_fact = Enum.find(facts, fn f -> f.type == "fact" and f.value =~ "3.14.1" end)
      assert version_fact != nil
      assert version_fact.confidence == 0.9
    end

    test "extracts port facts" do
      facts = FactExtractor.extract("The server listens on 4000")
      assert Enum.any?(facts, fn f -> f.type == "fact" and f.value =~ "4000" end)
    end

    test "extracts endpoint/url facts" do
      facts = FactExtractor.extract("api: https://api.example.com/v2/data")
      assert Enum.any?(facts, fn f -> f.type == "fact" and f.value =~ "https://api.example.com" end)
    end

    test "extracts lesson facts" do
      facts = FactExtractor.extract("lesson: Always check connection pool exhaustion before scaling")
      assert Enum.any?(facts, fn f -> f.type == "lesson" end)
    end

    test "extracts root cause lessons" do
      facts = FactExtractor.extract("The root cause was a race condition in the cache invalidation logic")
      assert Enum.any?(facts, fn f -> f.type == "lesson" and f.value =~ "race condition" end)
    end

    test "extracts 'fixed by' lessons" do
      facts = FactExtractor.extract("This was fixed by adding a mutex around the shared state")
      assert Enum.any?(facts, fn f -> f.type == "lesson" end)
    end

    test "extracts commitment facts" do
      facts = FactExtractor.extract("We committed to delivering the MVP by next Friday")
      assert Enum.any?(facts, fn f -> f.type == "commitment" end)
    end

    test "extracts deadline commitments" do
      facts = FactExtractor.extract("This needs to be done by 2026-04-01 at the latest")
      assert Enum.any?(facts, fn f -> f.type == "commitment" and f.value =~ "2026-04-01" end)
    end

    test "extracts relationship facts" do
      facts = FactExtractor.extract("owner: Alice maintains the auth service")
      assert Enum.any?(facts, fn f -> f.type == "relationship" end)
    end

    test "extracts @mention relationships" do
      facts = FactExtractor.extract("@bob is responsible for the frontend architecture")
      assert Enum.any?(facts, fn f -> f.type == "relationship" end)
    end

    test "returns empty list for content with no patterns" do
      facts = FactExtractor.extract("The sky is blue and the grass is green.")
      assert facts == []
    end

    test "extracts multiple fact types from rich content" do
      content = """
      We decided to use Elixir for the backend. The system runs on BEAM.
      lesson: Never deploy on Fridays. Port listens on 4000.
      owner: Roberto manages the OSA project.
      """

      facts = FactExtractor.extract(content)
      types = Enum.map(facts, & &1.type) |> Enum.uniq()
      assert length(types) >= 3
    end

    test "results are sorted by confidence descending" do
      content = """
      version 2.0.0 is deployed. We decided to use Kubernetes.
      lesson: Check health endpoints first.
      """

      facts = FactExtractor.extract(content)
      confidences = Enum.map(facts, & &1.confidence)
      assert confidences == Enum.sort(confidences, :desc)
    end

    test "deduplicates by value" do
      # Content that might trigger same value from multiple patterns
      facts = FactExtractor.extract("decided to use Redis and chose to use Redis for caching")
      values = Enum.map(facts, & &1.value)
      assert values == Enum.uniq(values)
    end

    test "each fact has required keys" do
      facts = FactExtractor.extract("We decided to migrate to Kubernetes for orchestration")

      for fact <- facts do
        assert Map.has_key?(fact, :type)
        assert Map.has_key?(fact, :value)
        assert Map.has_key?(fact, :confidence)
        assert Map.has_key?(fact, :pattern)
        assert is_binary(fact.type)
        assert is_binary(fact.value)
        assert is_float(fact.confidence)
        assert is_binary(fact.pattern)
      end
    end
  end

  describe "extract_confident/2" do
    test "filters by default threshold of 0.7" do
      content = "We decided to use Elixir. The sky is blue today."
      facts = FactExtractor.extract_confident(content)
      assert Enum.all?(facts, fn f -> f.confidence >= 0.7 end)
    end

    test "respects custom threshold" do
      content = "version 1.0.0 released. We decided to refactor the pipeline module."
      facts = FactExtractor.extract_confident(content, 0.85)
      assert Enum.all?(facts, fn f -> f.confidence >= 0.85 end)
    end

    test "returns empty list when nothing meets threshold" do
      facts = FactExtractor.extract_confident("The sky is blue.", 0.99)
      assert facts == []
    end
  end

  describe "extract_grouped/1" do
    test "groups facts by type" do
      content = """
      We decided to use PostgreSQL. The system runs on BEAM.
      lesson: Always validate inputs. version 2.0.0.
      """

      grouped = FactExtractor.extract_grouped(content)
      assert is_map(grouped)

      for {type, facts} <- grouped do
        assert is_binary(type)
        assert is_list(facts)
        assert Enum.all?(facts, fn f -> f.type == type end)
      end
    end

    test "returns empty map for no matches" do
      grouped = FactExtractor.extract_grouped("Nothing interesting here at all.")
      assert grouped == %{}
    end
  end
end
