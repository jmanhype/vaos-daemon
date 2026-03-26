defmodule OptimalSystemAgent.Investigation.Optimizer do
  @moduledoc """
  MCTS harness for investigation parameter optimization.

  Runs 200 iterations (5s timeout, depth 8) using the existing MCTS Tree/Node
  infrastructure with custom expand/simulate for investigation operations.
  FastProbe.score/2 provides the reward signal — no LLM calls, no API calls.

  Returns the winning strategy only if it beats the baseline EIG.
  """

  require Logger

  alias OptimalSystemAgent.Investigation.{Strategy, Operations, FastProbe, StrategyStore, Receipt}
  alias OptimalSystemAgent.Agent.Strategies.MCTS.{Tree, Node}

  @default_iterations 200
  @default_timeout 5_000
  @default_max_depth 8
  @exploration_constant :math.sqrt(2)

  @doc """
  Optimize investigation parameters using MCTS.

  Returns `{strategy, receipt}` where strategy is the winning (or baseline) strategy
  and receipt contains optimization metadata.
  """
  @spec optimize(map()) :: {Strategy.t(), Receipt.t()}
  def optimize(probe_ctx) do
    start_time = System.monotonic_time(:millisecond)
    topic = probe_ctx[:topic] || ""

    # Load prior strategy or use defaults
    base_strategy =
      case StrategyStore.load_best(topic) do
        {:ok, prior} ->
          %{prior | generation: prior.generation + 1, parent_hash: Strategy.param_hash(prior)}

        :error ->
          Strategy.default()
      end

    # Enrich paper_map with cached publisher scores for fast probing
    probe_ctx = enrich_probe_ctx(probe_ctx)

    # Score baseline
    baseline_eig = FastProbe.score(base_strategy, probe_ctx)

    # Initial state for MCTS
    initial_state = %{
      strategy: base_strategy,
      operations: [],
      depth: 0
    }

    {tree, root_id} = Tree.new(initial_state)
    deadline = start_time + @default_timeout

    # Run MCTS iterations
    {tree, iterations_run} =
      run_iterations(tree, root_id, probe_ctx, 0, @default_iterations, deadline, @default_max_depth)

    # Extract best path
    {best_strategy, best_path} = extract_best_strategy(tree, root_id)
    winning_eig = FastProbe.score(best_strategy, probe_ctx)

    elapsed = System.monotonic_time(:millisecond) - start_time
    tree_size = map_size(tree.nodes)

    # Determine winner with sanity checks
    {strategy, actual_winning_eig} =
      if winning_eig > baseline_eig and sane?(best_strategy, probe_ctx) do
        Logger.info(
          "[investigate:optimizer] MCTS #{iterations_run} iters in #{elapsed}ms. " <>
            "EIG: #{Float.round(baseline_eig, 3)} -> #{Float.round(winning_eig, 3)} " <>
            "(#{length(best_path)} mutations)"
        )

        winning = %{
          best_strategy
          | topic: topic,
            created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            parent_hash: Strategy.param_hash(base_strategy)
        }

        StrategyStore.save(winning)
        {winning, winning_eig}
      else
        Logger.info(
          "[investigate:optimizer] Baseline strategy was already optimal " <>
            "(#{iterations_run} iters, #{elapsed}ms)"
        )

        {base_strategy, baseline_eig}
      end

    # Build receipt
    receipt =
      Receipt.build(
        baseline_strategy: base_strategy,
        winning_strategy: strategy,
        baseline_eig: baseline_eig,
        winning_eig: actual_winning_eig,
        iterations_run: iterations_run,
        elapsed_ms: elapsed,
        tree_size: tree_size,
        best_path: best_path
      )

    {strategy, receipt}
  end

  # -- MCTS iteration loop -----------------------------------------------

  defp run_iterations(tree, _root_id, _probe_ctx, count, max_iters, _deadline, _max_depth)
       when count >= max_iters do
    {tree, count}
  end

  defp run_iterations(tree, root_id, probe_ctx, count, max_iters, deadline, max_depth) do
    if System.monotonic_time(:millisecond) >= deadline do
      {tree, count}
    else
      # SELECT
      leaf_id = select(tree, root_id)

      # EXPAND
      {tree, child_id} = expand(tree, leaf_id, max_depth)

      # SIMULATE
      score = simulate(tree, child_id, max_depth, probe_ctx)

      # BACKPROPAGATE
      tree = backpropagate(tree, child_id, score)

      run_iterations(tree, root_id, probe_ctx, count + 1, max_iters, deadline, max_depth)
    end
  end

  # -- UCT selection (mirrors Simulation.select but local for encapsulation) --

  defp select(tree, node_id) do
    node = Tree.get(tree, node_id)

    cond do
      not node.expanded? -> node_id
      node.children == [] -> node_id
      true ->
        best_child_id =
          Enum.max_by(node.children, fn child_id ->
            child = Tree.get(tree, child_id)
            uct(child, node.visits)
          end)

        select(tree, best_child_id)
    end
  end

  defp uct(%Node{visits: 0}, _parent_visits), do: :infinity

  defp uct(%Node{visits: visits, wins: wins}, parent_visits) do
    wins / visits + @exploration_constant * :math.sqrt(:math.log(parent_visits) / visits)
  end

  # -- Expand with investigation operations --------------------------------

  defp expand(tree, node_id, max_depth) do
    node = Tree.get(tree, node_id)

    if node.depth >= max_depth do
      tree = Tree.put(tree, %{node | expanded?: true})
      {tree, node_id}
    else
      existing_ops =
        MapSet.new(
          Enum.map(node.children, fn cid ->
            Tree.get(tree, cid).operation
          end)
        )

      untried = Enum.reject(Operations.operations(), &MapSet.member?(existing_ops, &1))

      {tree, child_ids} =
        Enum.reduce(untried, {tree, []}, fn op, {t, ids} ->
          new_strategy = Operations.apply_op(node.state.strategy, op)

          child_state = %{
            strategy: new_strategy,
            operations: node.state.operations ++ [op],
            depth: node.state.depth + 1
          }

          {t2, cid} = Tree.add_child(t, node_id, op, child_state)
          {t2, [cid | ids]}
        end)

      tree = Tree.put(tree, %{Tree.get(tree, node_id) | expanded?: true})

      selected =
        case child_ids do
          [] -> node_id
          ids -> Enum.random(ids)
        end

      {tree, selected}
    end
  end

  # -- Simulate: random rollout with FastProbe scoring ----------------------

  defp simulate(tree, node_id, max_depth, probe_ctx) do
    node = Tree.get(tree, node_id)
    rollout(node.state, node.depth, max_depth, probe_ctx)
  end

  defp rollout(state, depth, max_depth, probe_ctx) do
    if depth >= max_depth do
      FastProbe.score(state.strategy, probe_ctx)
    else
      op = Enum.random(Operations.operations())
      new_strategy = Operations.apply_op(state.strategy, op)

      new_state = %{
        state
        | strategy: new_strategy,
          operations: state.operations ++ [op],
          depth: state.depth + 1
      }

      rollout(new_state, depth + 1, max_depth, probe_ctx)
    end
  end

  # -- Backpropagate -------------------------------------------------------

  defp backpropagate(tree, node_id, score) do
    node = Tree.get(tree, node_id)
    updated = %{node | visits: node.visits + 1, wins: node.wins + score}
    tree = Tree.put(tree, updated)

    case updated.parent do
      nil -> tree
      parent_id -> backpropagate(tree, parent_id, score)
    end
  end

  # -- Extract best strategy by following most-visited path ----------------

  defp extract_best_strategy(tree, root_id) do
    path = extract_best_path(tree, root_id, [])

    node =
      if path == [] do
        Tree.get(tree, root_id)
      else
        {last_id, _op} = List.last(path)
        Tree.get(tree, last_id)
      end

    ops = Enum.map(path, fn {_id, op} -> op end)
    {node.state.strategy, ops}
  end

  defp extract_best_path(tree, node_id, acc) do
    node = Tree.get(tree, node_id)

    case node.children do
      [] ->
        acc

      children ->
        best_child_id =
          Enum.max_by(children, fn cid ->
            Tree.get(tree, cid).visits
          end)

        child = Tree.get(tree, best_child_id)
        extract_best_path(tree, best_child_id, acc ++ [{best_child_id, child.operation}])
    end
  end

  # -- Sanity checks: reject degenerate strategies -------------------------

  defp sane?(strategy, probe_ctx) do
    evidence =
      (probe_ctx[:verified_supporting] || []) ++ (probe_ctx[:verified_opposing] || [])

    paper_map = probe_ctx[:paper_map] || %{}

    {grounded, _belief} =
      Enum.split_with(evidence, fn ev ->
        sq = compute_source_quality(ev, paper_map, strategy)
        sq >= strategy.grounded_threshold
      end)

    total = length(evidence)

    cond do
      # No evidence to evaluate — strategy is fine
      total == 0 -> true
      # Everything filtered out — threshold too high
      length(grounded) == 0 -> false
      # Everything grounded (threshold too low) — only flag if >2 items
      length(grounded) == total and total > 2 -> false
      # Degenerate direction sensitivity
      strategy.direction_ratio > 1.8 -> false
      true -> true
    end
  end

  defp compute_source_quality(ev, paper_map, strategy) do
    case ev[:paper_ref] || Map.get(ev, :paper_ref) do
      nil ->
        0.15

      n ->
        case Map.get(paper_map, n) do
          nil ->
            0.1

          paper ->
            citations = paper["citation_count"] || paper["citationCount"] || 0
            cs = if citations > 0, do: :math.log10(citations) / 5.0, else: 0.0
            cs = min(cs, 1.0)
            ps = Map.get(paper, :_publisher_score, 0.3)
            cs * strategy.citation_weight + ps * strategy.publisher_weight
        end
    end
  end

  # -- Enrich probe context with cached publisher scores -------------------

  @doc false
  def enrich_probe_ctx(probe_ctx) do
    paper_map = probe_ctx[:paper_map] || %{}

    enriched =
      Map.new(paper_map, fn {k, paper} ->
        if Map.has_key?(paper, :_publisher_score) do
          {k, paper}
        else
          ps = compute_publisher_score(paper)
          {k, Map.put(paper, :_publisher_score, ps)}
        end
      end)

    Map.put(probe_ctx, :paper_map, enriched)
  end

  # Quick publisher score — computed once and cached in paper_map.
  # Mirrors the logic in investigate.ex but simplified for fast evaluation.
  defp compute_publisher_score(paper) do
    title = (paper["title"] || "") |> String.downcase()
    source = (paper["source"] || "") |> String.downcase()
    abstract = (paper["abstract"] || "") |> String.downcase()
    all_text = "#{title} #{source} #{abstract}"

    cond do
      Regex.match?(
        ~r/journal.of.alternative|complementary.*medicine|integrative.*medicine/i,
        source
      ) ->
        0.05

      Regex.match?(~r/systematic\s+review|meta[\-\s]?analysis|cochrane/i, title) ->
        0.8

      Regex.match?(
        ~r/\bnature\b|\blancet\b|\bbmj\b|\bnejm\b|\bcochrane\b|\bjama\b|\bplos\b|\bpnas\b/i,
        all_text
      ) ->
        0.8

      Regex.match?(
        ~r/\bwiley\b|\bspringer\b|\belsevier\b|\boxford\b|\bcambridge\b|\bieee\b|\bacm\b/i,
        all_text
      ) ->
        0.8

      true ->
        0.3
    end
  end
end
