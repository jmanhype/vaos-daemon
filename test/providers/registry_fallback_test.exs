defmodule MiosaProviders.RegistryFallbackTest do
  use ExUnit.Case, async: false

  alias Daemon.Test.MockProvider
  alias Daemon.Providers.HealthChecker
  alias MiosaProviders.Registry

  setup do
    case Process.whereis(HealthChecker) do
      nil -> start_supervised!(HealthChecker)
      _pid -> :ok
    end

    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end

    :ok
  end

  describe "automatic fallback" do
    test "strips stale model before calling the fallback provider" do
      previous_chain = Application.get_env(:daemon, :fallback_chain)
      previous_openai_key = Application.get_env(:daemon, :openai_api_key)

      on_exit(fn ->
        restore_env(:fallback_chain, previous_chain)
        restore_env(:openai_api_key, previous_openai_key)
        MockProvider.reset()
      end)

      assert {:module, MockProvider} = Code.ensure_loaded(MockProvider)
      assert :ok = Registry.register_provider(:mock, MockProvider)
      Application.put_env(:daemon, :fallback_chain, [:openai, :mock])
      Application.delete_env(:daemon, :openai_api_key)
      MockProvider.reset()

      messages = [%{role: "user", content: "hello"}]

      assert {:ok, _response} =
               Registry.chat(
                 messages,
                 provider: :openai,
                 model: "gpt-4o"
               )

      refute Keyword.has_key?(MockProvider.last_opts() || [], :model)
    end

    test "returns the original provider error when fallback is disabled" do
      previous_chain = Application.get_env(:daemon, :fallback_chain)
      previous_openai_key = Application.get_env(:daemon, :openai_api_key)

      on_exit(fn ->
        restore_env(:fallback_chain, previous_chain)
        restore_env(:openai_api_key, previous_openai_key)
        MockProvider.reset()
      end)

      assert {:module, MockProvider} = Code.ensure_loaded(MockProvider)
      assert :ok = Registry.register_provider(:mock, MockProvider)
      Application.put_env(:daemon, :fallback_chain, [:openai, :mock])
      Application.delete_env(:daemon, :openai_api_key)
      MockProvider.reset()

      messages = [%{role: "user", content: "hello"}]

      assert {:error, reason} =
               Registry.chat(
                 messages,
                 provider: :openai,
                 model: "gpt-4o",
                 allow_fallback: false
               )

      assert reason =~ "OPENAI_API_KEY not configured"

      assert MockProvider.last_opts() == nil
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:daemon, key)
  defp restore_env(key, value), do: Application.put_env(:daemon, key, value)
end
