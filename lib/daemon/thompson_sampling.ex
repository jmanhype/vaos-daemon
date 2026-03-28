defmodule Daemon.ThompsonSampling do
  @moduledoc """
  Thompson Sampling library for multi-armed bandit problems.

  Thompson Sampling is a Bayesian approach to the multi-armed bandit problem
  that balances exploration and exploitation by sampling from the posterior
  distribution of each arm's reward probability.

  This module provides Beta-Binomial Thompson Sampling, where each arm is
  modeled with a Beta(α, β) posterior distribution. After each trial, the
  posterior is updated: α += reward, β += (1 - reward).

  ## Features

  - Beta distribution sampling using Marsaglia-Tsang method (a >= 1)
  - Gamma sampling with Ahrens-Dieter boost (a < 1)
  - Support for continuous quality signals (0.0 - 1.0), not just binary outcomes
  - Multiple arms selection (rank by sampled values)

  ## Usage

      # Initialize arms
      arms = %{
        variant_a: %{alpha: 1.0, beta: 1.0},
        variant_b: %{alpha: 1.0, beta: 1.0}
      }

      # Sample from each arm's posterior and select best
      {best_arm, _sample} = ThompsonSampling.select_arm(arms)

      # Update after observing outcome
      quality = 0.85  # Continuous quality signal (0.0 - 1.0)
      updated_arms = ThompsonSampling.update_arm(arms, best_arm, quality)

  ## Mathematical Background

  For Beta-Binomial Thompson Sampling:
  - Prior: Beta(α₀, β₀) — typically Beta(1, 1) for uniform prior
  - Posterior after reward r ∈ [0, 1]: Beta(α₀ + r, β₀ + (1 - r))
  - Sample θᵢ ~ Beta(αᵢ, βᵢ) for each arm i
  - Select arm with max θᵢ

  The continuous reward formulation makes learning ~5-10x more data-efficient
  than binary success/failure. A quality-0.95 outcome contributes 19x more
  to α than a quality-0.05 outcome.

  ## References

  - Agrawal, S., & Goyal, N. (2012). Analysis of Thompson Sampling for the Multi-armed Bandit Problem
  - Chapelle, O., & Li, L. (2011). An Empirical Evaluation of Thompson Sampling
  """

  @type arm :: %{alpha: float(), beta: float()}
  @type arms :: %{optional(atom() | String.t()) => arm()}

  @doc """
  Sample from Beta(α, β) distribution.

  Uses the gamma relationship: Beta(α, β) = Gamma(α) / (Gamma(α) + Gamma(β))

  ## Parameters
    - `a`: Alpha parameter (shape 1), must be > 0
    - `b`: Beta parameter (shape 2), must be > 0

  ## Returns
    Float in (0, 1)

  ## Examples

      iex> sample = ThompsonSampling.sample_beta(1.0, 1.0)
      iex> sample > 0.0 and sample < 1.0
      true

      iex> sample = ThompsonSampling.sample_beta(5.0, 2.0)
      iex> sample > 0.0 and sample < 1.0
      true
  """
  @spec sample_beta(float(), float()) :: float()
  def sample_beta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0 do
    x = sample_gamma(a / 1)
    y = sample_gamma(b / 1)

    if x + y == 0.0 do
      # Degenerate case — return 0.5
      0.5
    else
      x / (x + y)
    end
  end

  @doc """
  Select the best arm using Thompson Sampling.

  Samples from each arm's Beta posterior and returns the arm with the highest
  sampled value along with its sample.

  ## Parameters
    - `arms`: Map of arm_id => %{alpha: float(), beta: float()}

  ## Returns
    {arm_id, sample_value} or nil if arms is empty

  ## Examples

      arms = %{
        variant_a: %{alpha: 5.0, beta: 2.0},
        variant_b: %{alpha: 3.0, beta: 4.0}
      }
      {best_arm, sample} = ThompsonSampling.select_arm(arms)
      # best_arm is either :variant_a or :variant_b
      # sample is the sampled value from Beta(α, β)
  """
  @spec select_arm(arms()) :: {atom() | String.t(), float()} | nil
  def select_arm(arms) when is_map(arms) and map_size(arms) > 0 do
    arms
    |> Enum.map(fn {id, arm} ->
      alpha = Map.get(arm, :alpha, arm["alpha"] || 1.0)
      beta = Map.get(arm, :beta, arm["beta"] || 1.0)
      {id, sample_beta(alpha, beta)}
    end)
    |> Enum.max_by(fn {_id, sample} -> sample end)
  end

  def select_arm(_), do: nil

  @doc """
  Rank arms by their Thompson Samples.

  Returns a list of {arm_id, sample_value} sorted by sample value descending.

  ## Parameters
    - `arms`: Map of arm_id => %{alpha: float(), beta: float()}

  ## Returns
    List of {arm_id, sample_value} sorted by sample descending

  ## Examples

      arms = %{
        emergent: %{alpha: 8.0, beta: 3.0},
        policy: %{alpha: 5.0, beta: 2.0}
      }
      ranked = ThompsonSampling.rank_arms(arms)
      # ranked might be: [emergent: 0.72, policy: 0.68]
  """
  @spec rank_arms(arms()) :: [{atom() | String.t(), float()}]
  def rank_arms(arms) when is_map(arms) do
    arms
    |> Enum.map(fn {id, arm} ->
      alpha = Map.get(arm, :alpha, arm["alpha"] || 1.0)
      beta = Map.get(arm, :beta, arm["beta"] || 1.0)
      {id, sample_beta(alpha, beta)}
    end)
    |> Enum.sort_by(fn {_id, sample} -> -sample end)
  end

  @doc """
  Update an arm's Beta posterior after observing an outcome.

  Supports continuous quality signals (0.0 - 1.0) for more data-efficient
  learning than binary success/failure.

  ## Parameters
    - `arms`: Map of arms
    - `arm_id`: Which arm to update
    - `reward`: Observed reward in [0, 1]

  ## Returns
    Updated arms map

  ## Examples

      arms = %{variant_a: %{alpha: 1.0, beta: 1.0}}
      # After observing quality 0.85
      updated = ThompsonSampling.update_arm(arms, :variant_a, 0.85)
      # updated.variant_a == %{alpha: 1.85, beta: 1.15}

  The Beta distribution posterior remains valid with non-integer parameters,
  allowing fine-grained quality signals.
  """
  @spec update_arm(arms(), atom() | String.t(), float()) :: arms()
  def update_arm(arms, arm_id, reward) when is_map(arms) and is_number(reward) do
    arm = Map.get(arms, arm_id, %{alpha: 1.0, beta: 1.0})

    # Clamp reward to [0, 1] to maintain valid Beta parameters
    clamped = max(0.0, min(1.0, reward))

    updated = %{
      alpha: arm.alpha + clamped,
      beta: arm.beta + (1.0 - clamped)
    }

    Map.put(arms, arm_id, updated)
  end

  @doc """
  Create a new arm with optional initial parameters.

  ## Parameters
    - `alpha`: Initial alpha (default: 1.0 for uniform prior)
    - `beta`: Initial beta (default: 1.0 for uniform prior)

  ## Returns
    A new arm map

  ## Examples

      ThompsonSampling.new_arm()
      # => %{alpha: 1.0, beta: 1.0}

      ThompsonSampling.new_arm(5.0, 2.0)
      # => %{alpha: 5.0, beta: 2.0}
  """
  @spec new_arm(number(), number()) :: arm()
  def new_arm(alpha \\ 1.0, beta \\ 1.0) do
    %{alpha: alpha * 1.0, beta: beta * 1.0}
  end

  @doc """
  Calculate the mean of a Beta distribution.

  The mean represents the expected value of the arm's reward probability.

  ## Parameters
    - `arm`: %{alpha: float(), beta: float()}

  ## Returns
    Mean value in (0, 1)

  ## Examples

      arm = %{alpha: 5.0, beta: 2.0}
      ThompsonSampling.arm_mean(arm)
      # => 0.714...
  """
  @spec arm_mean(arm()) :: float()
  def arm_mean(%{alpha: a, beta: b}) when is_number(a) and is_number(b) and a + b > 0 do
    a / (a + b)
  end

  @doc """
  Format an arm for display/logging.

  ## Examples

      arm = %{alpha: 8.5, beta: 3.2}
      ThompsonSampling.format_arm(arm)
      # => "Beta(8.5, 3.2) μ=0.727"
  """
  @spec format_arm(arm()) :: String.t()
  def format_arm(%{alpha: a, beta: b}) do
    mean = Float.round(a / (a + b), 3)
    "Beta(#{Float.round(a, 1)}, #{Float.round(b, 1)}) μ=#{mean}"
  end

  # ── Private: Gamma Sampling ─────────────────────────────────────────

  # Gamma sampling: Marsaglia-Tsang for a >= 1, Ahrens-Dieter boost for a < 1
  defp sample_gamma(a) when a < 1.0 do
    # Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
    sample_gamma(a + 1.0) * :math.pow(:rand.uniform(), 1.0 / a)
  end

  defp sample_gamma(a) do
    # Marsaglia-Tsang squeeze method for a >= 1
    d = a - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)

    do_marsaglia_tsang(d, c)
  end

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

  defp box_muller_normal do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end
end
