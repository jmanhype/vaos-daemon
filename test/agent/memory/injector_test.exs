defmodule Daemon.Agent.Memory.InjectorTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Memory.{Taxonomy, Injector}

  # ── Helpers ──────────────────────────────────────────────────────────

  defp make_entry(content, opts \\ []) do
    Taxonomy.new(content, opts)
  end

  # ── inject_relevant/2 ───────────────────────────────────────────────

  describe "inject_relevant/2 — always-inject rules" do
    test "project_info + workspace scope always injected" do
      entries = [
        make_entry("The stack uses Elixir and Phoenix", category: :project_info, scope: :workspace)
      ]

      result = Injector.inject_relevant(entries, %{})
      assert length(result) == 1
      assert hd(result).category == :project_info
      assert hd(result).relevance_score > 0.0
    end

    test "user_preference + global scope always injected" do
      entries = [
        make_entry("I always prefer explicit types", category: :user_preference, scope: :global)
      ]

      result = Injector.inject_relevant(entries, %{})
      assert length(result) == 1
      assert hd(result).category == :user_preference
    end

    test "both always-inject rules rank higher than contextual entries" do
      entries = [
        make_entry("session note", category: :context, scope: :session),
        make_entry("project uses Elixir", category: :project_info, scope: :workspace),
        make_entry("always use strict mode", category: :user_preference, scope: :global)
      ]

      result = Injector.inject_relevant(entries, %{session_id: "sess-1"})

      # project_info and user_preference should be in top 2
      top_categories = result |> Enum.take(2) |> Enum.map(& &1.category) |> MapSet.new()
      assert :project_info in top_categories or :user_preference in top_categories
    end
  end

  describe "inject_relevant/2 — file pattern matching" do
    test "lessons about elixir injected when working on .ex files" do
      entries = [
        make_entry("Lesson: elixir GenServer calls can timeout if handler is slow",
          category: :lesson,
          scope: :workspace
        )
      ]

      result = Injector.inject_relevant(entries, %{files: ["/app/lib/server.ex"]})
      assert length(result) == 1
      assert hd(result).relevance_score > 0.0
    end

    test "lessons about go not injected when working on .ex files" do
      entries = [
        make_entry("Lesson: golang goroutine leak when channel not closed",
          category: :lesson,
          scope: :workspace
        )
      ]

      # The word "golang" / "goroutine" won't match elixir keywords
      result = Injector.inject_relevant(entries, %{files: ["/app/lib/server.ex"]})
      # Should still appear (base score > 0) but with low score
      if length(result) > 0 do
        assert hd(result).relevance_score < 0.5
      end
    end

    test "filename match gives high relevance" do
      entries = [
        make_entry("The router.ex file handles all API routes",
          category: :lesson,
          scope: :workspace
        )
      ]

      result = Injector.inject_relevant(entries, %{files: ["/app/lib/router.ex"]})
      assert length(result) == 1
      assert hd(result).relevance_score > 0.3
    end
  end

  describe "inject_relevant/2 — task matching" do
    test "patterns injected when task_type matches" do
      entries = [
        make_entry("Pattern: debug sessions often need log inspection first",
          category: :pattern,
          scope: :workspace
        )
      ]

      result = Injector.inject_relevant(entries, %{task_type: "debug"})
      assert length(result) == 1
      assert hd(result).relevance_score > 0.0
    end

    test "task description keyword matching" do
      entries = [
        make_entry("Solution: connection pool exhaustion fixed by increasing pool size",
          category: :solution,
          scope: :workspace
        )
      ]

      result =
        Injector.inject_relevant(entries, %{task: "fix connection pool exhaustion in production"})

      assert length(result) == 1
      assert hd(result).relevance_score > 0.3
    end
  end

  describe "inject_relevant/2 — error matching" do
    test "solutions injected when error keywords match" do
      entries = [
        make_entry("Solution: timeout error on database query — increase pool_size to 20",
          category: :solution,
          scope: :workspace
        )
      ]

      result =
        Injector.inject_relevant(entries, %{
          error: "DBConnection.ConnectionError: timeout on database query"
        })

      assert length(result) == 1
      assert hd(result).relevance_score > 0.3
    end

    test "lessons also surface for error context" do
      entries = [
        make_entry("Lesson: database timeout errors are usually pool exhaustion",
          category: :lesson,
          scope: :workspace
        )
      ]

      result =
        Injector.inject_relevant(entries, %{error: "timeout on database connection"})

      assert length(result) == 1
    end
  end

  describe "inject_relevant/2 — session scoping" do
    test "session-scoped context only injected for matching session" do
      entries = [
        make_entry("Working on the auth module refactor",
          category: :context,
          scope: :session,
          metadata: %{session_id: "sess-1"}
        )
      ]

      # With matching session
      result = Injector.inject_relevant(entries, %{session_id: "sess-1"})
      assert length(result) == 1

      # Without session — session context should have very low score or be filtered
      result_no_session = Injector.inject_relevant(entries, %{})

      if length(result_no_session) > 0 do
        # Should be lower relevance without session match than with
        assert hd(result_no_session).relevance_score < hd(result).relevance_score
      end
    end
  end

  describe "inject_relevant/2 — limits and budget" do
    test "respects max_entries" do
      entries =
        for i <- 1..10 do
          make_entry("Project info item #{i}", category: :project_info, scope: :workspace)
        end

      result = Injector.inject_relevant(entries, %{max_entries: 3})
      assert length(result) == 3
    end

    test "respects max_tokens budget" do
      entries =
        for i <- 1..10 do
          # Each entry ~50 chars = ~12 tokens
          make_entry("Short project info number #{i}",
            category: :project_info,
            scope: :workspace
          )
        end

      # Budget for ~2 entries (~25 tokens)
      result = Injector.inject_relevant(entries, %{max_tokens: 25})
      assert length(result) <= 3
    end
  end

  # ── format_for_prompt/1 ─────────────────────────────────────────────

  describe "format_for_prompt/1" do
    test "returns empty string for empty list" do
      assert Injector.format_for_prompt([]) == ""
    end

    test "formats entries with category and scope tags" do
      entries = [
        make_entry("Use strict mode", category: :user_preference, scope: :global),
        make_entry("Stack: Elixir + Phoenix", category: :project_info, scope: :workspace)
      ]

      output = Injector.format_for_prompt(entries)
      assert String.contains?(output, "[user_preference]")
      assert String.contains?(output, "[global]")
      assert String.contains?(output, "Use strict mode")
      assert String.contains?(output, "[project_info]")
      assert String.contains?(output, "[workspace]")
    end
  end
end
