defmodule Daemon.Agent.StrategyTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Strategy
  alias Daemon.Agent.Strategies.{ReAct, ChainOfThought, TreeOfThoughts, Reflection, MCTS}

  # ── Strategy.all/0 ───────────────────────────────────────────────

  describe "all/0" do
    test "returns all 5 strategies" do
      strategies = Strategy.all()
      assert length(strategies) == 5
      names = Enum.map(strategies, & &1.name)
      assert :react in names
      assert :chain_of_thought in names
      assert :tree_of_thoughts in names
      assert :reflection in names
      assert :mcts in names
    end
  end

  # ── Strategy.names/0 ────────────────────────────────────────────

  describe "names/0" do
    test "returns all strategy name atoms" do
      # Order reflects selection priority: specific strategies before ReAct (the fallback)
      assert Strategy.names() == [:mcts, :reflection, :tree_of_thoughts, :chain_of_thought, :react]
    end
  end

  # ── Strategy.resolve_by_name/1 ──────────────────────────────────

  describe "resolve_by_name/1" do
    test "resolves each known strategy by name" do
      for name <- [:react, :chain_of_thought, :tree_of_thoughts, :reflection, :mcts] do
        assert {:ok, mod} = Strategy.resolve_by_name(name)
        assert mod.name() == name
      end
    end

    test "returns error for unknown strategy" do
      assert {:error, :unknown_strategy} = Strategy.resolve_by_name(:nonexistent)
    end
  end

  # ── Strategy.resolve/1 — explicit strategy key ──────────────────

  describe "resolve/1 with explicit strategy" do
    test "uses explicit :strategy key when provided" do
      assert {:ok, mod} = Strategy.resolve(%{strategy: :reflection})
      assert mod == Reflection
    end

    test "returns error for unknown explicit strategy" do
      assert {:error, :unknown_strategy} = Strategy.resolve(%{strategy: :bogus})
    end
  end

  # ── Strategy.resolve/1 — task type heuristic ────────────────────

  describe "resolve/1 with task_type" do
    test "simple tasks resolve to ReAct" do
      assert {:ok, ReAct} = Strategy.resolve(%{task_type: :simple})
      assert {:ok, ReAct} = Strategy.resolve(%{task_type: :action})
    end

    test "analysis tasks resolve to ChainOfThought" do
      assert {:ok, ChainOfThought} = Strategy.resolve(%{task_type: :analysis})
      assert {:ok, ChainOfThought} = Strategy.resolve(%{task_type: :research})
    end

    test "planning tasks resolve to TreeOfThoughts" do
      assert {:ok, TreeOfThoughts} = Strategy.resolve(%{task_type: :planning})
      assert {:ok, TreeOfThoughts} = Strategy.resolve(%{task_type: :design})
      assert {:ok, TreeOfThoughts} = Strategy.resolve(%{task_type: :architecture})
    end

    test "debugging tasks resolve to Reflection" do
      assert {:ok, Reflection} = Strategy.resolve(%{task_type: :debugging})
      assert {:ok, Reflection} = Strategy.resolve(%{task_type: :review})
      assert {:ok, Reflection} = Strategy.resolve(%{task_type: :refactor})
    end

    test "exploration tasks resolve to MCTS" do
      assert {:ok, MCTS} = Strategy.resolve(%{task_type: :exploration})
      assert {:ok, MCTS} = Strategy.resolve(%{task_type: :optimization})
      assert {:ok, MCTS} = Strategy.resolve(%{task_type: :search})
    end
  end

  # ── Strategy.resolve/1 — complexity fallback ────────────────────

  describe "resolve/1 with complexity" do
    test "low complexity (1-3) falls back to ReAct" do
      for c <- 1..3 do
        assert {:ok, ReAct} = Strategy.resolve(%{complexity: c})
      end
    end

    test "medium complexity (4-5) falls back to ChainOfThought" do
      for c <- 4..5 do
        assert {:ok, ChainOfThought} = Strategy.resolve(%{complexity: c})
      end
    end

    test "high complexity (6-7) falls back to TreeOfThoughts" do
      for c <- 6..7 do
        assert {:ok, TreeOfThoughts} = Strategy.resolve(%{complexity: c})
      end
    end

    test "very high complexity (8-9) falls back to Reflection" do
      for c <- 8..9 do
        assert {:ok, Reflection} = Strategy.resolve(%{complexity: c})
      end
    end

    test "extreme complexity (10) falls back to MCTS" do
      assert {:ok, MCTS} = Strategy.resolve(%{complexity: 10})
    end
  end

  # ── Strategy.resolve/1 — empty context ──────────────────────────

  describe "resolve/1 with empty context" do
    test "defaults to ReAct when no hints" do
      assert {:ok, ReAct} = Strategy.resolve(%{})
    end
  end

  # ── ReAct ───────────────────────────────────────────────────────

  describe "ReAct strategy" do
    test "implements behaviour callbacks" do
      assert ReAct.name() == :react
    end

    test "select? matches simple and action tasks" do
      assert ReAct.select?(%{task_type: :simple})
      assert ReAct.select?(%{task_type: :action})
      assert ReAct.select?(%{tools: [:some_tool]})
      assert ReAct.select?(%{complexity: 2})
      refute ReAct.select?(%{task_type: :debugging})
      refute ReAct.select?(%{complexity: 5})
    end

    test "init_state creates correct initial state" do
      state = ReAct.init_state(%{task: "test", max_iterations: 10})
      assert state.iteration == 0
      assert state.max_iterations == 10
      assert state.phase == :think
    end

    test "next_step cycles through think -> act -> observe" do
      state = ReAct.init_state(%{task: "do something"})
      context = %{task: "do something"}

      # Think phase
      {{:think, thought}, state} = ReAct.next_step(state, context)
      assert thought =~ "Analyzing task"
      assert state.phase == :act

      # Act phase
      {{:act, :pending, _meta}, state} = ReAct.next_step(state, context)
      assert state.phase == :observe

      # Observe phase
      {{:observe, _msg}, state} = ReAct.next_step(state, context)
      assert state.phase == :think
      assert state.iteration == 1
    end

    test "next_step returns :done at max iterations" do
      state = ReAct.init_state(%{max_iterations: 0})
      {{:done, result}, _state} = ReAct.next_step(state, %{})
      assert result.reason == :max_iterations
    end

    test "handle_result accumulates actions" do
      state = ReAct.init_state(%{})
      state = ReAct.handle_result({:act, :pending, %{}}, "tool_output", state)
      assert state.actions == ["tool_output"]
    end

    test "handle_result accumulates observations" do
      state = ReAct.init_state(%{})
      state = ReAct.handle_result({:observe, "msg"}, "result", state)
      assert state.observations == ["result"]
    end
  end

  # ── ChainOfThought ──────────────────────────────────────────────

  describe "ChainOfThought strategy" do
    test "implements behaviour callbacks" do
      assert ChainOfThought.name() == :chain_of_thought
    end

    test "select? matches analysis and research tasks" do
      assert ChainOfThought.select?(%{task_type: :analysis})
      assert ChainOfThought.select?(%{task_type: :research})
      assert ChainOfThought.select?(%{complexity: 4})
      refute ChainOfThought.select?(%{task_type: :simple})
    end

    test "init_state sets up reasoning phase" do
      state = ChainOfThought.init_state(%{task: "analyze this", verify: true})
      assert state.phase == :reason
      assert state.verify == true
      assert state.task == "analyze this"
    end

    test "next_step emits think prompt in reason phase" do
      state = ChainOfThought.init_state(%{task: "explain gravity"})
      {{:think, prompt}, new_state} = ChainOfThought.next_step(state, %{})
      assert prompt =~ "step-by-step"
      assert prompt =~ "FINAL ANSWER"
      assert new_state.phase == :parse
    end

    test "parse_steps extracts numbered steps" do
      text = """
      1. First step
      2. Second step
      3) Third step
      """

      steps = ChainOfThought.parse_steps(text)
      assert length(steps) == 3
      assert "First step" in steps
      assert "Second step" in steps
      assert "Third step" in steps
    end

    test "extract_final_answer finds FINAL ANSWER" do
      text = "Some reasoning\nFINAL ANSWER: The answer is 42."
      assert ChainOfThought.extract_final_answer(text) == "The answer is 42."
    end

    test "extract_final_answer returns nil when not present" do
      assert ChainOfThought.extract_final_answer("no answer here") == nil
    end

    test "handle_result stores reasoning and parsed steps" do
      state = ChainOfThought.init_state(%{task: "test"})
      state = %{state | phase: :parse}

      response = "1. Step one\n2. Step two\nFINAL ANSWER: Done"
      state = ChainOfThought.handle_result({:think, "prompt"}, response, state)

      assert length(state.steps) == 2
      assert state.final_answer == "Done"
      assert state.reasoning == response
    end
  end

  # ── TreeOfThoughts ──────────────────────────────────────────────

  describe "TreeOfThoughts strategy" do
    test "implements behaviour callbacks" do
      assert TreeOfThoughts.name() == :tree_of_thoughts
    end

    test "select? matches planning and design tasks" do
      assert TreeOfThoughts.select?(%{task_type: :planning})
      assert TreeOfThoughts.select?(%{task_type: :design})
      assert TreeOfThoughts.select?(%{task_type: :architecture})
      assert TreeOfThoughts.select?(%{complexity: 6})
      refute TreeOfThoughts.select?(%{task_type: :simple})
    end

    test "init_state defaults to 3 candidates" do
      state = TreeOfThoughts.init_state(%{task: "plan something"})
      assert state.num_candidates == 3
      assert state.phase == :generate
    end

    test "next_step emits generation prompt first" do
      state = TreeOfThoughts.init_state(%{task: "design API"})
      {{:think, prompt}, new_state} = TreeOfThoughts.next_step(state, %{})
      assert prompt =~ "Generate exactly 3"
      assert prompt =~ "APPROACH"
      assert new_state.phase == :evaluate
    end

    test "parse_approaches extracts formatted approaches" do
      text = """
      APPROACH 1: Direct API
      Build a REST API with standard CRUD.

      APPROACH 2: GraphQL
      Use GraphQL for flexible queries.

      APPROACH 3: gRPC
      Use gRPC for performance.
      """

      approaches = TreeOfThoughts.parse_approaches(text, 3)
      assert length(approaches) == 3
      assert Enum.any?(approaches, &(&1 =~ "Direct API"))
    end

    test "parse_ranking extracts comma-separated numbers" do
      text = "RANKING: 2, 1, 3"
      assert TreeOfThoughts.parse_ranking(text, 3) == [1, 0, 2]
    end

    test "parse_ranking returns default order when no RANKING found" do
      assert TreeOfThoughts.parse_ranking("no ranking here", 3) == [0, 1, 2]
    end
  end

  # ── Reflection ──────────────────────────────────────────────────

  describe "Reflection strategy" do
    test "implements behaviour callbacks" do
      assert Reflection.name() == :reflection
    end

    test "select? matches debugging and review tasks" do
      assert Reflection.select?(%{task_type: :debugging})
      assert Reflection.select?(%{task_type: :review})
      assert Reflection.select?(%{task_type: :refactor})
      assert Reflection.select?(%{complexity: 8})
      refute Reflection.select?(%{task_type: :simple})
    end

    test "init_state defaults to 3 max rounds" do
      state = Reflection.init_state(%{task: "fix bug"})
      assert state.max_rounds == 3
      assert state.phase == :generate
      assert state.round == 0
    end

    test "next_step starts with generate prompt" do
      state = Reflection.init_state(%{task: "debug issue"})
      {{:think, prompt}, new_state} = Reflection.next_step(state, %{})
      assert prompt =~ "thorough response"
      assert new_state.phase == :critique
    end

    test "substantive_critique? detects non-issues" do
      refute Reflection.substantive_critique?("NO ISSUES FOUND")
      refute Reflection.substantive_critique?("The response is excellent and complete.")
      refute Reflection.substantive_critique?("No significant problems detected.")
      refute Reflection.substantive_critique?(nil)
    end

    test "substantive_critique? detects real issues" do
      assert Reflection.substantive_critique?("The analysis misses edge cases in the error handling.")
      assert Reflection.substantive_critique?("Several logical errors were found.")
    end

    test "next_step emits :done when critique is non-substantive" do
      state = %{
        Reflection.init_state(%{task: "test"})
        | phase: :check_critique,
          content: "some content",
          current_critique: "NO ISSUES FOUND"
      }

      {{:done, result}, _state} = Reflection.next_step(state, %{})
      assert result.rounds == 0
      assert "NO ISSUES FOUND" in result.critiques
    end

    test "next_step emits revision prompt when critique is substantive" do
      state = %{
        Reflection.init_state(%{task: "test"})
        | phase: :check_critique,
          content: "some content",
          current_critique: "Missing error handling for nil inputs."
      }

      {{:think, prompt}, new_state} = Reflection.next_step(state, %{})
      assert prompt =~ "Revise"
      assert prompt =~ "Missing error handling"
      assert new_state.phase == :revise
    end
  end

  # ── MCTS ────────────────────────────────────────────────────────

  describe "MCTS strategy" do
    test "implements behaviour callbacks" do
      assert MCTS.name() == :mcts
    end

    test "select? matches exploration and optimization tasks" do
      assert MCTS.select?(%{task_type: :exploration})
      assert MCTS.select?(%{task_type: :optimization})
      assert MCTS.select?(%{task_type: :search})
      assert MCTS.select?(%{complexity: 10})
      refute MCTS.select?(%{task_type: :simple})
    end

    test "operations/0 returns 10 operations" do
      ops = MCTS.operations()
      assert length(ops) == 10
      assert :decompose in ops
      assert :verify in ops
      assert :synthesize in ops
    end

    test "operation_descriptions/0 describes all operations" do
      descs = MCTS.operation_descriptions()
      assert map_size(descs) == 10

      for op <- MCTS.operations() do
        assert Map.has_key?(descs, op), "Missing description for #{op}"
      end
    end

    test "init_state builds tree and configures search" do
      state = MCTS.init_state(%{task: "explore", iterations: 100, max_depth: 10, timeout: 5_000})
      assert state.phase == :search
      assert state.iterations == 100
      assert state.max_depth == 10
      assert state.timeout == 5_000
      assert state.tree != nil
      assert state.root_id == 0
    end

    test "next_step runs MCTS search and emits think prompt" do
      # Use small iteration count for speed
      state = MCTS.init_state(%{task: "solve problem", iterations: 50, max_depth: 5, timeout: 5_000})
      {{:think, prompt}, new_state} = MCTS.next_step(state, %{})

      assert prompt =~ "Monte Carlo Tree Search"
      assert prompt =~ "solve problem"
      assert new_state.phase == :done
      assert new_state.iterations_run > 0
      assert new_state.best_path != []
    end

    test "next_step returns :done after search phase" do
      state = MCTS.init_state(%{task: "test", iterations: 10, max_depth: 3, timeout: 5_000})
      {_step, state} = MCTS.next_step(state, %{})
      {{:done, result}, _state} = MCTS.next_step(state, %{})

      assert is_list(result.best_path)
      assert result.iterations > 0
      assert result.tree_size > 0
      assert result.root_visits > 0
    end
  end

  # ── MCTS.Simulation ─────────────────────────────────────────────

  describe "MCTS.Simulation" do
    alias Daemon.Agent.Strategies.MCTS.{Simulation, Tree}

    test "heuristic_score returns 0 for empty reasoning" do
      assert Simulation.heuristic_score(%{reasoning: []}) == 0.0
    end

    test "heuristic_score returns positive score for diverse operations" do
      state = %{reasoning: [:decompose, :analyze, :verify, :synthesize, :evaluate]}
      score = Simulation.heuristic_score(state)
      assert score > 0.0
      assert score <= 1.0
    end

    test "heuristic_score penalizes immediate repetition" do
      diverse = %{reasoning: [:decompose, :analyze, :verify, :synthesize]}
      repetitive = %{reasoning: [:decompose, :decompose, :decompose, :decompose]}

      assert Simulation.heuristic_score(diverse) > Simulation.heuristic_score(repetitive)
    end

    test "apply_operation advances state" do
      state = %{reasoning: [], insights: [], depth: 0}
      new_state = Simulation.apply_operation(state, :decompose)

      assert new_state.reasoning == [:decompose]
      assert length(new_state.insights) == 1
      assert new_state.depth == 1
    end

    test "select returns root when unexpanded" do
      {tree, root_id} = Tree.new(%{task: "test", reasoning: [], insights: [], depth: 0})
      assert Simulation.select(tree, root_id) == root_id
    end

    test "expand creates child nodes" do
      {tree, root_id} = Tree.new(%{task: "test", reasoning: [], insights: [], depth: 0})
      {tree, _child_id} = Simulation.expand(tree, root_id, 5)
      root = Tree.get(tree, root_id)
      assert root.expanded?
      assert length(root.children) == 10
    end

    test "backpropagate updates visits and wins" do
      {tree, root_id} = Tree.new(%{task: "test", reasoning: [], insights: [], depth: 0})
      {tree, child_id} = Simulation.expand(tree, root_id, 5)
      tree = Simulation.backpropagate(tree, child_id, 0.8)

      child = Tree.get(tree, child_id)
      assert child.visits == 1
      assert child.wins == 0.8

      root = Tree.get(tree, root_id)
      assert root.visits == 1
      assert root.wins == 0.8
    end

    test "simulate returns score in [0, 1]" do
      {tree, root_id} = Tree.new(%{task: "test", reasoning: [], insights: [], depth: 0})
      score = Simulation.simulate(tree, root_id, 5, nil)
      assert score >= 0.0
      assert score <= 1.0
    end
  end

  # ── MCTS.Tree ───────────────────────────────────────────────────

  describe "MCTS.Tree" do
    alias Daemon.Agent.Strategies.MCTS.Tree

    test "new creates tree with root node" do
      {tree, root_id} = Tree.new(%{task: "test"})
      assert root_id == 0
      root = Tree.get(tree, root_id)
      assert root.id == 0
      assert root.state == %{task: "test"}
      assert root.children == []
    end

    test "add_child creates child linked to parent" do
      {tree, root_id} = Tree.new(%{task: "test"})
      {tree, child_id} = Tree.add_child(tree, root_id, :analyze, %{task: "test", analyzed: true})

      assert child_id == 1
      child = Tree.get(tree, child_id)
      assert child.operation == :analyze
      assert child.parent == root_id
      assert child.depth == 1

      root = Tree.get(tree, root_id)
      assert child_id in root.children
    end

    test "get returns nil for nonexistent ID" do
      {tree, _} = Tree.new(%{})
      assert Tree.get(tree, 999) == nil
    end
  end
end
