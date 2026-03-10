defmodule OptimalSystemAgent.Agent.IntrospectionTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Agent.Introspection

  setup do
    case Process.whereis(OptimalSystemAgent.SessionRegistry) do
      nil -> start_supervised!({Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry})
      _pid -> :ok
    end
    :ok
  end

  describe "snapshot/0" do
    test "returns a map with sessions, total_sessions, and timestamp" do
      snap = Introspection.snapshot()
      assert Map.has_key?(snap, :sessions)
      assert Map.has_key?(snap, :total_sessions)
      assert Map.has_key?(snap, :timestamp)
      assert is_list(snap.sessions)
      assert is_integer(snap.total_sessions)
      assert snap.total_sessions >= 0
      assert match?(%DateTime{}, snap.timestamp)
    end

    test "total_sessions matches length of sessions list" do
      snap = Introspection.snapshot()
      assert snap.total_sessions == length(snap.sessions)
    end
  end

  describe "session_state/1" do
    test "returns :not_found for unknown session" do
      assert {:error, :not_found} = Introspection.session_state("no-such-session")
    end
  end

  describe "all_sessions/0" do
    test "returns a list" do
      assert is_list(Introspection.all_sessions())
    end
  end
end
