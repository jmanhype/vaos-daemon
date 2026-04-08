defmodule Daemon.Tools.Builtins.InvestigateTest do
  use ExUnit.Case, async: false

  alias Daemon.Tools.Builtins.Investigate

  setup do
    keys = [
      :default_provider,
      :default_model,
      :utility_model,
      :investigate_verification_model,
      :investigate_verify_max_tokens
    ]

    original =
      Enum.into(keys, %{}, fn key ->
        {key, Application.get_env(:daemon, key, :__missing__)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, :__missing__} -> Application.delete_env(:daemon, key)
        {key, value} -> Application.put_env(:daemon, key, value)
      end)
    end)

    :ok
  end

  test "preferred_verification_model prefers utility-tier model over default reasoning model" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.delete_env(:daemon, :utility_model)
    Application.delete_env(:daemon, :investigate_verification_model)

    assert Investigate.preferred_verification_model() == "glm-4.5-flash"
  end

  test "preferred_verification_model honors explicit override" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.put_env(:daemon, :utility_model, "glm-4.5-flash")
    Application.put_env(:daemon, :investigate_verification_model, "glm-custom-verify")

    assert Investigate.preferred_verification_model() == "glm-custom-verify"
  end

  test "merge_verification_stats aggregates counts and averages" do
    merged =
      Investigate.merge_verification_stats([
        %{
          total_items: 3,
          llm_items: 2,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 0,
          cache_hits: 1,
          cache_misses: 1,
          cache_lookup_ms: 4,
          llm_ms_total: 80,
          average_llm_ms: 80,
          slowest_llm_ms: 80,
          model: "glm-4.5-flash"
        },
        %{
          total_items: 4,
          llm_items: 3,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 1,
          cache_hits: 0,
          cache_misses: 2,
          cache_lookup_ms: 3,
          llm_ms_total: 100,
          average_llm_ms: 50,
          slowest_llm_ms: 60,
          model: "glm-4.5-flash"
        }
      ])

    assert merged.total_items == 7
    assert merged.llm_items == 5
    assert merged.no_llm_items == 2
    assert merged.unique_llm_items == 4
    assert merged.deduped_llm_items == 1
    assert merged.cache_hits == 1
    assert merged.cache_misses == 3
    assert merged.cache_lookup_ms == 7
    assert merged.llm_ms_total == 180
    assert merged.average_llm_ms == 60
    assert merged.slowest_llm_ms == 80
    assert merged.model == "glm-4.5-flash"
  end
end
