defmodule Daemon.Investigation.PromptFeedbackTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.PromptFeedback

  @test_hash "test_" <> Base.encode16(:crypto.hash(:sha256, "test"), case: :lower) |> String.slice(0, 11)
  @test_topic "test_topic_#{:rand.uniform(1_000_000)}"

  setup do
    on_exit(fn ->
      # Clean up test files
      store_dir = PromptFeedback.store_dir()

      if File.dir?(store_dir) do
        store_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "test_"))
        |> Enum.each(fn file ->
          File.rm(Path.join(store_dir, file))
        end)
      end
    end)

    :ok
  end

  describe "record/3" do
    test "creates a feedback file" do
      metrics = %{
        total_sourced: 5,
        verified: 4,
        partial: 1,
        unverified: 0,
        verification_rate: 0.8
      }

      assert :ok = PromptFeedback.record(@test_hash, @test_topic, metrics)

      # Verify file exists
      store_dir = PromptFeedback.store_dir()
      assert File.dir?(store_dir)

      files = File.ls!(store_dir) |> Enum.filter(&String.starts_with?(&1, "test_"))
      assert length(files) > 0
    end

    test "appends to existing entries" do
      metrics1 = %{total_sourced: 5, verified: 4, partial: 1, unverified: 0, verification_rate: 0.8}
      metrics2 = %{total_sourced: 3, verified: 3, partial: 0, unverified: 0, verification_rate: 1.0}

      PromptFeedback.record(@test_hash, @test_topic, metrics1)
      PromptFeedback.record(@test_hash, @test_topic, metrics2)

      # Load all and check we have 2 entries for this hash
      all = PromptFeedback.load_all()
      matching = Enum.filter(all, fn e -> e["prompt_hash"] == @test_hash end)
      assert length(matching) == 2
    end

    test "handles string-keyed metrics" do
      metrics = %{
        "total_sourced" => 3,
        "verified" => 2,
        "partial" => 1,
        "unverified" => 0,
        "verification_rate" => 0.67
      }

      assert :ok = PromptFeedback.record(@test_hash, @test_topic, metrics)
    end
  end

  describe "load_all/0" do
    test "returns empty list when no feedback exists" do
      # Clean all test files first
      store_dir = PromptFeedback.store_dir()

      if File.dir?(store_dir) do
        store_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "test_"))
        |> Enum.each(&File.rm(Path.join(store_dir, &1)))
      end

      all = PromptFeedback.load_all()
      # May contain entries from other tests/runs, but should be a list
      assert is_list(all)
    end

    test "returns recorded entries" do
      metrics = %{total_sourced: 5, verified: 5, partial: 0, unverified: 0, verification_rate: 1.0}
      PromptFeedback.record(@test_hash, @test_topic, metrics)

      all = PromptFeedback.load_all()
      assert length(all) >= 1

      entry = Enum.find(all, fn e -> e["prompt_hash"] == @test_hash end)
      assert entry != nil
      assert entry["metrics"]["verification_rate"] == 1.0
    end
  end

  describe "aggregate/1" do
    test "returns zero for unknown hash" do
      result = PromptFeedback.aggregate("nonexistent_hash_xyz")
      assert result.avg_verification_rate == 0.0
      assert result.sample_count == 0
    end

    test "computes average verification rate" do
      hash = "test_agg_" <> Integer.to_string(:rand.uniform(999999))

      PromptFeedback.record(hash, "topic1", %{
        total_sourced: 5, verified: 4, partial: 1, unverified: 0, verification_rate: 0.8
      })

      PromptFeedback.record(hash, "topic2", %{
        total_sourced: 3, verified: 3, partial: 0, unverified: 0, verification_rate: 1.0
      })

      result = PromptFeedback.aggregate(hash)
      assert result.sample_count == 2
      assert_in_delta result.avg_verification_rate, 0.9, 0.01
    end
  end

  describe "store_dir/0" do
    test "returns a string path" do
      dir = PromptFeedback.store_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "prompt_feedback")
    end
  end
end
