defmodule OptimalSystemAgent.Vault.ObservationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Vault.Observation

  describe "new/2" do
    test "creates observation with defaults" do
      obs = Observation.new("test content")
      assert obs.content == "test content"
      assert obs.score == 0.7
      assert obs.decay_rate == 0.05
      assert obs.tags == []
      assert obs.session_id == nil
      assert obs.source == nil
      assert is_binary(obs.id)
      assert %DateTime{} = obs.created_at
    end

    test "accepts custom options" do
      obs =
        Observation.new("custom obs",
          score: 0.9,
          decay_rate: 0.1,
          tags: ["error", "critical"],
          session_id: "sess-123",
          source: "agent"
        )

      assert obs.score == 0.9
      assert obs.decay_rate == 0.1
      assert obs.tags == ["error", "critical"]
      assert obs.session_id == "sess-123"
      assert obs.source == "agent"
    end

    test "generates unique IDs" do
      obs1 = Observation.new("a")
      obs2 = Observation.new("b")
      assert obs1.id != obs2.id
    end
  end

  describe "classify/1" do
    test "classifies error content with high score" do
      {score, tags} = Observation.classify("There was an error in the pipeline")
      assert score == 0.9
      assert "error" in tags
      assert "incident" in tags
    end

    test "classifies crash content" do
      {score, _tags} = Observation.classify("The server crash happened at midnight")
      assert score == 0.9
    end

    test "classifies decision content" do
      {score, tags} = Observation.classify("We decided to use PostgreSQL")
      assert score == 0.85
      assert "decision" in tags
    end

    test "classifies learning content" do
      {score, tags} = Observation.classify("I learned that caching helps performance")
      assert score == 0.8
      assert "learning" in tags
    end

    test "classifies preference content" do
      {score, tags} = Observation.classify("I prefer to use Elixir for backend services")
      assert score == 0.75
      assert "preference" in tags
    end

    test "classifies pattern content" do
      {score, tags} = Observation.classify("This is a recurring pattern in the codebase")
      assert score == 0.7
      assert "pattern" in tags
    end

    test "classifies general content with low score" do
      {score, tags} = Observation.classify("The sky is blue today")
      assert score == 0.5
      assert "general" in tags
    end
  end

  describe "effective_score/1" do
    test "returns full score for recently created observation" do
      obs = Observation.new("test", score: 0.8)
      effective = Observation.effective_score(obs)
      # Just created, should be very close to original score
      assert_in_delta effective, 0.8, 0.01
    end

    test "decays over time" do
      # Create an observation that was created 24 hours ago
      past = DateTime.utc_now() |> DateTime.add(-24 * 3600, :second)

      obs = %Observation{
        id: "test",
        content: "old observation",
        score: 1.0,
        decay_rate: 0.1,
        tags: [],
        created_at: past
      }

      effective = Observation.effective_score(obs)
      # After 24 hours with decay_rate 0.1: 1.0 * e^(-0.1 * 24) = ~0.0907
      assert effective < 0.5
      assert effective > 0.0
    end

    test "never goes below zero" do
      very_old = DateTime.utc_now() |> DateTime.add(-365 * 24 * 3600, :second)

      obs = %Observation{
        id: "test",
        content: "ancient",
        score: 0.5,
        decay_rate: 0.5,
        tags: [],
        created_at: very_old
      }

      effective = Observation.effective_score(obs)
      assert effective >= 0.0
    end
  end

  describe "relevant?/2" do
    test "returns true for fresh observation" do
      obs = Observation.new("fresh", score: 0.8)
      assert Observation.relevant?(obs)
    end

    test "returns true when above custom threshold" do
      obs = Observation.new("test", score: 0.5)
      assert Observation.relevant?(obs, 0.3)
    end

    test "returns false when below threshold" do
      very_old = DateTime.utc_now() |> DateTime.add(-365 * 24 * 3600, :second)

      obs = %Observation{
        id: "test",
        content: "ancient",
        score: 0.1,
        decay_rate: 1.0,
        tags: [],
        created_at: very_old
      }

      refute Observation.relevant?(obs, 0.1)
    end
  end

  describe "to_markdown/1 and from_markdown/1 round-trip" do
    test "round-trips an observation" do
      obs = Observation.new("Test observation content",
        score: 0.85,
        decay_rate: 0.03,
        tags: ["decision", "important"],
        session_id: "sess-abc",
        source: "agent-1"
      )

      md = Observation.to_markdown(obs)
      assert {:ok, parsed} = Observation.from_markdown(md)

      assert parsed.id == obs.id
      assert parsed.content == obs.content
      assert parsed.score == obs.score
      assert parsed.decay_rate == obs.decay_rate
      assert parsed.tags == obs.tags
      assert parsed.session_id == obs.session_id
      assert parsed.source == obs.source
    end

    test "to_markdown produces valid frontmatter" do
      obs = Observation.new("content here", tags: ["test"])
      md = Observation.to_markdown(obs)

      assert String.starts_with?(md, "---\n")
      assert md =~ "category: observation"
      assert md =~ "id: #{obs.id}"
      assert md =~ "score: #{obs.score}"
      assert md =~ "decay_rate: #{obs.decay_rate}"
      assert md =~ "tags: test"
      assert md =~ "content here"
    end

    test "from_markdown returns :error for invalid input" do
      assert :error = Observation.from_markdown("no frontmatter here")
    end

    test "from_markdown handles nil session_id and source" do
      obs = Observation.new("test")
      md = Observation.to_markdown(obs)
      {:ok, parsed} = Observation.from_markdown(md)

      assert parsed.session_id == nil
      assert parsed.source == nil
    end

    test "from_markdown handles multiple tags" do
      obs = Observation.new("test", tags: ["error", "incident", "critical"])
      md = Observation.to_markdown(obs)
      {:ok, parsed} = Observation.from_markdown(md)

      assert parsed.tags == ["error", "incident", "critical"]
    end
  end
end
