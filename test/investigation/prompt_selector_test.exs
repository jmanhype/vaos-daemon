defmodule Daemon.Investigation.PromptSelectorTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.{PromptSelector, PromptConfig}

  @test_dir Path.join(System.tmp_dir!(), "prompt_selector_test_#{:rand.uniform(1_000_000)}")

  setup do
    # Override registry dir for tests by cleaning the real one
    registry_dir = PromptSelector.registry_dir()
    registry_file = Path.join(registry_dir, "registry.json")

    # Back up existing registry if present
    backup = if File.exists?(registry_file) do
      {:ok, content} = File.read(registry_file)
      content
    else
      nil
    end

    # Remove registry for clean test state
    File.rm(registry_file)

    on_exit(fn ->
      # Restore backup or clean up
      if backup do
        File.mkdir_p!(registry_dir)
        File.write!(registry_file, backup)
      else
        File.rm(registry_file)
      end
    end)

    :ok
  end

  describe "select/0" do
    test "cold start returns hardcoded defaults" do
      {prompts, variant_id} = PromptSelector.select()
      assert variant_id == "default"
      assert is_map(prompts)
      assert String.contains?(prompts["for_system"], "FOR")
    end

    test "creates registry file on first select" do
      PromptSelector.select()
      assert File.exists?(Path.join(PromptSelector.registry_dir(), "registry.json"))
    end

    test "single variant always selected" do
      # Only default exists
      {_prompts, variant_id} = PromptSelector.select()
      assert variant_id == "default"

      # Select again — still default
      {_prompts, variant_id2} = PromptSelector.select()
      assert variant_id2 == "default"
    end

    test "two variants both explored over many selections" do
      # Register a second variant
      custom = make_valid_prompts("Custom FOR system")
      {:ok, custom_id} = PromptSelector.register(custom, source: "test")

      # Select many times — both should appear
      selected_ids = for _ <- 1..100 do
        {_prompts, id} = PromptSelector.select()
        id
      end

      unique = Enum.uniq(selected_ids)
      assert "default" in unique
      assert custom_id in unique
    end

    test "strong posterior dominates selections" do
      # Register a variant with strong posterior
      custom = make_valid_prompts("Strong variant")
      {:ok, custom_id} = PromptSelector.register(custom, source: "strong")

      # Give it a very strong posterior (alpha=50, beta=2)
      for _ <- 1..49, do: PromptSelector.update(custom_id, 1, 0)
      PromptSelector.update(custom_id, 0, 1)

      # Give default a weak posterior (alpha=2, beta=50)
      for _ <- 1..49, do: PromptSelector.update("default", 0, 1)
      PromptSelector.update("default", 1, 0)

      # Over 50 selections, the strong variant should dominate
      selected_ids = for _ <- 1..50 do
        {_prompts, id} = PromptSelector.select()
        id
      end

      strong_count = Enum.count(selected_ids, &(&1 == custom_id))
      assert strong_count > 40, "Expected strong variant to dominate, got #{strong_count}/50"
    end

    test "survives corrupted registry" do
      # Write garbage to registry file
      File.mkdir_p!(PromptSelector.registry_dir())
      File.write!(Path.join(PromptSelector.registry_dir(), "registry.json"), "not json{{{")

      # Should still work (falls back to fresh registry)
      {prompts, variant_id} = PromptSelector.select()
      assert variant_id == "default"
      assert is_map(prompts)
    end
  end

  describe "update/3" do
    test "updates alpha and beta correctly" do
      PromptSelector.select()  # Ensure default exists
      PromptSelector.update("default", 3, 1)

      [variant] = PromptSelector.list_variants()
      assert variant["alpha"] == 4  # 1 (prior) + 3
      assert variant["beta"] == 2   # 1 (prior) + 1
      assert variant["total_trials"] == 4
    end

    test "accumulates over multiple calls" do
      PromptSelector.select()  # Ensure default exists
      PromptSelector.update("default", 2, 0)
      PromptSelector.update("default", 3, 1)

      [variant] = PromptSelector.list_variants()
      assert variant["alpha"] == 6  # 1 + 2 + 3
      assert variant["beta"] == 2   # 1 + 0 + 1
      assert variant["total_trials"] == 6
    end

    test "unknown variant is a no-op" do
      assert :ok == PromptSelector.update("nonexistent_variant", 5, 2)
    end
  end

  describe "register/2" do
    test "registers new variant" do
      prompts = make_valid_prompts("New FOR system")
      {:ok, variant_id} = PromptSelector.register(prompts, source: "test")

      assert is_binary(variant_id)
      assert String.starts_with?(variant_id, "test_")

      variants = PromptSelector.list_variants()
      registered = Enum.find(variants, &(&1["variant_id"] == variant_id))
      assert registered["source"] == "test"
      assert registered["alpha"] == 1
      assert registered["beta"] == 1
    end

    test "reuses existing variant by prompt_hash" do
      prompts = make_valid_prompts("Reuse test")
      {:ok, id1} = PromptSelector.register(prompts, source: "first")
      {:ok, id2} = PromptSelector.register(prompts, source: "second")

      assert id1 == id2
    end

    test "preserves posterior on re-register with same hash" do
      prompts = make_valid_prompts("Preserve test")
      {:ok, id} = PromptSelector.register(prompts, source: "keep")

      # Build up some posterior
      PromptSelector.update(id, 10, 2)

      # Re-register same prompts
      {:ok, id2} = PromptSelector.register(prompts, source: "keep_again")
      assert id == id2

      # Posterior should be preserved
      variant = Enum.find(PromptSelector.list_variants(), &(&1["variant_id"] == id))
      assert variant["alpha"] == 11  # 1 + 10
      assert variant["beta"] == 3    # 1 + 2
    end

    test "rejects missing keys" do
      incomplete = %{"for_system" => "hi", "against_system" => "bye"}
      assert {:error, msg} = PromptSelector.register(incomplete)
      assert String.contains?(msg, "Missing required prompt keys")
    end

    test "rejects empty values" do
      prompts = %{
        "for_system" => "",
        "against_system" => "test",
        "advocate_user_template" => "test",
        "example_format" => "test",
        "verify_prompt" => "test",
        "no_papers_fallback" => "test"
      }

      assert {:error, msg} = PromptSelector.register(prompts)
      assert String.contains?(msg, "Empty or non-string")
    end
  end

  describe "list_variants/0" do
    test "empty on cold start" do
      variants = PromptSelector.list_variants()
      assert variants == []
    end

    test "returns all variants with stats" do
      PromptSelector.select()  # Creates default
      custom = make_valid_prompts("List test")
      {:ok, _} = PromptSelector.register(custom, source: "listed")

      variants = PromptSelector.list_variants()
      assert length(variants) == 2

      ids = Enum.map(variants, & &1["variant_id"])
      assert "default" in ids
    end
  end

  describe "sample_beta/2" do
    test "Beta(1,1) produces values in [0, 1]" do
      for _ <- 1..100 do
        s = PromptSelector.sample_beta(1, 1)
        assert s >= 0.0 and s <= 1.0
      end
    end

    test "Beta(100,1) produces values near 1.0" do
      samples = for _ <- 1..100, do: PromptSelector.sample_beta(100, 1)
      avg = Enum.sum(samples) / length(samples)
      assert avg > 0.9, "Expected Beta(100,1) mean near 1.0, got #{avg}"
    end

    test "Beta(1,100) produces values near 0.0" do
      samples = for _ <- 1..100, do: PromptSelector.sample_beta(1, 100)
      avg = Enum.sum(samples) / length(samples)
      assert avg < 0.1, "Expected Beta(1,100) mean near 0.0, got #{avg}"
    end

    test "Beta(50,50) produces values near 0.5" do
      samples = for _ <- 1..100, do: PromptSelector.sample_beta(50, 50)
      avg = Enum.sum(samples) / length(samples)
      assert avg > 0.4 and avg < 0.6, "Expected Beta(50,50) mean near 0.5, got #{avg}"
    end

    test "Beta(0.5, 0.5) handles a < 1 case" do
      for _ <- 1..50 do
        s = PromptSelector.sample_beta(0.5, 0.5)
        assert s >= 0.0 and s <= 1.0
      end
    end
  end

  # --- Helpers ---

  defp make_valid_prompts(for_system_text) do
    %{
      "for_system" => for_system_text,
      "against_system" => "Test AGAINST system",
      "advocate_user_template" => "Test template ~claim~",
      "example_format" => "Test example",
      "verify_prompt" => "Test verify ~paper_title~",
      "no_papers_fallback" => "Test fallback"
    }
  end
end
