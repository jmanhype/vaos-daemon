defmodule OptimalSystemAgent.Sandbox.RegistryTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Sandbox.Registry

  setup do
    # Start the Registry for each test
    case GenServer.whereis(Registry) do
      nil -> start_supervised!(Registry)
      pid -> pid
    end

    :ok
  end

  describe "allocate/2" do
    test "allocates a new sandbox for an agent" do
      assert {:ok, allocation} = Registry.allocate("agent-1")
      assert is_atom(allocation.backend)
      assert is_binary(allocation.ref)
      assert is_integer(allocation.allocated_at)
    end

    test "returns existing allocation on duplicate allocate" do
      {:ok, first} = Registry.allocate("agent-dup")
      {:ok, second} = Registry.allocate("agent-dup")
      assert first.ref == second.ref
      assert first.allocated_at == second.allocated_at
    end

    test "respects backend option" do
      {:ok, allocation} = Registry.allocate("agent-sprites", backend: :sprites)
      assert allocation.backend == :sprites
    end
  end

  describe "lookup/1" do
    test "returns nil for unknown agent" do
      assert Registry.lookup("nonexistent-agent") == nil
    end

    test "returns allocation after allocate" do
      {:ok, _} = Registry.allocate("agent-lookup")
      allocation = Registry.lookup("agent-lookup")
      assert allocation != nil
      assert is_binary(allocation.ref)
    end
  end

  describe "release/1" do
    test "releases an allocated sandbox" do
      {:ok, _} = Registry.allocate("agent-release")
      assert :ok = Registry.release("agent-release")
      assert Registry.lookup("agent-release") == nil
    end

    test "release on unknown agent returns :ok" do
      assert :ok = Registry.release("never-allocated")
    end
  end
end
