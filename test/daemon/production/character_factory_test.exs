defmodule Daemon.Production.CharacterFactoryTest do
  use ExUnit.Case, async: true

  alias Daemon.Production.CharacterFactory

  describe "normalize_brief/1" do
    test "requires workflow paths" do
      assert {:error, reason} = CharacterFactory.normalize_brief(%{})
      assert reason =~ "qwen_workflow_path"
    end

    test "provides the default six-character roster" do
      assert {:ok, brief} =
               CharacterFactory.normalize_brief(%{
                 "qwen_workflow_path" => "/tmp/qwen.json",
                 "klein_workflow_path" => "/tmp/klein.json"
               })

      assert brief.title == "Six Character LoRA Factory"
      assert length(brief.characters) == 6
      assert Enum.any?(brief.characters, &(&1.slug == "elder_man"))
      assert Enum.any?(brief.characters, &(&1.slug == "harbor_woman"))
      assert Enum.any?(brief.characters, &(&1.slug == "talking_golden_retriever"))
    end
  end

  describe "produce/1" do
    test "writes a complete character program scaffold" do
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "character_factory_test_#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{program_path: program_path, base_output_dir: ^base_dir, character_count: 1}} =
               CharacterFactory.produce(%{
                 "title" => "Test Factory",
                 "base_output_dir" => base_dir,
                 "qwen_workflow_path" => "/tmp/qwen.json",
                 "klein_workflow_path" => "/tmp/klein.json",
                 "no_id_video_ui_path" => "/tmp/no-id-ui.json",
                 "fallback_video_api_path" => "/tmp/fallback-video.json",
                 "characters" => [
                   %{
                     "slug" => "test_mascot",
                     "name" => "Test Mascot",
                     "kind" => "cartoon",
                     "gender" => "unspecified",
                     "environment" => "test stage",
                     "anchor_prompt" => "test anchor prompt",
                     "positive_prompt_prefix" => "same exact test mascot",
                     "speech_text_16s" => "This is a test line for a sixteen second clip."
                   }
                 ]
               })

      assert File.exists?(program_path)

      character_dir = Path.join(base_dir, "test_mascot")

      for relative_path <- [
            "character.json",
            "qwen_anchor.plan.json",
            "klein_refpack.plan.json",
            "benchmark.brief.json",
            "lora_training.plan.json",
            "video_16s.plan.json"
          ] do
        assert File.exists?(Path.join(character_dir, relative_path))
      end

      benchmark =
        character_dir
        |> Path.join("benchmark.brief.json")
        |> File.read!()
        |> Jason.decode!()

      assert benchmark["workflow_path"] == "/tmp/klein.json"
      assert benchmark["reference_slots"] |> length() == 6
      assert benchmark["scene_defaults"]["steps"] == 24

      refpack =
        character_dir
        |> Path.join("klein_refpack.plan.json")
        |> File.read!()
        |> Jason.decode!()

      assert length(refpack["dataset_targets"]) == 40
      assert hd(refpack["hero_targets"])["output_path"] =~ "test_mascot_front_klein.png"

      video_plan =
        character_dir
        |> Path.join("video_16s.plan.json")
        |> File.read!()
        |> Jason.decode!()

      assert video_plan["duration_seconds"] == 16
      assert video_plan["fallback_video_api_path"] == "/tmp/fallback-video.json"
    end
  end
end
