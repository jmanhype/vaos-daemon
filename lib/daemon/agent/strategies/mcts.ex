defmodule Daemon.Agent.Strategies.MCTS do
  @moduledoc """
  Monte Carlo Tree Search reasoning strategy.

  Reasons at the operation level (~10^6 search space) rather than token level.
  Uses UCT to balance exploration vs exploitation across 10 reasoning operations.

  Process:
  1. SELECT  — traverse tree using UCT to find promising leaf
  2. EXPAND  — add child nodes (possible next operations)
  3. SIMULATE — rollout from leaf to terminal state
  4. BACKPROPAGATE — update win/visit counts up the tree

  After N iterations, extract the best path and format as a reasoning plan.

  Best for: exploration tasks, optimization problems, complex search spaces.
  """

  @behaviour Daemon.Agent.Strategy

  alias Daemon.Agent.Strategies.MCTS.{Simulation, Tree}

  @default_iterations 1_000
  @default_max_depth 20
  @default_timeout 60_000

  @operation_descriptions %{
    decompose: "Break the problem into smaller sub-problems",
    analyze: "Examine components, relationships, and structure",
    synthesize: "Combine partial results into a coherent whole",
    compare: "Compare alternatives, trade-offs, or approaches",
    abstract: "Generalize from specifics to find broader patterns",
    specialize: "Apply general principles to the specific case",
    verify: "Check correctness, consistency, and completeness",
    refute: "Find counterexamples or weaknesses in reasoning",
    transform: "Reframe the problem or change representation",
    evaluate: "Assess quality, feasibility, and completeness"
  }

  @operations Map.keys(@operation_descriptions)

  # ── Behaviour Callbacks ──────────────────────────────────────────

  @impl true
  def name, do: :mcts

  @impl true
  def select?(%{task_type: type}) when type in [:exploration, :optimization, :search], do: true
  def select?(%{complexity: c}) when is_integer(c) and c >= 10, do: true
  def select?(_), do: false

  @impl true
  def init_state(context) do
    task = Map.get(context, :task, "")
    iterations = Map.get(context, :iterations, @default_iterations)
    max_depth = Map.get(context, :max_depth, @default_max_depth)
    timeout = Map.get(context, :timeout, @default_timeout)

    initial_state = %{task: task, reasoning: [], insights: [], depth: 0}
    {tree, root_id} = Tree.new(initial_state)

    %{
      phase: :search,
      task: task,
      iterations: iterations,
      max_depth: max_depth,
      timeout: timeout,
      scorer: Map.get(context, :scorer),
      tree: tree,
      root_id: root_id,
      best_path: [],
      iterations_run: 0,
      tree_size: 0
    }
  end

  @impl true
  def next_step(%{phase: :search} = state, _context) do
    start_time = System.monotonic_time(:millisecond)
    deadline = start_time + state.timeout

    {tree, iterations_run} =
      run_iterations(
        state.tree,
        state.root_id,
        state.iterations,
        state.max_depth,
        deadline,
        state.scorer,
        0
      )

    best_path = extract_best_path(tree, state.root_id)

    steps =
      best_path
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {op, i} ->
        desc = Map.get(@operation_descriptions, op, to_string(op))
        "#{i}. #{format_operation_name(op)}: #{desc}"
      end)

    prompt =
      "You are given a task and an optimal sequence of reasoning operations discovered " <>
        "via Monte Carlo Tree Search. Execute each step to produce a thorough solution.\n\n" <>
        "Task: #{state.task}\n\n" <>
        "Reasoning plan (#{length(best_path)} steps):\n#{steps}\n\n" <>
        "Execute this plan step by step. For each step, show your reasoning and findings. " <>
        "Conclude with a final synthesized answer."

    new_state = %{
      state
      | phase: :done,
        tree: tree,
        best_path: best_path,
        iterations_run: iterations_run,
        tree_size: tree.next_id
    }

    step = {:think, prompt}
    {step, new_state}
  end

  def next_step(%{phase: :done} = state, _context) do
    root = Tree.get(state.tree, state.root_id)

    result = %{
      best_path: Enum.map(state.best_path, &operation_description/1),
      iterations: state.iterations_run,
      tree_size: state.tree_size,
      root_visits: root.visits
    }

    {{:done, result}, state}
  end

  @impl true
  def handle_result(_step, _result, state), do: state

  # ── MCTS Loop ────────────────────────────────────────────────────

  defp run_iterations(tree, _root_id, 0, _max_depth, _deadline, _scorer, count) do
    {tree, count}
  end

  defp run_iterations(tree, root_id, remaining, max_depth, deadline, scorer, count) do
    if System.monotonic_time(:millisecond) >= deadline do
      {tree, count}
    else
      leaf_id = Simulation.select(tree, root_id)
      {tree, expand_id} = Simulation.expand(tree, leaf_id, max_depth)
      score = Simulation.simulate(tree, expand_id, max_depth, scorer)
      tree = Simulation.backpropagate(tree, expand_id, score)
      run_iterations(tree, root_id, remaining - 1, max_depth, deadline, scorer, count + 1)
    end
  end

  # ── Path Extraction ──────────────────────────────────────────────

  defp extract_best_path(tree, root_id) do
    root = Tree.get(tree, root_id)
    do_extract_best_path(tree, root)
  end

  defp do_extract_best_path(_tree, %{children: []}), do: []

  defp do_extract_best_path(tree, node) do
    best_child_id = Enum.max_by(node.children, fn cid -> Tree.get(tree, cid).visits end)
    best_child = Tree.get(tree, best_child_id)
    [best_child.operation | do_extract_best_path(tree, best_child)]
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp format_operation_name(op) do
    op |> Atom.to_string() |> String.capitalize()
  end

  defp operation_description(op) do
    %{
      operation: op,
      name: format_operation_name(op),
      description: Map.get(@operation_descriptions, op, "")
    }
  end

  # ── Public API ───────────────────────────────────────────────────

  @doc "Returns the list of available reasoning operations."
  @spec operations() :: [atom()]
  def operations, do: @operations

  @doc "Returns operation descriptions."
  @spec operation_descriptions() :: %{atom() => String.t()}
  def operation_descriptions, do: @operation_descriptions

  @doc "Delegate to Simulation for operation application."
  defdelegate apply_operation(state, op), to: Simulation

  @doc "Delegate to Simulation for heuristic scoring."
  defdelegate heuristic_score(state), to: Simulation
end
