defmodule Daemon.Production.ComfyUISceneRunnerTest do
  use ExUnit.Case, async: false

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

  describe "produce/1" do
    test "fails cleanly for local workflows when remote transfer fails" do
      runner = Process.whereis(ComfyUISceneRunner) || start_supervised!(ComfyUISceneRunner)
      assert is_pid(runner)

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "comfyui_scene_runner_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      workflow_path = Path.join(tmp_dir, "scene.workflow.json")
      output_dir = Path.join(tmp_dir, "outputs")

      workflow = %{
        "prompt" => %{
          "5645" => %{"inputs" => %{"filename_prefix" => "test_prefix", "save_output" => true}}
        }
      }

      File.write!(workflow_path, Jason.encode!(workflow))

      assert {:ok, %{local_output_dir: ^output_dir}} =
               ComfyUISceneRunner.produce(%{
                 "title" => "Regression",
                 "remote_host" => "127.0.0.1",
                 "remote_user" => "nobody",
                 "remote_port" => 1,
                 "local_output_dir" => output_dir,
                 "scenes" => [
                   %{
                     "name" => "Scene 01",
                     "workflow_path" => workflow_path,
                     "output_prefix" => "regression_scene01"
                   }
                 ]
               })

      deadline = System.monotonic_time(:millisecond) + 5_000

      wait_for_terminal_state = fn wait_for_terminal_state ->
        status = ComfyUISceneRunner.status()

        cond do
          status.state in [:failed, :complete, :aborted] ->
            status

          System.monotonic_time(:millisecond) > deadline ->
            flunk("expected terminal status, got #{inspect(status)}")

          true ->
            Process.sleep(100)
            wait_for_terminal_state.(wait_for_terminal_state)
        end
      end

      status = wait_for_terminal_state.(wait_for_terminal_state)

      assert status.state == :failed
      assert status.outputs == []
      assert Enum.any?(status.errors, &String.contains?(&1, "scp failed"))

      patched = Path.join(output_dir, "regression_scene01_#{status.run_id}_01.workflow.json")
      assert File.exists?(patched)
    end
  end
end
