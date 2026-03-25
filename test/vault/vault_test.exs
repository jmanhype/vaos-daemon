defmodule Daemon.VaultTest do
  use ExUnit.Case, async: false

  alias Daemon.Vault
  alias Daemon.Vault.{Store, FactStore}

  setup do
    tmp = System.tmp_dir!() |> Path.join("vault_int_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:daemon, :config_dir, tmp)

    # Initialize vault directories
    Store.init()

    # Clear ETS facts from any prior test
    try do
      :ets.delete_all_objects(:daemon_vault_facts)
    rescue
      ArgumentError -> :ok
    end

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  describe "remember/3" do
    test "stores memory and returns path" do
      assert {:ok, path} = Vault.remember("We decided to use PostgreSQL for the database.", :decision)
      assert File.exists?(path)
    end

    test "stores memory with default category :fact" do
      assert {:ok, path} = Vault.remember("Elixir runs on the BEAM VM.")
      assert path =~ "/facts/"
    end

    test "accepts string category" do
      assert {:ok, path} = Vault.remember("A lesson about caching.", "lesson")
      assert path =~ "/lessons/"
    end

    test "falls back to :fact for invalid string category" do
      assert {:ok, path} = Vault.remember("Some content.", "nonexistent_category")
      assert path =~ "/facts/"
    end

    test "extracts facts from content" do
      Vault.remember("We decided to use Redis for caching. Port listens on 6379.", :decision)
      Process.sleep(100)

      facts = FactStore.active_facts()
      types = Enum.map(facts, & &1[:type])
      assert "decision" in types or "fact" in types
    end

    test "accepts title in opts" do
      {:ok, path} = Vault.remember("Content here.", :fact, %{title: "Custom Title"})
      assert path =~ "custom-title"
    end

    test "generates title from content when not provided" do
      {:ok, path} = Vault.remember("First line is the title\nSecond line is body.", :fact)
      assert path =~ "first-line-is-the-title"
    end

    test "handles empty content gracefully" do
      {:ok, path} = Vault.remember("", :fact, %{title: "empty-note"})
      assert File.exists?(path)
    end
  end

  describe "recall/2" do
    test "finds stored memories by query" do
      Vault.remember("Elixir is great for building distributed systems.", :fact,
        %{title: "Elixir Strengths"})
      Vault.remember("Python is good for data science.", :fact,
        %{title: "Python Strengths"})

      results = Vault.recall("Elixir")
      assert length(results) >= 1
      assert Enum.any?(results, fn {_cat, path, _score} -> path =~ "elixir" end)
    end

    test "returns empty list when nothing matches" do
      Vault.remember("Something about Elixir.", :fact, %{title: "Elixir Note"})
      results = Vault.recall("zzzznonexistent")
      assert results == []
    end

    test "passes options through to Store.search" do
      Vault.remember("BEAM virtual machine fact.", :fact, %{title: "BEAM Fact"})
      Vault.remember("BEAM concurrency decision.", :decision, %{title: "BEAM Decision"})

      results = Vault.recall("BEAM", categories: [:fact])
      assert Enum.all?(results, fn {cat, _, _} -> cat == :fact end)
    end
  end

  describe "init/0" do
    test "delegates to Store.init" do
      assert :ok = Vault.init()
    end
  end

  describe "inject/1" do
    test "returns string for message with keywords" do
      Vault.remember("We decided to use Kubernetes for orchestration.", :decision,
        %{title: "K8s Decision"})

      result = Vault.inject("Tell me about kubernetes orchestration")
      assert is_binary(result)
    end

    test "returns empty string for short/stopword-only message" do
      result = Vault.inject("the")
      assert result == ""
    end
  end

  describe "context/2" do
    test "returns a string" do
      result = Vault.context()
      assert is_binary(result)
    end

    test "accepts profile parameter" do
      result = Vault.context(:planning)
      assert is_binary(result)
    end

    test "includes facts when present" do
      FactStore.store(%{type: "fact", value: "BEAM VM powers Elixir", confidence: 0.9})
      Process.sleep(50)

      result = Vault.context(:default)
      assert is_binary(result)
      # With facts present, context should be non-empty
      if FactStore.count() > 0 do
        assert result =~ "BEAM VM" or String.length(result) > 0
      end
    end
  end
end
