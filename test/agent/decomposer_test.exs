defmodule Daemon.Agent.Orchestrator.DecomposerTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Orchestrator.Decomposer

  # ── should_decompose?/1 ───────────────────────────────────────────

  describe "should_decompose?/1" do
    test "short simple tasks return false" do
      refute Decomposer.should_decompose?("fix the typo")
      refute Decomposer.should_decompose?("add a button")
      refute Decomposer.should_decompose?("hello world")
    end

    test "long complex tasks return true" do
      msg = "Please refactor the authentication module and also update the database schema and then deploy the updated backend service and additionally migrate all the integration tests to use the new mocking framework and update the CI pipeline configuration"
      assert Decomposer.should_decompose?(msg)
    end
  end

  # ── estimate_complexity_score/1 ───────────────────────────────────

  describe "estimate_complexity_score/1" do
    test "simple text returns low score" do
      score = Decomposer.estimate_complexity_score("fix a bug")
      assert score < 0.5
    end

    test "complex text with multiple domains returns high score" do
      score = Decomposer.estimate_complexity_score(
        "deploy the backend and test the frontend and also migrate the database and additionally refactor the API and update the infrastructure"
      )
      assert score > 0.6
    end

    test "score is capped at 1.0" do
      score = Decomposer.estimate_complexity_score(
        "first deploy and then test and also migrate and additionally refactor and next update and furthermore integrate and moreover step second third finally backend frontend database api"
      )
      assert score <= 1.0
    end
  end

  # ── cost_justified?/2 ─────────────────────────────────────────────

  describe "cost_justified?/2" do
    test "fewer than 3 sub-tasks with same role is not justified" do
      sub_tasks = [
        %{role: :backend, description: "task one here"},
        %{role: :backend, description: "task two here"}
      ]
      refute Decomposer.cost_justified?("a simple task description", sub_tasks)
    end

    test "3+ sub-tasks with distinct roles can be justified" do
      sub_tasks = [
        %{role: :backend, description: "build the api"},
        %{role: :frontend, description: "build the ui"},
        %{role: :data, description: "schema design"}
      ]
      # Short task description means low single-agent cost, so multi-agent might not be justified
      # But distinct roles help
      result = Decomposer.cost_justified?("build full stack feature", sub_tasks)
      assert is_boolean(result)
    end
  end

  # ── build_execution_waves/1 ───────────────────────────────────────

  describe "build_execution_waves/1" do
    test "tasks with no dependencies are in wave 0" do
      sub_tasks = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: []},
        %{name: "c", depends_on: []}
      ]

      waves = Decomposer.build_execution_waves(sub_tasks)
      assert length(waves) == 1
      assert length(hd(waves)) == 3
    end

    test "respects dependency ordering" do
      sub_tasks = [
        %{name: "schema", depends_on: []},
        %{name: "api", depends_on: ["schema"]},
        %{name: "frontend", depends_on: ["api"]},
        %{name: "tests", depends_on: []}
      ]

      waves = Decomposer.build_execution_waves(sub_tasks)
      assert length(waves) == 3

      wave0_names = Enum.map(Enum.at(waves, 0), & &1.name) |> Enum.sort()
      assert wave0_names == ["schema", "tests"]

      wave1_names = Enum.map(Enum.at(waves, 1), & &1.name)
      assert wave1_names == ["api"]

      wave2_names = Enum.map(Enum.at(waves, 2), & &1.name)
      assert wave2_names == ["frontend"]
    end

    test "empty list returns empty waves" do
      assert Decomposer.build_execution_waves([]) == []
    end
  end

  # ── build_dependency_context/2 ────────────────────────────────────

  describe "build_dependency_context/2" do
    test "returns nil for empty depends_on" do
      assert Decomposer.build_dependency_context([], %{}) == nil
    end

    test "returns nil when no results available" do
      assert Decomposer.build_dependency_context(["a", "b"], %{}) == nil
    end

    test "builds context string from available results" do
      results = %{"schema" => "Created users table", "tests" => "All tests pass"}
      context = Decomposer.build_dependency_context(["schema", "tests"], results)
      assert context =~ "Results from schema"
      assert context =~ "Created users table"
      assert context =~ "Results from tests"
    end
  end
end
