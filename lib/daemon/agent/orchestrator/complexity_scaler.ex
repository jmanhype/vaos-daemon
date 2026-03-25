defmodule Daemon.Agent.Orchestrator.ComplexityScaler do
  @moduledoc """
  Maps complexity scores to optimal agent counts with tier-aware ceilings.

  Score→Count mapping (Fibonacci-ish growth):
    1→1, 2→2, 3→3, 4→5, 5→8, 6→12, 7→18, 8→25, 9→35, 10→50

  Tier ceilings cap the result: elite→50, specialist→30, utility→10.
  User overrides ("use 25 agents") take priority, still capped at 50.
  """

  @complexity_map %{
    1 => 1,
    2 => 2,
    3 => 3,
    4 => 5,
    5 => 8,
    6 => 12,
    7 => 18,
    8 => 25,
    9 => 35,
    10 => 50
  }

  @tier_ceilings %{elite: 50, specialist: 30, utility: 10}

  @doc """
  Compute optimal agent count from complexity score, tier, and optional user override.

  - If `user_override` is a positive integer, it takes priority (capped at 50).
  - Otherwise, maps `score` (1-10) through the complexity table and caps by tier ceiling.
  """
  @spec optimal_agent_count(integer(), atom(), integer() | nil) :: pos_integer()
  def optimal_agent_count(_score, _tier, n) when is_integer(n) and n > 0, do: min(n, 50)

  def optimal_agent_count(score, tier, nil) do
    base = Map.get(@complexity_map, clamp(score, 1, 10), 5)
    ceiling = Map.get(@tier_ceilings, tier, 10)
    min(base, ceiling)
  end

  @doc """
  Detect explicit agent count intent from a user message.

  Matches patterns like "use 25 agents", "swarm of 10", "launch 5 agents",
  "spawn 8 agents", "deploy 3 agents", "dispatch 12".

  Returns the integer count (1-50) or nil if no intent detected.
  """
  @spec detect_agent_count_intent(String.t()) :: integer() | nil
  def detect_agent_count_intent(message) do
    patterns = [
      ~r/use\s+(\d+)\s+agents?/i,
      ~r/(\d+)\s+agents?\s+(?:to|for|on)/i,
      ~r/swarm\s+of\s+(\d+)/i,
      ~r/dispatch\s+(\d+)/i,
      ~r/launch\s+(\d+)\s+agents?/i,
      ~r/spawn\s+(\d+)\s+agents?/i,
      ~r/deploy\s+(\d+)\s+agents?/i
    ]

    Enum.find_value(patterns, fn regex ->
      case Regex.run(regex, message) do
        [_, count_str] ->
          case Integer.parse(count_str) do
            {n, _} when n > 0 and n <= 50 -> n
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp clamp(val, min_v, max_v), do: val |> max(min_v) |> min(max_v)
end
