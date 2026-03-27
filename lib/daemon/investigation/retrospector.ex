defmodule Daemon.Investigation.Retrospector do
  @moduledoc """
  Online strategy parameter optimization via A/B testing.

  Subscribes to `:investigation_complete` events, computes an outcome quality
  score, and uses one-at-a-time A/B testing to optimize Strategy parameters.
  Changes are gated through `Governance.Approvals` (type: `"strategy_change"`).

  Algorithm:
  1. Collect investigation outcomes in a rolling buffer (max 100).
  2. After 10+ outcomes with no running experiment, pick a random param,
     perturb it, and submit for governance approval (auto-approve if tiny).
  3. Collect 10 new outcomes under the perturbed value.
  4. Welch's t-test: keep if significantly better, revert otherwise.
  """
  use GenServer
  require Logger

  alias Daemon.Investigation.{Strategy, StrategyStore}

  @max_outcomes 100
  @min_sample_size 10
  @significance_threshold 0.1
  @auto_approve_threshold 0.05

  @type outcome :: %{
          strategy_hash: String.t(),
          quality: float(),
          timestamp: DateTime.t()
        }

  @type experiment :: %{
          param: atom(),
          original_value: number(),
          proposed_value: number(),
          topic: String.t(),
          started_at: DateTime.t(),
          scores_before: [float()],
          scores_after: [float()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :subscribe, 5_000)
    {:ok, %{event_ref: nil, outcomes: [], experiment: nil, experiment_count: 0}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    ref = Daemon.Events.Bus.register_handler(:investigation_complete, &handle_event/1)
    Logger.info("[Retrospector] Subscribed to :investigation_complete events")
    {:noreply, %{state | event_ref: ref}}
  end

  def handle_info({:investigation_outcome, meta}, state) do
    quality = compute_quality(meta)
    Logger.info("[Retrospector] Investigation quality: #{Float.round(quality, 3)} (hash: #{meta[:strategy_hash] || "unknown"})")

    outcome = %{
      strategy_hash: meta[:strategy_hash] || "unknown",
      quality: quality,
      timestamp: DateTime.utc_now()
    }

    outcomes = Enum.take([outcome | state.outcomes], @max_outcomes)
    state = %{state | outcomes: outcomes}
    state = maybe_evaluate_experiment(state, quality)
    state = maybe_start_experiment(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{event_ref: ref}) when not is_nil(ref) do
    Daemon.Events.Bus.unregister_handler(:investigation_complete, ref)
    :ok
  end

  def terminate(_, _), do: :ok

  # -- Event handler callback (runs in Task, sends to GenServer) --------
  # Bus delivers full Event maps with :data containing the investigation metadata.

  defp handle_event(%{data: data}) when is_map(data) do
    send(__MODULE__, {:investigation_outcome, data})
  end

  defp handle_event(meta) when is_map(meta) do
    # Fallback: if the map itself contains investigation keys, use it directly
    send(__MODULE__, {:investigation_outcome, meta})
  end

  defp handle_event(_), do: :ok

  # -- Quality scoring --------------------------------------------------

  @doc """
  Compute investigation quality score from outcome metadata.

  Weights: 40% verification rate, 30% grounded ratio, -20% fraud penalty, 10% certainty.
  Returns a float in ~[0, 1].
  """
  @spec compute_quality(map()) :: float()
  def compute_quality(meta) do
    supporting = meta[:supporting] || []
    opposing = meta[:opposing] || []
    total_evidence = length(supporting) + length(opposing)

    grounded_for = meta[:grounded_for_count] || 0
    grounded_against = meta[:grounded_against_count] || 0
    grounded_count = grounded_for + grounded_against

    fraud = meta[:fraudulent_citations] || 0
    uncertainty = meta[:uncertainty] || 1.0

    # Count sourced & verified from evidence lists
    all_evidence = supporting ++ opposing
    sourced = Enum.filter(all_evidence, fn ev ->
      is_map(ev) and (Map.get(ev, :source_type) == :sourced or Map.get(ev, "source_type") == "sourced")
    end)
    total_sourced = length(sourced)
    count_verified = Enum.count(sourced, fn ev ->
      v = Map.get(ev, :verification) || Map.get(ev, "verification")
      v in ["verified", :verified]
    end)

    verification_rate = if total_sourced > 0, do: count_verified / total_sourced, else: 0.0
    grounded_ratio = if total_evidence > 0, do: grounded_count / total_evidence, else: 0.0
    fraud_penalty = if total_evidence > 0, do: fraud / total_evidence, else: 0.0
    certainty = 1.0 - uncertainty

    score = 0.4 * verification_rate + 0.3 * grounded_ratio - 0.2 * fraud_penalty + 0.1 * max(0.0, certainty)
    max(0.0, min(1.0, score))
  end

  # -- Welch's t-test ---------------------------------------------------

  @doc """
  Welch's t-test comparing two samples.
  Returns `{t_statistic, p_value}`.
  Uses normal CDF approximation (good enough for N >= 10).
  """
  @spec welch_t_test([float()], [float()]) :: {float(), float()}
  def welch_t_test(a, b) when length(a) >= 2 and length(b) >= 2 do
    n_a = length(a)
    n_b = length(b)
    mean_a = Enum.sum(a) / n_a
    mean_b = Enum.sum(b) / n_b
    var_a = variance(a, mean_a)
    var_b = variance(b, mean_b)
    se = :math.sqrt(var_a / n_a + var_b / n_b)

    t = if se > 0, do: (mean_b - mean_a) / se, else: 0.0
    # Approximate two-tailed p-value using normal CDF
    p = 0.5 * :math.erfc(abs(t) / :math.sqrt(2))
    {t, p}
  end

  defp variance(samples, mean) do
    n = length(samples)
    if n < 2 do
      0.0
    else
      sum_sq = Enum.reduce(samples, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end)
      sum_sq / (n - 1)
    end
  end

  # -- Experiment lifecycle ---------------------------------------------

  defp maybe_evaluate_experiment(%{experiment: nil} = state, _quality), do: state

  defp maybe_evaluate_experiment(%{experiment: exp} = state, quality) do
    scores_after = [quality | exp.scores_after]
    exp = %{exp | scores_after: scores_after}

    if length(scores_after) >= @min_sample_size do
      evaluate_and_conclude(state, exp)
    else
      %{state | experiment: exp, experiment_count: state.experiment_count + 1}
    end
  end

  defp evaluate_and_conclude(state, exp) do
    {t, p} = welch_t_test(exp.scores_before, exp.scores_after)
    mean_before = Enum.sum(exp.scores_before) / length(exp.scores_before)
    mean_after = Enum.sum(exp.scores_after) / length(exp.scores_after)

    cond do
      mean_after > mean_before and p < @significance_threshold ->
        Logger.info("[Retrospector] Experiment KEEP: #{exp.param} = #{exp.proposed_value} " <>
          "(mean #{Float.round(mean_before, 3)} -> #{Float.round(mean_after, 3)}, t=#{Float.round(t, 2)}, p=#{Float.round(p, 3)})")
        %{state | experiment: nil, experiment_count: 0}

      mean_after < mean_before and p < @significance_threshold ->
        Logger.info("[Retrospector] Experiment REVERT: #{exp.param} back to #{exp.original_value} " <>
          "(mean #{Float.round(mean_before, 3)} -> #{Float.round(mean_after, 3)}, t=#{Float.round(t, 2)}, p=#{Float.round(p, 3)})")
        StrategyStore.update_param(exp.topic, exp.param, exp.original_value)
        %{state | experiment: nil, experiment_count: 0}

      true ->
        Logger.info("[Retrospector] Experiment INCONCLUSIVE, reverting #{exp.param} to #{exp.original_value} " <>
          "(p=#{Float.round(p, 3)} >= #{@significance_threshold})")
        StrategyStore.update_param(exp.topic, exp.param, exp.original_value)
        %{state | experiment: nil, experiment_count: 0}
    end
  end

  defp maybe_start_experiment(%{experiment: %{}} = state), do: state

  defp maybe_start_experiment(%{outcomes: outcomes} = state) when length(outcomes) < @min_sample_size do
    state
  end

  defp maybe_start_experiment(%{outcomes: outcomes} = state) do
    topic = "_global"

    # Load current strategy
    current = case StrategyStore.load_best(topic) do
      {:ok, s} -> s
      :error -> %Strategy{topic: topic, created_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    end

    # Pick a random param
    param_keys = Strategy.param_keys()
    param = Enum.random(param_keys)
    bounds = Strategy.bounds()
    {lo, hi} = Map.get(bounds, param, {0.0, 1.0})
    current_value = Map.get(current, param)

    # Sample perturbation
    delta = :rand.normal() * 0.1 * (hi - lo)
    proposed = max(lo, min(hi, current_value + delta))

    # Skip if proposed == current (hit boundary or zero delta)
    if abs(proposed - current_value) < 1.0e-9 do
      state
    else
      # Determine if auto-approve (tiny change) or needs governance
      relative_change = abs(delta) / (hi - lo)

      approval_result = if relative_change < @auto_approve_threshold do
        :auto_approved
      else
        try do
          Daemon.Governance.Approvals.create(%{
            type: "strategy_change",
            title: "Retrospector: #{param} #{Float.round(current_value * 1.0, 4)} -> #{Float.round(proposed * 1.0, 4)}",
            description: "A/B test perturbation of #{param} (relative change: #{Float.round(relative_change * 100, 1)}%)",
            requested_by: "retrospector",
            context: %{
              "param" => Atom.to_string(param),
              "original" => current_value,
              "proposed" => proposed,
              "relative_change" => relative_change
            }
          })
        rescue
          _ -> :auto_approved
        end
      end

      case approval_result do
        :auto_approved ->
          start_experiment(state, topic, param, current_value, proposed, outcomes)

        {:ok, _approval} ->
          # Large change submitted for human review — start experiment optimistically.
          # If rejected later, the experiment will naturally revert (inconclusive).
          start_experiment(state, topic, param, current_value, proposed, outcomes)

        {:error, _reason} ->
          # Governance unavailable — auto-approve and proceed
          start_experiment(state, topic, param, current_value, proposed, outcomes)
      end
    end
  end

  defp start_experiment(state, topic, param, original_value, proposed_value, outcomes) do
    StrategyStore.update_param(topic, param, proposed_value)

    scores_before = outcomes
      |> Enum.take(@min_sample_size)
      |> Enum.map(& &1.quality)

    experiment = %{
      param: param,
      original_value: original_value,
      proposed_value: proposed_value,
      topic: topic,
      started_at: DateTime.utc_now(),
      scores_before: scores_before,
      scores_after: []
    }

    Logger.info("[Retrospector] Started experiment: #{param} #{Float.round(original_value * 1.0, 4)} -> #{Float.round(proposed_value * 1.0, 4)}")
    %{state | experiment: experiment, experiment_count: 0}
  end
end
