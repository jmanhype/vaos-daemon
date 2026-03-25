defmodule Daemon.MCTS.NodeTest do
  use ExUnit.Case, async: true

  alias Daemon.MCTS.Node

  # ---------------------------------------------------------------------------
  # UCB1 selection
  # ---------------------------------------------------------------------------

  describe "ucb1/2" do
    test "returns :infinity for unvisited nodes" do
      node = %Node{path: "/test", type: :file, visits: 0, reward: 0.0}
      assert Node.ucb1(node, 10) == :infinity
    end

    test "returns 0.0 when parent_visits is 0" do
      node = %Node{path: "/test", type: :file, visits: 1, reward: 0.5}
      assert Node.ucb1(node, 0) == 0.0
    end

    test "calculates exploitation + exploration for visited nodes" do
      node = %Node{path: "/test", type: :file, visits: 10, reward: 5.0}
      score = Node.ucb1(node, 100)

      # exploitation = 5.0 / 10 = 0.5
      # exploration = sqrt(2) * sqrt(ln(100) / 10) ≈ 1.414 * sqrt(0.4605) ≈ 0.959
      # total ≈ 1.459
      assert is_float(score)
      assert score > 0.5  # exploitation alone
      assert score < 3.0  # sanity upper bound
    end

    test "higher reward means higher score (exploitation)" do
      high_reward = %Node{path: "/a", type: :file, visits: 10, reward: 8.0}
      low_reward = %Node{path: "/b", type: :file, visits: 10, reward: 2.0}

      assert Node.ucb1(high_reward, 100) > Node.ucb1(low_reward, 100)
    end

    test "fewer visits means higher exploration bonus" do
      many_visits = %Node{path: "/a", type: :file, visits: 100, reward: 50.0}
      few_visits = %Node{path: "/b", type: :file, visits: 2, reward: 1.0}

      # With same avg reward (0.5), fewer visits should have higher exploration
      score_many = Node.ucb1(many_visits, 200)
      score_few = Node.ucb1(few_visits, 200)

      # few_visits has avg 0.5 + large exploration term
      # many_visits has avg 0.5 + small exploration term
      assert score_few > score_many
    end

    test "unvisited nodes always win selection" do
      visited = %Node{path: "/a", type: :file, visits: 100, reward: 99.0}
      unvisited = %Node{path: "/b", type: :file, visits: 0, reward: 0.0}

      assert Node.ucb1(unvisited, 100) == :infinity
      assert Node.ucb1(visited, 100) < 1_000_000.0
    end
  end

  # ---------------------------------------------------------------------------
  # Average reward
  # ---------------------------------------------------------------------------

  describe "avg_reward/1" do
    test "returns 0.0 for zero visits" do
      node = %Node{path: "/test", type: :file, visits: 0, reward: 0.0}
      assert Node.avg_reward(node) == 0.0
    end

    test "returns correct average for visited node" do
      node = %Node{path: "/test", type: :file, visits: 4, reward: 2.0}
      assert Node.avg_reward(node) == 0.5
    end

    test "handles single visit" do
      node = %Node{path: "/test", type: :file, visits: 1, reward: 0.75}
      assert Node.avg_reward(node) == 0.75
    end

    test "handles high visit counts" do
      node = %Node{path: "/test", type: :file, visits: 10_000, reward: 5_000.0}
      assert Node.avg_reward(node) == 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # Struct defaults
  # ---------------------------------------------------------------------------

  describe "struct defaults" do
    test "new node has correct defaults" do
      node = %Node{path: "/test", type: :file}
      assert node.visits == 0
      assert node.reward == 0.0
      assert node.children == []
      assert node.expanded == false
      assert is_nil(node.content_summary)
      assert is_nil(node.parent)
    end
  end
end
