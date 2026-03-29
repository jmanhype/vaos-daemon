defmodule Daemon.Bandit do
  @moduledoc """
  Multi-Armed Bandit library for agent decision optimization.

  Provides unified algorithms (Thompson Sampling, UCB, Epsilon-Greedy)
  with pluggable persistence (JSON, ETS, Ecto) and telemetry integration.

  ## Data Structures

  * `arm()` - Individual bandit arm map: `%{alpha: float(), beta: float(), metadata: map()}`
  * `arms()` - Collection: `%{arm_id => arm()}`

  ## Core API

  * `select/3` - Select an arm using specified algorithm
  * `update/4` - Update arm with reward (auto-clamps to [0, 1])
  * `create_arms/2` - Create arms with uniform or custom priors

  ## Algorithms

  * `Daemon.Bandit.Thompson` - Thompson Sampling (Bayesian)
  * `Daemon.Bandit.UCB` - Upper Confidence Bound (optimism)
  * `Daemon.Bandit.EpsilonGreedy` - Epsilon-Greedy (exploration)

  ## Persistence

  * `Daemon.Bandit.Store` - JSON (default), ETS (fast), Ecto (scalable)

  ## Beta Sampling

  * `Daemon.Bandit.Beta` - Marsaglia-Tsang gamma sampling (pure Elixir)

  ## Telemetry

  Emits events:
  * `[:bandit, :arm_selected]` - `%{arm_id: term(), algorithm: atom()}`
  * `[:bandit, :arm_updated]` - `%{arm_id: term(), reward: float(), alpha: float(), beta: float()}`
  * `[:bandit, :reward_distribution]` - Summary statistics

  ## Example

      iex> arms = Daemon.Bandit.create_arms(["a", "b", "c"], alpha: 1, beta: 1)
      iex> {:ok, arm_id, arms} = Daemon.Bandit.select(arms, :thompson)
      iex> {:ok, arms} = Daemon.Bandit.update(arms, arm_id, 0.8)

  """
end
