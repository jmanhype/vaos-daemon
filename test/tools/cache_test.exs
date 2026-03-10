defmodule OptimalSystemAgent.Tools.CacheTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Cache
  alias OptimalSystemAgent.Tools.CachedExecutor

  setup do
    # Start cache if not running
    case Cache.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Cache.clear()
    :ok
  end

  # ── Basic put/get ──────────────────────────────────────────────────

  describe "put/get round trip" do
    test "stores and retrieves a value" do
      Cache.put("key1", "hello")
      assert {:ok, "hello"} = Cache.get("key1")
    end

    test "stores complex values" do
      Cache.put("key2", %{result: [1, 2, 3], status: :ok})
      assert {:ok, %{result: [1, 2, 3], status: :ok}} = Cache.get("key2")
    end

    test "returns :miss for unknown key" do
      assert :miss = Cache.get("nonexistent_key_xyz")
    end

    test "overwrites previous value on second put" do
      Cache.put("key3", "first")
      Cache.put("key3", "second")
      assert {:ok, "second"} = Cache.get("key3")
    end
  end

  # ── TTL / expiry ───────────────────────────────────────────────────

  describe "TTL expiry" do
    test "returns {:miss, :expired} for expired entry" do
      Cache.put("exp_key", "value", 1)
      :timer.sleep(5)
      assert {:miss, :expired} = Cache.get("exp_key")
    end

    test "valid entry within TTL is returned" do
      Cache.put("valid_key", "live", 60_000)
      assert {:ok, "live"} = Cache.get("valid_key")
    end

    test "custom TTL via put/3" do
      Cache.put("short", "data", 2)
      :timer.sleep(10)
      assert {:miss, :expired} = Cache.get("short")
    end
  end

  # ── invalidate / clear ─────────────────────────────────────────────

  describe "invalidate/1" do
    test "removes a specific entry" do
      Cache.put("del_key", "gone")
      Cache.invalidate("del_key")
      assert :miss = Cache.get("del_key")
    end

    test "invalidating missing key is safe" do
      assert :ok = Cache.invalidate("never_set")
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      Cache.put("a", 1)
      Cache.put("b", 2)
      Cache.put("c", 3)
      Cache.clear()
      assert :miss = Cache.get("a")
      assert :miss = Cache.get("b")
      assert :miss = Cache.get("c")
    end
  end

  # ── stats ──────────────────────────────────────────────────────────

  describe "stats/0" do
    test "returns size, hits, misses" do
      Cache.clear()
      stats = Cache.stats()
      assert is_integer(stats.size)
      assert is_integer(stats.hits)
      assert is_integer(stats.misses)
    end

    test "size reflects number of stored entries" do
      Cache.clear()
      Cache.put("s1", 1)
      Cache.put("s2", 2)
      stats = Cache.stats()
      assert stats.size == 2
    end
  end

  # ── CachedExecutor ─────────────────────────────────────────────────

  describe "CachedExecutor.cache_key/2" do
    test "same module + params produces same key" do
      k1 = CachedExecutor.cache_key(MyMod, %{a: 1, b: 2})
      k2 = CachedExecutor.cache_key(MyMod, %{b: 2, a: 1})
      assert k1 == k2
    end

    test "different modules produce different keys" do
      k1 = CachedExecutor.cache_key(ModA, %{x: 1})
      k2 = CachedExecutor.cache_key(ModB, %{x: 1})
      assert k1 != k2
    end
  end

  describe "CachedExecutor.execute/3 with bypass" do
    defmodule FakeTool do
      def execute(_params), do: {:ok, "result_#{:rand.uniform(10_000)}"}
    end

    test "bypass: true always calls the module" do
      r1 = CachedExecutor.execute(FakeTool, %{}, bypass: true)
      r2 = CachedExecutor.execute(FakeTool, %{}, bypass: true)
      # Both succeed but may differ (bypass skips cache)
      assert {:ok, _} = r1
      assert {:ok, _} = r2
    end

    test "without bypass, second call returns cached value" do
      {:ok, first} = CachedExecutor.execute(FakeTool, %{cached: true})
      {:ok, second} = CachedExecutor.execute(FakeTool, %{cached: true})
      assert first == second
    end
  end
end
