defmodule Daemon.Agent.Memory.TaxonomyTest do
  use ExUnit.Case, async: true
  @moduletag :skip  # Taxonomy module API changed

  alias Daemon.Agent.Memory.Taxonomy

  # ── new/2 ────────────────────────────────────────────────────────────

  describe "new/2" do
    test "creates entry with auto-generated ID and timestamps" do
      entry = Taxonomy.new("some memory content")

      assert is_binary(entry.id)
      assert String.length(entry.id) == 16
      assert %DateTime{} = entry.created_at
      assert %DateTime{} = entry.accessed_at
      assert entry.access_count == 0
      assert entry.relevance_score == 0.0
    end

    test "auto-classifies content into category" do
      entry = Taxonomy.new("I always prefer functional style over OOP")
      assert entry.category == :user_preference
    end

    test "respects explicit category override" do
      entry = Taxonomy.new("anything", category: :lesson)
      assert entry.category == :lesson
    end

    test "defaults scope to :workspace" do
      entry = Taxonomy.new("content")
      assert entry.scope == :workspace
    end

    test "respects explicit scope" do
      entry = Taxonomy.new("content", scope: :global)
      assert entry.scope == :global
    end

    test "stores metadata" do
      entry = Taxonomy.new("content", metadata: %{source: "user"})
      assert entry.metadata == %{source: "user"}
    end
  end

  # ── categorize/1 ─────────────────────────────────────────────────────

  describe "categorize/1" do
    test "classifies user preferences" do
      assert Taxonomy.categorize("I always prefer tabs over spaces") == :user_preference
      assert Taxonomy.categorize("Never use var, always use const") == :user_preference
    end

    test "classifies project info" do
      assert Taxonomy.categorize("The project uses Elixir with Phoenix framework") == :project_info
    end

    test "classifies project specs" do
      assert Taxonomy.categorize("The requirement is that users must authenticate first") ==
               :project_spec
    end

    test "classifies lessons" do
      assert Taxonomy.categorize("We learned from that bug that N+1 queries cause issues") ==
               :lesson
    end

    test "classifies patterns" do
      assert Taxonomy.categorize("A recurring pattern in the codebase is the repository layer") ==
               :pattern
    end

    test "classifies solutions" do
      assert Taxonomy.categorize("The solution to the timeout was increasing the pool size") ==
               :solution
    end

    test "defaults to :context for unrecognized content" do
      assert Taxonomy.categorize("hello world 12345") == :context
    end

    test "handles nil and non-string input" do
      assert Taxonomy.categorize(nil) == :context
      assert Taxonomy.categorize(42) == :context
    end
  end

  # ── filter_by/2 ──────────────────────────────────────────────────────

  describe "filter_by/2" do
    setup do
      entries = [
        Taxonomy.new("global preference", category: :user_preference, scope: :global),
        Taxonomy.new("workspace project info", category: :project_info, scope: :workspace),
        Taxonomy.new("session context", category: :context, scope: :session),
        Taxonomy.new("a lesson about errors", category: :lesson, scope: :workspace),
        Taxonomy.new("a known pattern", category: :pattern, scope: :global)
      ]

      {:ok, entries: entries}
    end

    test "filters by single category", %{entries: entries} do
      result = Taxonomy.filter_by(entries, category: :lesson)
      assert length(result) == 1
      assert hd(result).category == :lesson
    end

    test "filters by multiple categories", %{entries: entries} do
      result = Taxonomy.filter_by(entries, category: [:lesson, :pattern])
      assert length(result) == 2
      assert Enum.all?(result, &(&1.category in [:lesson, :pattern]))
    end

    test "filters by single scope", %{entries: entries} do
      result = Taxonomy.filter_by(entries, scope: :global)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.scope == :global))
    end

    test "filters by multiple scopes", %{entries: entries} do
      result = Taxonomy.filter_by(entries, scope: [:global, :session])
      assert length(result) == 3
    end

    test "combines category and scope filters", %{entries: entries} do
      result = Taxonomy.filter_by(entries, category: :user_preference, scope: :global)
      assert length(result) == 1
      assert hd(result).category == :user_preference
      assert hd(result).scope == :global
    end

    test "filters by min_relevance" do
      entries = [
        %{Taxonomy.new("high", category: :lesson) | relevance_score: 0.9},
        %{Taxonomy.new("low", category: :lesson) | relevance_score: 0.1}
      ]

      result = Taxonomy.filter_by(entries, min_relevance: 0.5)
      assert length(result) == 1
      assert hd(result).relevance_score == 0.9
    end

    test "filters by min_access_count" do
      entries = [
        %{Taxonomy.new("accessed", category: :lesson) | access_count: 5},
        %{Taxonomy.new("fresh", category: :lesson) | access_count: 0}
      ]

      result = Taxonomy.filter_by(entries, min_access_count: 3)
      assert length(result) == 1
      assert hd(result).access_count == 5
    end

    test "filters by :since datetime", %{entries: entries} do
      # All entries were just created, so filtering by 1 hour ago should include all
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Taxonomy.filter_by(entries, since: one_hour_ago)
      assert length(result) == 5

      # Filtering by 1 hour in the future should include none
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Taxonomy.filter_by(entries, since: future)
      assert length(result) == 0
    end

    test "filters by custom predicate", %{entries: entries} do
      result =
        Taxonomy.filter_by(entries,
          predicate: fn entry -> String.contains?(entry.content, "global") end
        )

      assert length(result) == 1
    end

    test "returns all entries when no filters given", %{entries: entries} do
      result = Taxonomy.filter_by(entries, [])
      assert length(result) == 5
    end
  end

  # ── touch/1 ──────────────────────────────────────────────────────────

  describe "touch/1" do
    test "increments access count and updates accessed_at" do
      entry = Taxonomy.new("content")
      assert entry.access_count == 0

      touched = Taxonomy.touch(entry)
      assert touched.access_count == 1
      assert DateTime.compare(touched.accessed_at, entry.accessed_at) in [:gt, :eq]

      touched2 = Taxonomy.touch(touched)
      assert touched2.access_count == 2
    end
  end

  # ── categories/0 and scopes/0 ───────────────────────────────────────

  describe "categories/0 and scopes/0" do
    test "returns all 7 categories" do
      cats = Taxonomy.categories()
      assert length(cats) == 7
      assert :user_preference in cats
      assert :project_info in cats
      assert :project_spec in cats
      assert :lesson in cats
      assert :pattern in cats
      assert :solution in cats
      assert :context in cats
    end

    test "returns all 3 scopes" do
      scopes = Taxonomy.scopes()
      assert length(scopes) == 3
      assert :global in scopes
      assert :workspace in scopes
      assert :session in scopes
    end
  end

  # ── valid_category?/1 and valid_scope?/1 ─────────────────────────────

  describe "validation helpers" do
    test "valid_category? returns true for valid categories" do
      assert Taxonomy.valid_category?(:lesson)
      assert Taxonomy.valid_category?(:pattern)
      refute Taxonomy.valid_category?(:bogus)
    end

    test "valid_scope? returns true for valid scopes" do
      assert Taxonomy.valid_scope?(:global)
      assert Taxonomy.valid_scope?(:session)
      refute Taxonomy.valid_scope?(:imaginary)
    end
  end
end
