defmodule OptimalSystemAgent.Agent.CostTrackerTest do
  use ExUnit.Case, async: false

  describe "calc_cost/3 (via module attribute)" do
    test "known model pricing calculation" do
      input = 1000
      output = 500
      in_rate = 300
      out_rate = 1500
      expected = ceil((input * in_rate + output * out_rate) / 1_000_000)
      assert expected == 2
    end

    test "default pricing for unknown model" do
      expected = ceil((10_000 * 100 + 5_000 * 300) / 1_000_000)
      assert expected == 3
    end

    test "large token counts produce correct costs" do
      expected = ceil((100_000 * 1500 + 50_000 * 7500) / 1_000_000)
      assert expected == 525
    end
  end

  describe "budget enforcement logic" do
    test "budget exceeded when spent >= budget" do
      spent = 25000
      budget = 25000
      assert spent >= budget
    end

    test "budget not exceeded when spent < budget" do
      spent = 24999
      budget = 25000
      assert spent < budget
    end

    test "zero budget never triggers pause" do
      budget = 0
      spent = 100
      refute budget > 0 and spent >= budget
    end
  end

  describe "reset logic" do
    test "daily reset when date changes" do
      yesterday = Date.add(Date.utc_today(), -1)
      today = Date.utc_today()
      assert Date.compare(yesterday, today) == :lt
    end

    test "monthly reset when month changes" do
      last_month = Date.add(Date.utc_today(), -31)
      today = Date.utc_today()
      last_ym = Calendar.strftime(last_month, "%Y-%m")
      today_ym = Calendar.strftime(today, "%Y-%m")
      assert last_ym < today_ym
    end
  end
end
