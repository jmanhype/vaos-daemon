defmodule Daemon.Investigation.PromptConfigTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.PromptConfig

  @test_dir Path.join(System.tmp_dir!(), "prompt_config_test_#{:rand.uniform(1_000_000)}")

  setup do
    on_exit(fn ->
      File.rm_rf(@test_dir)
      # Clean up any test files in the real user dir
      optimized_path = Path.join(PromptConfig.user_dir(), "investigation_optimized.json")
      if File.exists?(optimized_path), do: File.rm(optimized_path)
    end)

    :ok
  end

  describe "load/0" do
    test "returns a map with all expected prompt keys" do
      prompts = PromptConfig.load()
      assert is_map(prompts)

      expected_keys = ~w(for_system against_system advocate_user_template
                         example_format citation_instructions verify_prompt
                         no_papers_fallback)

      for key <- expected_keys do
        assert Map.has_key?(prompts, key), "Missing key: #{key}"
        assert is_binary(prompts[key]), "Key #{key} should be a string"
      end
    end

    test "loads from priv/prompts if no optimized version exists" do
      # Remove any optimized file
      optimized_path = Path.join(PromptConfig.user_dir(), "investigation_optimized.json")
      File.rm(optimized_path)

      prompts = PromptConfig.load()
      assert is_map(prompts)
      assert String.contains?(prompts["for_system"], "strongest case FOR")
    end

    test "advocate_user_template contains ~key~ placeholders" do
      prompts = PromptConfig.load()
      template = prompts["advocate_user_template"]

      assert String.contains?(template, "~position~")
      assert String.contains?(template, "~claim~")
      assert String.contains?(template, "~papers_context~")
      assert String.contains?(template, "~arg_type~")
    end

    test "verify_prompt contains ~key~ placeholders" do
      prompts = PromptConfig.load()
      template = prompts["verify_prompt"]

      assert String.contains?(template, "~paper_title~")
      assert String.contains?(template, "~paper_abstract~")
      assert String.contains?(template, "~claim~")
    end
  end

  describe "render/2" do
    test "replaces ~key~ placeholders with values" do
      template = "Hello ~name~, you are ~age~ years old."
      result = PromptConfig.render(template, name: "Alice", age: 30)
      assert result == "Hello Alice, you are 30 years old."
    end

    test "handles missing bindings gracefully (leaves placeholder)" do
      template = "Hello ~name~, ~missing~ here."
      result = PromptConfig.render(template, name: "Bob")
      assert result == "Hello Bob, ~missing~ here."
    end

    test "handles empty bindings" do
      template = "No placeholders here."
      result = PromptConfig.render(template, [])
      assert result == "No placeholders here."
    end

    test "does not conflict with curly braces in content" do
      template = "Paper says: {results: ~value~}"
      result = PromptConfig.render(template, value: "42%")
      assert result == "Paper says: {results: 42%}"
    end

    test "renders the advocate template with all bindings" do
      prompts = PromptConfig.load()
      rendered = PromptConfig.render(prompts["advocate_user_template"],
        position: "TRUE",
        direction: "",
        claim: "Test claim",
        papers_context: "Paper 1 here",
        prior_text: "",
        arg_type: "arguments",
        example_format: "Example here",
        arg_word: "argument"
      )

      assert String.contains?(rendered, "TRUE")
      assert String.contains?(rendered, "Test claim")
      assert String.contains?(rendered, "Paper 1 here")
      refute String.contains?(rendered, "~position~")
      refute String.contains?(rendered, "~claim~")
    end
  end

  describe "save_optimized/1 and load round-trip" do
    test "saves and loads optimized prompts" do
      custom_prompts = %{
        "for_system" => "Custom FOR system prompt",
        "against_system" => "Custom AGAINST system prompt",
        "advocate_user_template" => "Custom template ~claim~",
        "example_format" => "Custom example",
        "citation_instructions" => "Custom citations",
        "verify_prompt" => "Custom verify ~paper_title~",
        "no_papers_fallback" => "Custom fallback"
      }

      PromptConfig.save_optimized(custom_prompts)

      # Now load should pick up optimized
      loaded = PromptConfig.load()
      assert loaded["for_system"] == "Custom FOR system prompt"
      assert loaded["advocate_user_template"] == "Custom template ~claim~"

      # Clean up
      File.rm(Path.join(PromptConfig.user_dir(), "investigation_optimized.json"))
    end
  end

  describe "prompt_hash/1" do
    test "returns a 16-char hex string" do
      prompts = PromptConfig.load()
      hash = PromptConfig.prompt_hash(prompts)
      assert is_binary(hash)
      assert String.length(hash) == 16
      assert Regex.match?(~r/^[a-f0-9]+$/, hash)
    end

    test "same prompts produce same hash" do
      prompts = PromptConfig.load()
      assert PromptConfig.prompt_hash(prompts) == PromptConfig.prompt_hash(prompts)
    end

    test "different prompts produce different hashes" do
      p1 = %{"a" => "hello"}
      p2 = %{"a" => "world"}
      refute PromptConfig.prompt_hash(p1) == PromptConfig.prompt_hash(p2)
    end
  end

  describe "hardcoded_defaults/0" do
    test "returns valid defaults" do
      defaults = PromptConfig.hardcoded_defaults()
      assert is_map(defaults)
      assert String.contains?(defaults["for_system"], "FOR")
      assert String.contains?(defaults["against_system"], "AGAINST")
    end
  end
end
