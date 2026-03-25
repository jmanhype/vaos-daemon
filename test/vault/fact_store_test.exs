defmodule Daemon.Vault.FactStoreTest do
  use ExUnit.Case, async: false

  alias Daemon.Vault.FactStore

  setup do
    # Clear the ETS table between tests to get clean state.
    # The FactStore GenServer is already started by the application supervisor.
    try do
      :ets.delete_all_objects(:daemon_vault_facts)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "store/1 and active_facts/0" do
    test "stores a fact and retrieves it" do
      FactStore.store(%{type: "decision", value: "Use Elixir", confidence: 0.85})
      Process.sleep(50)

      facts = FactStore.active_facts()
      assert length(facts) >= 1
      assert Enum.any?(facts, fn f -> f[:value] == "Use Elixir" end)
    end

    test "stored fact has id, stored_at, and valid_until" do
      FactStore.store(%{type: "fact", value: "BEAM VM", confidence: 0.9})
      Process.sleep(50)

      [fact | _] = FactStore.active_facts()
      assert is_binary(fact[:id])
      assert is_binary(fact[:stored_at])
      assert fact[:valid_until] == nil
    end

    test "stores multiple facts" do
      FactStore.store(%{type: "fact", value: "Fact 1", confidence: 0.7})
      FactStore.store(%{type: "lesson", value: "Lesson 1", confidence: 0.8})
      FactStore.store(%{type: "decision", value: "Decision 1", confidence: 0.85})
      Process.sleep(50)

      facts = FactStore.active_facts()
      assert length(facts) == 3
    end
  end

  describe "facts_by_type/1" do
    test "returns only facts of the specified type" do
      FactStore.store(%{type: "decision", value: "Use Elixir", confidence: 0.85})
      FactStore.store(%{type: "fact", value: "Runs on BEAM", confidence: 0.9})
      FactStore.store(%{type: "decision", value: "Use PostgreSQL", confidence: 0.8})
      Process.sleep(50)

      decisions = FactStore.facts_by_type("decision")
      assert length(decisions) == 2
      assert Enum.all?(decisions, fn f -> f[:type] == "decision" end)
    end

    test "returns empty list for nonexistent type" do
      facts = FactStore.facts_by_type("nonexistent")
      assert facts == []
    end

    test "includes superseded facts" do
      FactStore.store(%{type: "fact", value: "port is 4000", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "fact", value: "port is 4000", confidence: 0.9})
      Process.sleep(50)

      all_facts = FactStore.facts_by_type("fact")
      assert length(all_facts) == 2
    end
  end

  describe "search/1" do
    test "finds facts by value substring" do
      FactStore.store(%{type: "fact", value: "Elixir on BEAM", confidence: 0.9})
      FactStore.store(%{type: "fact", value: "Python scripting", confidence: 0.7})
      Process.sleep(50)

      results = FactStore.search("BEAM")
      assert length(results) == 1
      assert hd(results)[:value] == "Elixir on BEAM"
    end

    test "case-insensitive search" do
      FactStore.store(%{type: "fact", value: "Docker containerization", confidence: 0.8})
      Process.sleep(50)

      results = FactStore.search("docker")
      assert length(results) == 1
    end

    test "returns empty list when nothing matches" do
      FactStore.store(%{type: "fact", value: "Elixir", confidence: 0.9})
      Process.sleep(50)

      results = FactStore.search("zzzznonexistent")
      assert results == []
    end

    test "only searches active facts" do
      FactStore.store(%{type: "fact", value: "port is 4000", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "fact", value: "port is 4000", confidence: 0.9})
      Process.sleep(50)

      results = FactStore.search("port is 4000")
      assert length(results) == 1
    end
  end

  describe "count/0" do
    test "returns 0 when empty" do
      assert FactStore.count() == 0
    end

    test "returns count of active facts" do
      FactStore.store(%{type: "fact", value: "A", confidence: 0.7})
      FactStore.store(%{type: "fact", value: "B", confidence: 0.7})
      FactStore.store(%{type: "fact", value: "C", confidence: 0.7})
      Process.sleep(50)

      assert FactStore.count() == 3
    end

    test "does not count superseded facts" do
      FactStore.store(%{type: "fact", value: "port 4000", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "fact", value: "port 4000", confidence: 0.9})
      Process.sleep(50)

      assert FactStore.count() == 1
    end
  end

  describe "temporal superseding" do
    test "supersedes existing fact with same type+value" do
      FactStore.store(%{type: "decision", value: "Use Redis", confidence: 0.8})
      Process.sleep(50)

      FactStore.store(%{type: "decision", value: "Use Redis", confidence: 0.9})
      Process.sleep(50)

      active = FactStore.active_facts()
      redis_facts = Enum.filter(active, fn f -> f[:value] == "Use Redis" end)
      assert length(redis_facts) == 1
      assert hd(redis_facts)[:confidence] == 0.9
    end

    test "does not supersede facts with different type" do
      FactStore.store(%{type: "fact", value: "Elixir", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "decision", value: "Elixir", confidence: 0.85})
      Process.sleep(50)

      active = FactStore.active_facts()
      elixir_facts = Enum.filter(active, fn f -> f[:value] == "Elixir" end)
      assert length(elixir_facts) == 2
    end

    test "does not supersede facts with different value" do
      FactStore.store(%{type: "decision", value: "Use Redis", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "decision", value: "Use Memcached", confidence: 0.85})
      Process.sleep(50)

      active = FactStore.active_facts()
      assert length(active) == 2
    end

    test "superseded facts retain valid_until timestamp" do
      FactStore.store(%{type: "fact", value: "port 3000", confidence: 0.8})
      Process.sleep(50)
      FactStore.store(%{type: "fact", value: "port 3000", confidence: 0.9})
      Process.sleep(50)

      all = FactStore.facts_by_type("fact")
      superseded = Enum.filter(all, fn f -> f[:valid_until] != nil end)
      assert length(superseded) == 1
      assert is_binary(hd(superseded)[:valid_until])
    end
  end
end
