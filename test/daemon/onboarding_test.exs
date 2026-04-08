defmodule Daemon.OnboardingTest do
  use ExUnit.Case, async: false

  alias Daemon.Onboarding

  setup do
    profile = "codex-onboarding-#{System.unique_integer([:positive])}"
    profile_dir = Path.expand("~/.daemon/profiles/#{profile}")

    original_profile = System.get_env("DAEMON_PROFILE")
    original_fallback_env = System.get_env("DAEMON_FALLBACK_CHAIN")
    original_zhipu_env = System.get_env("ZHIPU_API_KEY")

    original_app_env =
      for key <- [
            :default_provider,
            :fallback_chain,
            :zhipu_api_key,
            :openai_api_key,
            :google_api_key,
            :zhipu_model
          ],
          into: %{} do
        {key, Application.get_env(:daemon, key)}
      end

    File.rm_rf!(profile_dir)
    File.mkdir_p!(profile_dir)

    System.put_env("DAEMON_PROFILE", profile)
    System.delete_env("DAEMON_FALLBACK_CHAIN")

    on_exit(fn ->
      restore_system_env("DAEMON_PROFILE", original_profile)
      restore_system_env("DAEMON_FALLBACK_CHAIN", original_fallback_env)
      restore_system_env("ZHIPU_API_KEY", original_zhipu_env)

      Enum.each(original_app_env, fn {key, value} ->
        restore_app_env(key, value)
      end)

      File.rm_rf!(profile_dir)
    end)

    {:ok, profile_dir: profile_dir}
  end

  test "apply_config rebuilds fallback chain from config keys, not ambient app env", %{
    profile_dir: profile_dir
  } do
    write_config(profile_dir, %{
      "provider" => %{"default" => "zhipu", "model" => "glm-5.1"},
      "api_keys" => %{"ZHIPU_API_KEY" => "zhipu-test-key"}
    })

    Application.put_env(:daemon, :openai_api_key, "openai-test-key")
    Application.put_env(:daemon, :google_api_key, "google-test-key")

    assert :ok = Onboarding.apply_config()
    assert Application.get_env(:daemon, :default_provider) == :zhipu
    assert Application.get_env(:daemon, :zhipu_model) == "glm-5.1"

    chain = Application.get_env(:daemon, :fallback_chain, [])

    refute :openai in chain
    refute :google in chain
    assert Enum.all?(chain, &(&1 == :ollama))
  end

  test "first_run? treats a zhipu-configured profile as ready", %{profile_dir: profile_dir} do
    write_config(profile_dir, %{
      "provider" => %{"default" => "zhipu", "model" => "glm-5.1"},
      "api_keys" => %{"ZHIPU_API_KEY" => "zhipu-test-key"}
    })

    assert :ok = Onboarding.apply_config()
    refute Onboarding.first_run?()
  end

  defp write_config(profile_dir, config) do
    File.write!(Path.join(profile_dir, "config.json"), Jason.encode!(config))
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:daemon, key)
  defp restore_app_env(key, value), do: Application.put_env(:daemon, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
