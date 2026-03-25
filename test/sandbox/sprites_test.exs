defmodule Daemon.Sandbox.SpritesTest do
  use ExUnit.Case, async: false

  alias Daemon.Sandbox.Sprites

  describe "available?/0" do
    test "returns false when SPRITES_TOKEN is not set" do
      original = Application.get_env(:daemon, :sprites_token)
      Application.put_env(:daemon, :sprites_token, nil)

      on_exit(fn ->
        if original,
          do: Application.put_env(:daemon, :sprites_token, original),
          else: Application.delete_env(:daemon, :sprites_token)
      end)

      refute Sprites.available?()
    end

    test "returns false when SPRITES_TOKEN is empty string" do
      original = Application.get_env(:daemon, :sprites_token)
      Application.put_env(:daemon, :sprites_token, "")

      on_exit(fn ->
        if original,
          do: Application.put_env(:daemon, :sprites_token, original),
          else: Application.delete_env(:daemon, :sprites_token)
      end)

      refute Sprites.available?()
    end

    test "returns true when SPRITES_TOKEN is set" do
      original = Application.get_env(:daemon, :sprites_token)
      Application.put_env(:daemon, :sprites_token, "test-token-123")

      on_exit(fn ->
        if original,
          do: Application.put_env(:daemon, :sprites_token, original),
          else: Application.delete_env(:daemon, :sprites_token)
      end)

      assert Sprites.available?()
    end
  end

  describe "execute/2 without token" do
    test "returns error when not available" do
      original = Application.get_env(:daemon, :sprites_token)
      Application.put_env(:daemon, :sprites_token, nil)

      on_exit(fn ->
        if original,
          do: Application.put_env(:daemon, :sprites_token, original),
          else: Application.delete_env(:daemon, :sprites_token)
      end)

      assert {:error, msg} = Sprites.execute("echo hello")
      assert msg =~ "not available"
    end
  end
end
