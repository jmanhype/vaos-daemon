defmodule Daemon.Bandit.ThompsonSampling do
  @moduledoc """
  Thompson Sampling for multi-armed bandit problems.

  Provides Beta-Bernoulli Thompson Sampling implementation for multi-armed
  bandit problems. Each arm maintains a Beta(alpha, beta) posterior that is
  updated with rewards. The sampling algorithm balances exploration (trying
  less-tested arms) with exploitation (using high-performing arms).

  ## Algorithm

  For each arm with posterior Beta(α, β):
  1. Sample θᵢ ~ Beta(αᵢ, βᵢ) for all arms
  2. Select arm with max θᵢ
  3. Observe reward r ∈ [0, 1]
  4. Update posterior: αᵢ ← αᵢ + r, βᵢ ← βᵢ + (1 - r)

  The Beta distribution is sampled using the Marsaglia-Tsang method for
  gamma sampling combined with the relationship Beta(a,b) = Gamma(a) / (Gamma(a) + Gamma(b)).

  ## Usage

      # Initialize arms
      arms = %{arm1: %{alpha: 1.0, beta: 1.0}, arm2: %{alpha: 1.0, beta: 1.0}}

      # Select an arm
      {selected_arm, _sample} = select_arm(arms)

      # After observing outcome, update the arm
      reward = if success, do: 1.0, else: 0.0
      updated_arms = update_arm(arms, selected_arm, reward)

  ## Arm Initialization

  - Start with α = β = 1.0 (uniform prior)
  - Non-integer rewards are supported (continuous update)
  - For binary outcomes, use 1.0 for success, 0.0 for failure
  - For partial credit, use intermediate values (e.g., 0.7)

  ## Persistence

  Arms state can be serialized to JSON and persisted across restarts:

      arms_json = Jason.encode!(arms)
      restored_arms = Jason.decode!(arms_json, keys: :atoms)

  ## References

  - Agrawal, S., & Goyal, N. (2012). Analysis of Thompson Sampling for the Multi-armed Bandit Problem
  - Chapelle, O., & Li, L. (2011). An Empirical Evaluation of Thompson Sampling
  """

  @type arm_id :: term()
  @type arm :: %{alpha: float(), beta: float()}
  @type arms :: %{arm_id() => arm()}

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Select an arm using Thompson Sampling.

  Samples from Beta(α, β) for each arm and returns the arm with the highest
  sample value. Returns {arm_id, sample_value} tuple.

  ## Examples

      iex> arms = %{a: %{alpha: 10.0, beta: 2.0}, b: %{alpha: 2.0, beta: 10.0}}
      iex> {arm, _sample} = Daemon.Bandit.ThompsonSampling.select_arm(arms)
      iex> arm in [:a, :b]
      true

  """
  @spec select_arm(arms()) :: {arm_id(), float()}
  def select_arm(arms) when is_map(arms) do
    if map_size(arms) == 0 do
      raise ArgumentError, "Cannot select from empty arms map"
    end

    arms
    |> Enum.map(fn {id, arm} ->
      alpha = get_alpha(arm)
      beta = get_beta(arm)
      {id, sample_beta(alpha, beta)}
    end)
    |> Enum.max_by(fn {_id, sample} -> sample end)
  end

  @doc """
  Update an arm's posterior with observed reward.

  Updates the Beta posterior: α ← α + reward, β ← β + (1 - reward).
  Reward is clamped to [0, 1] range. Returns updated arms map.

  ## Examples

      iex> arms = %{a: %{alpha: 1.0, beta: 1.0}}
      iex> updated = Daemon.Bandit.ThompsonSampling.update_arm(arms, :a, 1.0)
      iex> updated[:a].alpha
      2.0

  """
  @spec update_arm(arms(), arm_id(), float()) :: arms()
  def update_arm(arms, arm_id, reward) when is_map(arms) and is_number(reward) do
    arm = Map.get(arms, arm_id, %{alpha: 1.0, beta: 1.0})
    clamped_reward = max(0.0, min(1.0, reward))

    updated = %{
      alpha: arm.alpha + clamped_reward,
      beta: arm.beta + (1.0 - clamped_reward)
    }

    Map.put(arms, arm_id, updated)
  end

  @doc """
  Get or create an arm's posterior.

  Returns the arm if it exists, otherwise creates a new arm with
  uniform prior (α = β = 1.0).

  ## Examples

      iex> arms = %{}
      iex> Daemon.Bandit.ThompsonSampling.get_arm(arms, :new)
      %{alpha: 1.0, beta: 1.0}

  """
  @spec get_arm(arms(), arm_id()) :: arm()
  def get_arm(arms, arm_id) do
    Map.get(arms, arm_id, default_arm())
  end

  @doc """
  Calculate the mean (expected value) of an arm's posterior.

  For Beta(α, β), the mean is α / (α + β).

  ## Examples

      iex> arm = %{alpha: 10.0, beta: 2.0}
      iex> Daemon.Bandit.ThompsonSampling.mean(arm)
      0.8333333333333333

  """
  @spec mean(arm()) :: float()
  def mean(%{alpha: alpha, beta: beta}) do
    alpha / (alpha + beta)
  end

  @doc """
  Calculate the sample variance of an arm's posterior.

  For Beta(α, β), the variance is (αβ) / ((α+β)²(α+β+1)).

  ## Examples

      iex> arm = %{alpha: 10.0, beta: 2.0}
      iex> Daemon.Bandit.ThompsonSampling.variance(arm) |> Float.round(4)
      0.0152

  """
  @spec variance(arm()) :: float()
  def variance(%{alpha: alpha, beta: beta}) do
    sum = alpha + beta
    (alpha * beta) / (:math.pow(sum, 2) * (sum + 1))
  end

  @doc """
  Calculate the confidence interval for an arm's posterior.

  Returns {lower_bound, upper_bound} for the specified confidence level
  (default 95%). Uses Beta distribution quantile approximation.

  ## Examples

      iex> arm = %{alpha: 10.0, beta: 2.0}
      iex> {lower, upper} = Daemon.Bandit.ThompsonSampling.confidence_interval(arm, 0.95)
      iex> lower < upper
      true

  """
  @spec confidence_interval(arm(), float()) :: {float(), float()}
  def confidence_interval(%{alpha: alpha, beta: beta}, confidence \\ 0.95) do
    # Approximation using Beta distribution mean ± z * std
    # For 95% CI, z ≈ 1.96
    z = z_score(confidence)
    mu = mean(%{alpha: alpha, beta: beta})
    sigma = :math.sqrt(variance(%{alpha: alpha, beta: beta}))

    lower = max(0.0, mu - z * sigma)
    upper = min(1.0, mu + z * sigma)
    {lower, upper}
  end

  @doc """
  Create a new arm with default prior (α = β = 1.0).

  ## Examples

      iex> Daemon.Bandit.ThompsonSampling.default_arm()
      %{alpha: 1.0, beta: 1.0}

  """
  @spec default_arm() :: arm()
  def default_arm, do: %{alpha: 1.0, beta: 1.0}

  @doc """
  Initialize an arms map with default priors.

  ## Examples

      iex> Daemon.Bandit.ThompsonSampling.init_arms([:a, :b, :c])
      %{a: %{alpha: 1.0, beta: 1.0}, b: %{alpha: 1.0, beta: 1.0}, c: %{alpha: 1.0, beta: 1.0}}

  """
  @spec init_arms([arm_id()]) :: arms()
  def init_arms(arm_ids) when is_list(arm_ids) do
    Map.new(arm_ids, fn id -> {id, default_arm()} end)
  end

  # ── Beta Distribution Sampling ─────────────────────────────────────

  @doc """
  Sample from a Beta distribution using the Beta-Gamma relationship.

  Beta(a, b) = Gamma(a) / (Gamma(a) + Gamma(b))

  Uses Marsaglia-Tsang method for gamma sampling.

  ## Examples

      iex> sample = Daemon.Bandit.ThompsonSampling.sample_beta(2.0, 5.0)
      iex> sample >= 0.0 and sample <= 1.0
      true

  """
  @spec sample_beta(float(), float()) :: float()
  def sample_beta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0 do
    x = sample_gamma(a)
    y = sample_gamma(b)

    if x + y == 0.0 do
      # Degenerate case — return 0.5
      0.5
    else
      x / (x + y)
    end
  end

  @doc """
  Sample from a Gamma distribution.

  Uses:
  - Marsaglia-Tsang method for a ≥ 1
  - Ahrens-Dieter method for a < 1 (boost: Gamma(a) = Gamma(a+1) * U^(1/a))

  ## Examples

      iex> sample = Daemon.Bandit.ThompsonSampling.sample_gamma(2.5)
      iex> sample > 0.0
      true

  """
  @spec sample_gamma(float()) :: float()
  def sample_gamma(a) when a < 1.0 do
    # Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
    sample_gamma(a + 1.0) * :math.pow(:rand.uniform(), 1.0 / a)
  end

  def sample_gamma(a) do
    # Marsaglia-Tsang squeeze method for a >= 1
    d = a - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)

    do_marsaglia_tsang(d, c)
  end

  # Marsaglia-Tsang method for gamma sampling (a >= 1)
  defp do_marsaglia_tsang(d, c) do
    # Box-Muller for standard normal
    x = box_muller_normal()
    v = 1.0 + c * x

    if v <= 0.0 do
      do_marsaglia_tsang(d, c)
    else
      v = v * v * v
      u = :rand.uniform()
      x_sq = x * x

      if u < 1.0 - 0.0331 * x_sq * x_sq do
        d * v
      else
        if :math.log(u) < 0.5 * x_sq + d * (1.0 - v + :math.log(v)) do
          d * v
        else
          do_marsaglia_tsang(d, c)
        end
      end
    end
  end

  # Box-Muller transform for standard normal sampling
  defp box_muller_normal do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp get_alpha(%{alpha: alpha}), do: alpha
  defp get_alpha(_), do: 1.0

  defp get_beta(%{beta: beta}), do: beta
  defp get_beta(_), do: 1.0

  # Approximate z-score for confidence level
  defp z_score(0.90), do: 1.645
  defp z_score(0.95), do: 1.96
  defp z_score(0.99), do: 2.576
  defp z_score(_), do: 1.96  # Default to 95%
end
