defmodule Daemon.Investigation.RetrospectorTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.Retrospector

  # -- compute_quality/1 tests ------------------------------------------

  describe "compute_quality/1" do
    test "perfect investigation scores near 1.0" do
      meta = %{
        supporting: [
          %{source_type: :sourced, verification: "verified"},
          %{source_type: :sourced, verification: "verified"}
        ],
        opposing: [
          %{source_type: :sourced, verification: "verified"}
        ],
        grounded_for_count: 2,
        grounded_against_count: 1,
        fraudulent_citations: 0,
        uncertainty: 0.0
      }

      quality = Retrospector.compute_quality(meta)
      # Max score: 0.4*1.0 + 0.3*1.0 + 0.1*1.0 = 0.8
      assert quality >= 0.75
      assert quality <= 1.0
    end

    test "all-fraudulent investigation scores near 0" do
      meta = %{
        supporting: [
          %{source_type: :sourced, verification: "unverified"},
          %{source_type: :sourced, verification: "unverified"}
        ],
        opposing: [
          %{source_type: :sourced, verification: "unverified"}
        ],
        grounded_for_count: 0,
        grounded_against_count: 0,
        fraudulent_citations: 3,
        uncertainty: 1.0
      }

      quality = Retrospector.compute_quality(meta)
      assert quality <= 0.1
    end

    test "mixed investigation scores reasonable range" do
      meta = %{
        supporting: [
          %{source_type: :sourced, verification: "verified"},
          %{source_type: :sourced, verification: "unverified"}
        ],
        opposing: [
          %{source_type: :sourced, verification: "partial"}
        ],
        grounded_for_count: 1,
        grounded_against_count: 1,
        fraudulent_citations: 1,
        uncertainty: 0.4
      }

      quality = Retrospector.compute_quality(meta)
      assert quality > 0.1
      assert quality < 0.9
    end

    test "zero evidence returns 0" do
      meta = %{
        supporting: [],
        opposing: [],
        grounded_for_count: 0,
        grounded_against_count: 0,
        fraudulent_citations: 0,
        uncertainty: 1.0
      }

      quality = Retrospector.compute_quality(meta)
      assert quality == 0.0
    end

    test "handles missing keys gracefully" do
      quality = Retrospector.compute_quality(%{})
      assert is_float(quality)
      assert quality >= 0.0
      assert quality <= 1.0
    end

    test "string-keyed evidence maps work" do
      meta = %{
        supporting: [
          %{"source_type" => "sourced", "verification" => "verified"}
        ],
        opposing: [],
        grounded_for_count: 1,
        grounded_against_count: 0,
        fraudulent_citations: 0,
        uncertainty: 0.3
      }

      quality = Retrospector.compute_quality(meta)
      assert quality > 0.0
    end

    test "string-keyed top-level metadata with atom-valued source_type works" do
      meta = %{
        "supporting" => [
          %{"source_type" => :sourced, "verification" => "verified"}
        ],
        "opposing" => [],
        "grounded_for_count" => 1,
        "grounded_against_count" => 0,
        "fraudulent_citations" => 0,
        "uncertainty" => 0.0
      }

      quality = Retrospector.compute_quality(meta)
      assert quality >= 0.75
    end
  end

  # -- welch_t_test/2 tests ---------------------------------------------

  describe "welch_t_test/2" do
    test "identical samples yield p near 1.0" do
      a = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
      b = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
      {t, p} = Retrospector.welch_t_test(a, b)
      assert abs(t) < 0.001
      # p should be close to 0.5 (two-tailed) when t is 0
      assert p >= 0.4
    end

    test "clearly different samples yield low p" do
      a = [0.1, 0.12, 0.11, 0.09, 0.1, 0.11, 0.1, 0.12, 0.09, 0.1]
      b = [0.9, 0.88, 0.91, 0.89, 0.9, 0.91, 0.9, 0.88, 0.92, 0.9]
      {_t, p} = Retrospector.welch_t_test(a, b)
      assert p < 0.05
    end

    test "same mean different variance yields high p" do
      a = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
      b = [0.1, 0.9, 0.2, 0.8, 0.3, 0.7, 0.4, 0.6, 0.45, 0.55]
      {_t, p} = Retrospector.welch_t_test(a, b)
      assert p > 0.1
    end

    test "b > a yields positive t" do
      a = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3]
      b = [0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7]
      {t, _p} = Retrospector.welch_t_test(a, b)
      assert t > 0
    end
  end

  # -- GenServer lifecycle tests ----------------------------------------

  describe "GenServer" do
    test "starts and returns pid" do
      name = :"retrospector_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(Retrospector, [], name: name)
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "get_state shows initial empty state" do
      name = :"retrospector_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(Retrospector, [], name: name)
      state = :sys.get_state(pid)
      assert state.outcomes == []
      assert state.experiment == nil
      assert state.experiment_count == 0
      GenServer.stop(pid)
    end

    test "processes investigation_outcome message" do
      name = :"retrospector_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(Retrospector, [], name: name)

      meta = %{
        supporting: [%{source_type: :sourced, verification: "verified"}],
        opposing: [],
        grounded_for_count: 1,
        grounded_against_count: 0,
        fraudulent_citations: 0,
        uncertainty: 0.2,
        strategy_hash: "test_hash_123"
      }

      send(pid, {:investigation_outcome, meta})
      # Give it time to process
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert length(state.outcomes) == 1
      assert hd(state.outcomes).strategy_hash == "test_hash_123"
      GenServer.stop(pid)
    end

    test "outcomes buffer respects max size" do
      name = :"retrospector_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(Retrospector, [], name: name)

      # Send 105 outcomes (max is 100)
      for i <- 1..105 do
        meta = %{
          supporting: [],
          opposing: [],
          grounded_for_count: 0,
          grounded_against_count: 0,
          fraudulent_citations: 0,
          uncertainty: 0.5,
          strategy_hash: "hash_#{i}"
        }
        send(pid, {:investigation_outcome, meta})
      end

      Process.sleep(200)
      state = :sys.get_state(pid)
      assert length(state.outcomes) <= 100
      GenServer.stop(pid)
    end

    test "no experiment started with fewer than 10 outcomes" do
      name = :"retrospector_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(Retrospector, [], name: name)

      for i <- 1..5 do
        meta = %{
          supporting: [%{source_type: :sourced, verification: "verified"}],
          opposing: [],
          grounded_for_count: 1,
          grounded_against_count: 0,
          fraudulent_citations: 0,
          uncertainty: 0.3,
          strategy_hash: "hash_#{i}"
        }
        send(pid, {:investigation_outcome, meta})
      end

      Process.sleep(100)
      state = :sys.get_state(pid)
      assert state.experiment == nil
      GenServer.stop(pid)
    end
  end
end
