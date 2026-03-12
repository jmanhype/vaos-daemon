defmodule OptimalSystemAgent.Webhooks.DispatcherTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Webhooks.Dispatcher

  # ── valid_url?/1 ──────────────────────────────────────────────────────

  describe "valid_url?/1" do
    test "accepts https URLs" do
      assert Dispatcher.valid_url?("https://example.com/hook")
    end

    test "accepts http URLs" do
      assert Dispatcher.valid_url?("http://example.com/hook")
    end

    test "rejects non-http schemes" do
      refute Dispatcher.valid_url?("ftp://example.com/hook")
      refute Dispatcher.valid_url?("file:///etc/passwd")
    end

    test "rejects nil and non-binary" do
      refute Dispatcher.valid_url?(nil)
      refute Dispatcher.valid_url?(123)
    end

    test "rejects empty string" do
      refute Dispatcher.valid_url?("")
    end

    test "blocks localhost" do
      refute Dispatcher.valid_url?("http://localhost/hook")
      refute Dispatcher.valid_url?("http://LOCALHOST/hook")
    end

    test "blocks 127.0.0.1" do
      refute Dispatcher.valid_url?("http://127.0.0.1/hook")
    end

    test "blocks 0.0.0.0" do
      refute Dispatcher.valid_url?("http://0.0.0.0/hook")
    end

    test "blocks ::1" do
      refute Dispatcher.valid_url?("http://::1/hook")
    end

    test "blocks link-local 169.254.x.x" do
      refute Dispatcher.valid_url?("http://169.254.169.254/latest/meta-data")
    end

    test "blocks private 10.x.x.x" do
      refute Dispatcher.valid_url?("http://10.0.0.1/hook")
    end

    test "blocks private 192.168.x.x" do
      refute Dispatcher.valid_url?("http://192.168.1.1/hook")
    end
  end

  # ── valid_secret?/1 ──────────────────────────────────────────────────

  describe "valid_secret?/1" do
    test "nil is valid (no secret)" do
      assert Dispatcher.valid_secret?(nil)
    end

    test "32-byte binary is valid" do
      assert Dispatcher.valid_secret?(String.duplicate("a", 32))
    end

    test "longer than 32 bytes is valid" do
      assert Dispatcher.valid_secret?(String.duplicate("a", 64))
    end

    test "shorter than 32 bytes is invalid" do
      refute Dispatcher.valid_secret?("short")
    end

    test "empty string is invalid" do
      refute Dispatcher.valid_secret?("")
    end
  end

  # ── register / unregister / list ─────────────────────────────────────

  describe "register/3, unregister/1, list/0" do
    setup do
      # Start the dispatcher for each test
      start_supervised!(Dispatcher)
      :ok
    end

    test "register returns {:ok, id} for valid URL" do
      assert {:ok, id} = Dispatcher.register("https://example.com/hook")
      assert is_binary(id) and byte_size(id) == 16
    end

    test "register rejects invalid URL" do
      assert {:error, :invalid_url} = Dispatcher.register("not-a-url")
    end

    test "register rejects short secret" do
      assert {:error, "secret must be at least 32 bytes"} =
               Dispatcher.register("https://example.com/hook", "tooshort")
    end

    test "registered webhook appears in list" do
      {:ok, id} = Dispatcher.register("https://example.com/hook")
      hooks = Dispatcher.list()
      assert Enum.any?(hooks, &(&1.id == id))
    end

    test "list does not expose secret" do
      secret = String.duplicate("s", 32)
      {:ok, _id} = Dispatcher.register("https://example.com/hook", secret)
      [hook] = Dispatcher.list()
      refute Map.has_key?(hook, :secret)
      assert hook.has_secret == true
    end

    test "unregister removes the webhook" do
      {:ok, id} = Dispatcher.register("https://example.com/hook")
      assert :ok = Dispatcher.unregister(id)
      assert Dispatcher.list() == []
    end

    test "unregister returns error for unknown id" do
      assert {:error, :not_found} = Dispatcher.unregister("nonexistent")
    end
  end
end
