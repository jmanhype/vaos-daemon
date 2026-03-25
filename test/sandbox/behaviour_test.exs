defmodule Daemon.Sandbox.BehaviourTest do
  use ExUnit.Case, async: true

  alias Daemon.Sandbox.{Docker, Wasm, Sprites}

  describe "behaviour compliance" do
    test "Docker implements Sandbox.Behaviour" do
      behaviours = Docker.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      assert Daemon.Sandbox.Behaviour in behaviours
    end

    test "Wasm implements Sandbox.Behaviour" do
      behaviours = Wasm.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      assert Daemon.Sandbox.Behaviour in behaviours
    end

    test "Sprites implements Sandbox.Behaviour" do
      behaviours = Sprites.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      assert Daemon.Sandbox.Behaviour in behaviours
    end

    test "all backends export available?/0 and execute/2 via __info__" do
      for mod <- [Docker, Wasm, Sprites] do
        exports = mod.__info__(:functions)
        assert {:available?, 0} in exports, "#{mod} missing available?/0"
        assert {:execute, 2} in exports, "#{mod} missing execute/2"
      end
    end
  end
end
