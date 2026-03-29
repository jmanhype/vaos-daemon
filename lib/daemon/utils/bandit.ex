defmodule Daemon.Utils.Bandit do
  @moduledoc """
  Multi-armed bandit utilities for Thompson Sampling.

  Provides Beta distribution sampling for Thompson Sampling, a Bayesian
  approach to the exploration-exploitation tradeoff in multi-armed bandit
  problems. Each arm maintains a Beta(α, β) posterior representing the
  probability distribution of its expected reward.

  ## Thompson Sampling

  Thompson Sampling selects an arm by:
  1. Drawing a sample from each arm's Beta posterior
  2. Selecting the arm with the highest sample

  This naturally balances exploration (sampling uncertain arms) and
  exploitation (favoring arms with high expected rewards).

  ## Usage

      # Initialize arms with uniform priors: Beta(1, 1)
      arms = %{arm_a: %{alpha: 1, beta: 1}, arm_b: %{alpha: 1, beta: 1}}

      # Select an arm using Thompson Sampling
      {selected_arm, _score} =
        arms
        |> Enum.map(fn {id, arm} ->
          {id, Daemon.Utils.Bandit.sample_beta(arm.alpha, arm.beta)}
        end)
        |> Enum.max_by(fn {_id, sample} -> sample end)

      # Update posterior after observing reward
      # reward: 1 for success, 0 for failure
      arms = Map.update!(arms, selected_arm, fn arm ->
        %{arm | alpha: arm.alpha + reward, beta: arm.beta + (1 - reward)}
      end)

  ## Implementation

  Beta sampling uses the Marsaglia-Tsang method for Gamma(a, 1) when a ≥ 1,
  and the Ahrens-Dieter method for a < 1. Beta(a, b) = Gamma(a) / (Gamma(a) + Gamma(b)).

  References:
  - Agrawal, S., & Goyal, N. (2012). Analysis of Thompson sampling for the multi-armed bandit problem
  - Marsaglia, G., & Tsang, W. W. (2000). A simple method for generating Gamma variables
  """

  @doc """
  Sample from a Beta distribution using the ratio-of-Gammas method.

  Beta(a, b) ~ Gamma(a) / (Gamma(a) + Gamma(b))

  ## Parameters
    * `a` - Alpha parameter (shape), must be > 0
    * `b` - Beta parameter (shape), must be > 0

  ## Returns
    * A float in the range (0, 1)

  ## Examples

      iex> Daemon.Utils.Bandit.sample_beta(1.0, 1.0)
      # Returns uniform sample from (0, 1)

      iex> Daemon.Utils.Bandit.sample_beta(10.0, 1.0)
      # Biased toward high values (high confidence of success)

      iex> Daemon.Utils.Bandit.sample_beta(1.0, 10.0)
      # Biased toward low values (high confidence of failure)

  """
  @spec sample_beta(float(), float()) :: float()
  def sample_beta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0 do
    x = sample_gamma(a)
    y = sample_gamma(b)

    if x + y == 0.0 do
      # Degenerate case — return 0.5 (neutral)
      0.5
    else
      x / (x + y)
    end
  end

  @doc """
  Sample from a Gamma distribution with shape parameter `a` and scale 1.

  Uses Marsaglia-Tsang for a ≥ 1, Ahrens-Dieter for a < 1.

  ## Parameters
    * `a` - Shape parameter, must be > 0

  ## Returns
    * A positive float

  """
  @spec sample_gamma(float()) :: float()
  def sample_gamma(a) when a < 1.0 do
    # Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
    # Boosts shape to ≥ 1, then scales back down
    sample_gamma(a + 1.0) * :math.pow(:rand.uniform(), 1.0 / a)
  end

  def sample_gamma(a) when a >= 1.0 do
    # Marsaglia-Tsang squeeze method for a >= 1
    d = a - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)

    do_marsaglia_tsang(d, c)
  end

  # Marsaglia-Tsang rejection sampling
  defp do_marsaglia_tsang(d, c) do
    # Box-Muller transform for standard normal
    x = box_muller_normal()
    v = 1.0 + c * x

    if v <= 0.0 do
      # Reject and retry
      do_marsaglia_tsang(d, c)
    else
      v = v * v * v
      u = :rand.uniform()
      x_sq = x * x

      # Squeeze test (fast accept)
      if u < 1.0 - 0.0331 * x_sq * x_sq do
        d * v
      else
        # Log test (exact accept/reject)
        if :math.log(u) < 0.5 * x_sq + d * (1.0 - v + :math.log(v)) do
          d * v
        else
          # Reject and retry
          do_marsaglia_tsang(d, c)
        end
      end
    end
  end

  # Box-Muller transform: generates standard normal (mean=0, std=1)
  defp box_muller_normal do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end

  @doc """
  Calculate the mean of a Beta distribution: μ = α / (α + β)

  ## Parameters
    * `alpha` - Alpha parameter (shape), must be > 0
    * `beta` - Beta parameter (shape), must be > 0

  ## Returns
    * The expected value (mean) of the Beta distribution

  ## Examples

      iex> Daemon.Utils.Bandit.beta_mean(1.0, 1.0)
      0.5

      iex> Daemon.Utils.Bandit.beta_mean(10.0, 1.0)
      0.9090909090909091

  """
  @spec beta_mean(float(), float()) :: float()
  def beta_mean(alpha, beta) when is_number(alpha) and is_number(beta) and alpha > 0 and beta > 0 do
    alpha / (alpha + beta)
  end

  @doc """
  Select the best arm using Thompson Sampling.

  Takes a map of arms with their Beta posterior parameters and returns
  the arm ID with the highest Thompson sample.

  ## Parameters
    * `arms` - A map where keys are arm IDs and values are maps with `:alpha` and `:beta`

  ## Returns
    * `{{arm_id, arm_data}, sample}` - The selected arm with its posterior and the sample value

  ## Examples

      arms = %{
        arm_a: %{alpha: 10, beta: 2},  # High success rate
        arm_b: %{alpha: 3, beta: 5}    # Lower success rate
      }

      {{:arm_a, arm}, sample} = Daemon.Utils.Bandit.select_arm(arms)

  """
  @spec select_arm(map()) :: {{atom(), map()}, float()}
  def select_arm(arms) when is_map(arms) and map_size(arms) > 0 do
    arms
    |> Enum.map(fn {arm_id, arm} ->
      alpha = Map.get(arm, :alpha, arm["alpha"] || 1)
      beta = Map.get(arm, :beta, arm["beta"] || 1)
      sample = sample_beta(alpha * 1.0, beta * 1.0)
      {{arm_id, arm}, sample}
    end)
    |> Enum.max_by(fn {_arm_and_data, sample} -> sample end)
  end

  @doc """
  Update a Beta posterior with observed outcomes.

  Increments α by the number of successes and β by the number of failures.

  ## Parameters
    * `arm` - Map with `:alpha` and `:beta` keys
    * `successes` - Number of positive outcomes (non-negative integer)
    * `failures` - Number of negative outcomes (non-negative integer)

  ## Returns
    * Updated arm map with incremented α and β

  ## Examples

      arm = %{alpha: 1, beta: 1}
      Daemon.Utils.Bandit.update_posterior(arm, 5, 2)
      # => %{alpha: 6, beta: 3}

  """
  @spec update_posterior(map(), non_neg_integer(), non_neg_integer()) :: map()
  def update_posterior(arm, successes, failures)
      when is_map(arm) and is_integer(successes) and successes >= 0 and
           is_integer(failures) and failures >= 0 do
    arm
    |> Map.update!(:alpha, &(&1 + successes))
    |> Map.update!(:beta, &(&1 + failures))
  end

  @doc """
  Format a Beta distribution for display.

  Returns a string like "Beta(10.0, 3.0) μ=0.77"

  ## Parameters
    * `alpha` - Alpha parameter
    * `beta` - Beta parameter

  ## Returns
    * Formatted string representation

  """
  @spec format_beta(float(), float()) :: String.t()
  def format_beta(alpha, beta) when is_number(alpha) and is_number(beta) do
    mean = beta_mean(alpha, beta)
    "Beta(#{Float.round(alpha, 1)}, #{Float.round(beta, 1)}) μ=#{Float.round(mean, 3)}"
  end
end
