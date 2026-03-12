defmodule OptimalSystemAgent.CommandsDuplicateKeyTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Commands

  describe "command key uniqueness" do
    test "no two commands share the same key" do
      names = Commands.list_commands() |> Enum.map(fn {name, _desc, _cat} -> name end)
      unique_names = Enum.uniq(names)
      duplicates = names -- unique_names
      assert duplicates == [],
        "Found duplicate command keys: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  describe "specific command presence" do
    test "/tier command is present in the list" do
      names = Commands.list_commands() |> Enum.map(fn {name, _desc, _cat} -> name end)
      assert "tier" in names
    end

    test "/tier command is routable (not :unknown)" do
      # The handler may fail because dependent GenServers aren't running in
      # the test environment, but the command must be looked up successfully
      # (i.e. not return :unknown).
      result =
        try do
          Commands.execute("tier", "test-session")
        catch
          :exit, _ -> :handler_found_but_infra_missing
        end

      refute result == :unknown
    end
  end

  describe "tier command disambiguation" do
    test "tier command count is exactly 1" do
      tier_cmds = Commands.list_commands() |> Enum.filter(fn {name, _d, _c} -> name == "tier" end)
      assert length(tier_cmds) == 1,
        "Expected exactly 1 tier command but found #{length(tier_cmds)}"
    end
  end

  describe "tier-set command" do
    test "/tier-set command is present in the list" do
      names = Commands.list_commands() |> Enum.map(fn {name, _desc, _cat} -> name end)
      assert "tier-set" in names
    end

    test "/tier-set command is routable (not :unknown)" do
      result =
        try do
          Commands.execute("tier-set", "test-session")
        catch
          :exit, _ -> :handler_found_but_infra_missing
        end

      refute result == :unknown
    end
  end
end
