defmodule Daemon.Vault.CategoryTest do
  use ExUnit.Case, async: true

  alias Daemon.Vault.Category

  @all_categories [:fact, :decision, :lesson, :preference, :commitment, :relationship, :project, :observation]

  describe "all/0" do
    test "returns all 8 categories" do
      cats = Category.all()
      assert length(cats) == 8

      for cat <- @all_categories do
        assert cat in cats
      end
    end
  end

  describe "dir/1" do
    test "returns correct directory for each category" do
      expected = %{
        fact: "facts",
        decision: "decisions",
        lesson: "lessons",
        preference: "preferences",
        commitment: "commitments",
        relationship: "relationships",
        project: "projects",
        observation: "observations"
      }

      for {cat, dir} <- expected do
        assert Category.dir(cat) == dir
      end
    end

    test "raises for invalid category" do
      assert_raise FunctionClauseError, fn ->
        Category.dir(:nonexistent)
      end
    end
  end

  describe "label/1" do
    test "returns human-readable label for each category" do
      expected = %{
        fact: "Fact",
        decision: "Decision",
        lesson: "Lesson",
        preference: "Preference",
        commitment: "Commitment",
        relationship: "Relationship",
        project: "Project",
        observation: "Observation"
      }

      for {cat, label} <- expected do
        assert Category.label(cat) == label
      end
    end
  end

  describe "frontmatter_keys/1" do
    test "returns correct keys for fact" do
      assert Category.frontmatter_keys(:fact) == ["confidence", "source", "domain"]
    end

    test "returns correct keys for decision" do
      assert Category.frontmatter_keys(:decision) == ["context", "alternatives", "outcome"]
    end

    test "returns correct keys for lesson" do
      assert Category.frontmatter_keys(:lesson) == ["trigger", "insight", "applied"]
    end

    test "returns correct keys for preference" do
      assert Category.frontmatter_keys(:preference) == ["scope", "strength"]
    end

    test "returns correct keys for commitment" do
      assert Category.frontmatter_keys(:commitment) == ["party", "deadline", "status"]
    end

    test "returns correct keys for relationship" do
      assert Category.frontmatter_keys(:relationship) == ["entity", "role", "context"]
    end

    test "returns correct keys for project" do
      assert Category.frontmatter_keys(:project) == ["status", "stack", "repo"]
    end

    test "returns correct keys for observation" do
      assert Category.frontmatter_keys(:observation) == ["score", "decay_rate", "tags"]
    end
  end

  describe "parse/1" do
    test "parses valid category strings" do
      for cat <- @all_categories do
        assert {:ok, ^cat} = Category.parse(Atom.to_string(cat))
      end
    end

    test "returns :error for invalid category string" do
      assert :error = Category.parse("nonexistent")
    end

    test "returns :error for empty string" do
      assert :error = Category.parse("")
    end

    test "returns :error for unknown atom string" do
      assert :error = Category.parse("totally_not_a_thing_at_all_xyz")
    end
  end

  describe "valid?/1" do
    test "returns true for all valid categories" do
      for cat <- @all_categories do
        assert Category.valid?(cat)
      end
    end

    test "returns false for invalid atoms" do
      refute Category.valid?(:nonexistent)
      refute Category.valid?(:foo)
    end
  end

  describe "frontmatter_template/2" do
    test "generates YAML frontmatter with category and created timestamp" do
      template = Category.frontmatter_template(:fact)
      assert String.starts_with?(template, "---\n")
      assert String.ends_with?(template, "\n---")
      assert template =~ "category: fact"
      assert template =~ "created: "
      assert template =~ "confidence: "
      assert template =~ "source: "
      assert template =~ "domain: "
    end

    test "fills in provided values" do
      template = Category.frontmatter_template(:fact, %{"confidence" => "high", "source" => "user"})
      assert template =~ "confidence: high"
      assert template =~ "source: user"
    end

    test "accepts atom keys in values map" do
      template = Category.frontmatter_template(:fact, %{confidence: "0.9", domain: "elixir"})
      assert template =~ "confidence: 0.9"
      assert template =~ "domain: elixir"
    end

    test "leaves unspecified values empty" do
      template = Category.frontmatter_template(:decision, %{"context" => "testing"})
      assert template =~ "context: testing"
      assert template =~ "alternatives: "
      assert template =~ "outcome: "
    end
  end
end
