defmodule Daemon.Dashboard.ServiceTest do
  use ExUnit.Case, async: false

  alias Daemon.Dashboard.Service

  describe "summary/0" do
    test "returns map with required top-level keys" do
      result = Service.summary()

      assert is_map(result)
      assert Map.has_key?(result, :kpis)
      assert Map.has_key?(result, :active_agents)
      assert Map.has_key?(result, :recent_activity)
      assert Map.has_key?(result, :system_health)
      assert Map.has_key?(result, :adaptation)
    end

    test "kpis contains numeric values" do
      %{kpis: kpis} = Service.summary()

      assert is_integer(kpis.active_sessions)
      assert is_integer(kpis.agents_online)
      assert is_integer(kpis.agents_total)
      assert is_integer(kpis.tokens_used_today)
      assert is_integer(kpis.uptime_seconds)
    end

    test "active_agents is a list" do
      %{active_agents: agents} = Service.summary()
      assert is_list(agents)
    end

    test "recent_activity is a list" do
      %{recent_activity: activity} = Service.summary()
      assert is_list(activity)
    end

    test "system_health has backend status" do
      %{system_health: health} = Service.summary()

      assert health.backend in ["ok", "degraded", "error"]
      assert is_integer(health.memory_mb)
      assert health.memory_mb > 0
    end

    test "adaptation exposes journal, meta-state, and recent signal summaries" do
      %{adaptation: adaptation} = Service.summary()

      assert is_map(adaptation)
      assert is_map(adaptation.journal)
      assert adaptation.journal.status in ["running", "inactive"]
      assert is_integer(adaptation.journal.signal_count)
      assert is_integer(adaptation.journal.in_flight_count)

      assert is_map(adaptation.meta_state)
      assert Map.has_key?(adaptation.meta_state, :authority_domain)
      assert Map.has_key?(adaptation.meta_state, :active_bottleneck)
      assert Map.has_key?(adaptation.meta_state, :pivot_reason)
      assert Map.has_key?(adaptation.meta_state, :active_steering_hypothesis)
      assert Map.has_key?(adaptation.meta_state, :last_updated_at)
      assert Map.has_key?(adaptation.meta_state, :last_experiment)
      assert is_integer(adaptation.meta_state.recent_failed_count)

      assert is_list(adaptation.recent_signals)
      assert Map.has_key?(adaptation, :current_trial)
      assert is_list(adaptation.active_promotions)
      assert is_list(adaptation.active_suppressions)
    end
  end
end
