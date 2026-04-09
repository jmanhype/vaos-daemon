defmodule Daemon.Production.ComfyUISceneRunnerTest do
  use ExUnit.Case, async: true

  alias Daemon.Production.ComfyUISceneRunner

  describe "normalize_brief/1" do
    test "requires at least one scene" do
      assert {:error, reason} = ComfyUISceneRunner.normalize_brief(%{})
      assert reason =~ "non-empty scenes list"
    end

    test "generates run metadata and unique output prefixes" do
      assert {:ok, brief} =
               ComfyUISceneRunner.normalize_brief(%{
                 "title" => "Kinuk",
                 "scenes" => [
                   %{"name" => "Scene 01", "workflow_path" => "/tmp/scene01.workflow.json"},
                   %{"name" => "Scene 02", "workflow_path" => "/tmp/scene02.workflow.json"}
                 ]
               })

      assert brief.title == "Kinuk"
      assert String.starts_with?(brief.local_output_dir, Path.expand("~/Downloads/vaos-comfyui"))
      assert length(brief.scenes) == 2
      assert Enum.at(brief.scenes, 0).output_prefix =~ brief.run_id
      assert Enum.at(brief.scenes, 1).output_prefix =~ brief.run_id
      refute Enum.at(brief.scenes, 0).output_prefix == Enum.at(brief.scenes, 1).output_prefix
    end
  end

  describe "patch_workflow/2" do
    test "applies scene overrides to the known node ids" do
      workflow = %{
        "prompt" => %{
          "100" => %{"inputs" => %{"image" => "old.jpg"}},
          "101" => %{"inputs" => %{"audio" => "old.wav"}},
          "5294" => %{"inputs" => %{"value" => 30}},
          "5530" => %{"inputs" => %{"value" => 190}},
          "5645" => %{"inputs" => %{"filename_prefix" => "old_prefix", "save_output" => true}},
          "5698" => %{"inputs" => %{"noise_seed" => 1}},
          "5703" => %{"inputs" => %{"noise_seed" => 2}},
          "5717" => %{"inputs" => %{"strength_model" => 1.0}},
          "5730" => %{
            "inputs" => %{
              "text" =>
                "[VISUAL]: cabin\n[SPEECH]: He says: old line.\n[SOUND]: quiet cabin room tone only; clear voice, no distortion"
            }
          },
          "5731" => %{"inputs" => %{"text" => "old negative"}}
        }
      }

      patched =
        ComfyUISceneRunner.patch_workflow(workflow, %{
          image: "new.jpg",
          audio: "new.wav",
          steps: 8,
          frames: 385,
          seed_a: 123,
          seed_b: 456,
          lora_strength: 0.5,
          output_prefix: "scene01_new",
          speech_text: "Ain't no party like a Bad Boy party.",
          negative_prompt: "no text"
        })

      prompt = patched["prompt"]

      assert get_in(prompt, ["100", "inputs", "image"]) == "new.jpg"
      assert get_in(prompt, ["101", "inputs", "audio"]) == "new.wav"
      assert get_in(prompt, ["5294", "inputs", "value"]) == 8
      assert get_in(prompt, ["5530", "inputs", "value"]) == 385
      assert get_in(prompt, ["5698", "inputs", "noise_seed"]) == 123
      assert get_in(prompt, ["5703", "inputs", "noise_seed"]) == 456
      assert get_in(prompt, ["5717", "inputs", "strength_model"]) == 0.5
      assert get_in(prompt, ["5645", "inputs", "filename_prefix"]) == "scene01_new"
      assert get_in(prompt, ["5730", "inputs", "text"]) =~ "Ain't no party like a Bad Boy party."
      assert get_in(prompt, ["5731", "inputs", "text"]) == "no text"
    end
  end
end
