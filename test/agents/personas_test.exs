defmodule OptimalSystemAgent.Agents.PersonasTest do
  use ExUnit.Case, async: true

  @persona_modules [
    OptimalSystemAgent.Agents.Researcher,
    OptimalSystemAgent.Agents.Writer,
    OptimalSystemAgent.Agents.Reviewer,
    OptimalSystemAgent.Agents.Coder,
    OptimalSystemAgent.Agents.Tester,
    OptimalSystemAgent.Agents.QaLead
  ]

  @valid_tiers [:elite, :specialist, :utility]

  # -----------------------------------------------------------------------
  # Behaviour compliance -- all required callbacks are implemented
  # -----------------------------------------------------------------------

  describe "behaviour compliance" do
    test "every persona exports the required callbacks" do
      required = [:name, :description, :tier, :role, :system_prompt, :skills, :triggers, :territory, :escalate_to]
      for mod <- @persona_modules do
        for cb <- required do
          assert function_exported?(mod, cb, 0), 
            "#{mod} is missing #{cb}/0"
        end
      end
    end
  end

  # -----------------------------------------------------------------------
  # name/0 and system_prompt/0
  # -----------------------------------------------------------------------

  describe "name/0" do
    test "every persona returns a non-empty string" do
      for mod <- @persona_modules do
        name = mod.name()
        assert is_binary(name), "#{mod}.name/0 should return a string"
        assert byte_size(name) > 0, "#{mod}.name/0 should not be empty"
      end
    end
  end

  describe "system_prompt/0" do
    test "every persona returns a non-empty string" do
      for mod <- @persona_modules do
        prompt = mod.system_prompt()
        assert is_binary(prompt), "#{mod}.system_prompt/0 should return a string"
        assert byte_size(prompt) > 0, "#{mod}.system_prompt/0 should not be empty"
      end
    end
  end

  # -----------------------------------------------------------------------
  # tier/0
  # -----------------------------------------------------------------------

  describe "tier/0" do
    test "every persona returns a valid tier atom" do
      for mod <- @persona_modules do
        tier = mod.tier()
        assert tier in @valid_tiers,
          "#{mod}.tier/0 returned #{inspect(tier)}, expected one of #{inspect(@valid_tiers)}"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Per-persona role checks
  # -----------------------------------------------------------------------

  describe "role/0 -- per-persona expectations" do
    test "Researcher role is :researcher" do
      assert OptimalSystemAgent.Agents.Researcher.role() == :researcher
    end

    test "Writer role is :writer" do
      assert OptimalSystemAgent.Agents.Writer.role() == :writer
    end

    test "Reviewer role is :reviewer" do
      assert OptimalSystemAgent.Agents.Reviewer.role() == :reviewer
    end

    test "Coder role is :coder" do
      assert OptimalSystemAgent.Agents.Coder.role() == :coder
    end

    test "Tester role is :tester" do
      assert OptimalSystemAgent.Agents.Tester.role() == :tester
    end

    test "QaLead role is :qa" do
      assert OptimalSystemAgent.Agents.QaLead.role() == :qa
    end
  end

  describe "triggers/0 -- keyword presence" do
    test "Researcher has research keyword in triggers" do
      triggers = OptimalSystemAgent.Agents.Researcher.triggers()
      assert Enum.any?(triggers, fn t -> String.contains?(t, "research") end)
    end

    test "Writer has write keyword in triggers" do
      triggers = OptimalSystemAgent.Agents.Writer.triggers()
      assert Enum.any?(triggers, fn t -> String.contains?(t, "write") end)
    end

    test "Reviewer has review keyword in triggers" do
      triggers = OptimalSystemAgent.Agents.Reviewer.triggers()
      assert Enum.any?(triggers, fn t -> String.contains?(t, "review") end)
    end

    test "Tester has test keyword in triggers" do
      triggers = OptimalSystemAgent.Agents.Tester.triggers()
      assert Enum.any?(triggers, fn t -> String.contains?(t, "test") end)
    end
  end
end
