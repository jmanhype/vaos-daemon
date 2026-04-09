defmodule Daemon.Production.CharacterBenchmarkTest do
  use ExUnit.Case, async: false

  alias Daemon.Production.CharacterBenchmark
  alias Daemon.Production.ComfyUISceneRunner

  describe "normalize_brief/1" do
    test "requires a workflow path" do
      assert {:error, reason} = CharacterBenchmark.normalize_brief(%{"reference_pack" => [%{}]})
      assert reason =~ "workflow_path"
    end

    test "requires a non-empty reference pack" do
      assert {:error, reason} =
               CharacterBenchmark.normalize_brief(%{"workflow_path" => "/tmp/workflow.json"})

      assert reason =~ "reference_pack"
    end

    test "builds default shot matrix and validates reference slots" do
      assert {:ok, normalized} =
               CharacterBenchmark.normalize_brief(%{
                 "title" => "Elder Pack",
                 "workflow_path" => "/tmp/flux.workflow.json",
                 "reference_pack" => [
                   %{"label" => "anchor", "path" => "/tmp/anchor.jpg"},
                   %{"label" => "front", "path" => "/tmp/front.png"}
                 ],
                 "reference_slots" => [
                   %{"label" => "anchor", "node_id" => "80", "input" => "image"},
                   %{"label" => "front", "node_id" => "181", "input" => "image"}
                 ],
                 "output_node_id" => "98",
                 "positive_prompt_node_id" => "86",
                 "scene_defaults" => %{
                   "steps" => 24,
                   "positive_prompt_prefix" =>
                     "Same exact elderly Native Alaskan man from the reference pack"
                 }
               })

      assert normalized.title == "Elder Pack"
      assert length(normalized.reference_pack) == 2
      assert length(normalized.shots) == 5
      assert Enum.any?(normalized.evaluation["criteria"], &(&1["key"] == "identity_match"))
      assert hd(normalized.reference_slots).label == "anchor"
    end

    test "requires reference slots for true multi-reference briefs" do
      assert {:error, reason} =
               CharacterBenchmark.normalize_brief(%{
                 "workflow_path" => "/tmp/flux.workflow.json",
                 "reference_pack" => [
                   %{"label" => "anchor", "path" => "/tmp/anchor.jpg"},
                   %{"label" => "left", "path" => "/tmp/left.png"}
                 ]
               })

      assert reason =~ "reference_slots"
    end

    test "rejects unused multi-reference pack entries" do
      assert {:error, reason} =
               CharacterBenchmark.normalize_brief(%{
                 "workflow_path" => "/tmp/flux.workflow.json",
                 "reference_pack" => [
                   %{"label" => "anchor", "path" => "/tmp/anchor.jpg"},
                   %{"label" => "left", "path" => "/tmp/left.png"}
                 ],
                 "reference_slots" => [
                   %{"label" => "anchor", "node_id" => "80", "input" => "image"}
                 ]
               })

      assert reason =~ "unused reference labels"
      assert reason =~ "left"
    end
  end

  describe "build_runner_brief/1" do
    test "expands shots into runner scenes with reference slot node overrides" do
      {:ok, normalized} =
        CharacterBenchmark.normalize_brief(%{
          "title" => "Elder Pack",
          "workflow_path" => "/tmp/flux.workflow.json",
          "output_node_id" => "98",
          "positive_prompt_node_id" => "86",
          "reference_pack" => [
            %{"label" => "anchor", "path" => "/tmp/anchor.jpg"},
            %{"label" => "left", "path" => "/tmp/left.png"}
          ],
          "reference_slots" => [
            %{"label" => "anchor", "node_id" => "80", "input" => "image"},
            %{"label" => "left", "node_id" => "81", "input" => "image"}
          ],
          "scene_defaults" => %{
            "steps" => 24,
            "negative_prompt" => "no text",
            "positive_prompt_prefix" =>
              "Same exact elderly Native Alaskan man from the reference pack"
          },
          "shots" => [
            %{"name" => "Front", "slug" => "front", "prompt_suffix" => "front-facing portrait"},
            %{
              "name" => "Left",
              "slug" => "left",
              "prompt_suffix" => "strong three-quarter left portrait"
            }
          ]
        })

      runner_brief = CharacterBenchmark.build_runner_brief(normalized)
      [front, left] = runner_brief["scenes"]

      assert runner_brief["title"] == "Elder Pack"
      assert front["workflow_path"] == "/tmp/flux.workflow.json"
      assert front["steps"] == 24
      assert front["output_extension"] == ".png"
      assert front["negative_prompt"] == "no text"
      assert front["positive_prompt"] =~ "front-facing portrait"
      refute Map.has_key?(front, "image")

      assert front["node_overrides"] == %{
               "80" => %{"image" => "/tmp/anchor.jpg"},
               "81" => %{"image" => "/tmp/left.png"},
               "86" => %{"text" => front["positive_prompt"]},
               "98" => %{"filename_prefix" => "elder_pack_front"}
             }

      assert left["output_prefix"] =~ "left"
      assert left["positive_prompt"] =~ "strong three-quarter left portrait"
    end
  end

  describe "produce/1" do
    test "writes a benchmark brief artifact and delegates to the scene runner" do
      runner = Process.whereis(ComfyUISceneRunner) || start_supervised!(ComfyUISceneRunner)
      assert is_pid(runner)

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "character_benchmark_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      workflow_path = Path.join(tmp_dir, "scene.workflow.json")
      output_dir = Path.join(tmp_dir, "outputs")

      workflow = %{
        "prompt" => %{
          "80" => %{"inputs" => %{"image" => "anchor.jpg"}},
          "5645" => %{"inputs" => %{"filename_prefix" => "test_prefix", "save_output" => true}}
        }
      }

      File.write!(workflow_path, Jason.encode!(workflow))

      assert {:ok, %{local_output_dir: ^output_dir, benchmark_path: benchmark_path}} =
               CharacterBenchmark.produce(%{
                 "title" => "Elder Benchmark",
                 "workflow_path" => workflow_path,
                 "remote_host" => "127.0.0.1",
                 "remote_user" => "nobody",
                 "remote_port" => 1,
                 "local_output_dir" => output_dir,
                 "reference_pack" => [
                   %{"label" => "anchor", "path" => "/tmp/anchor.jpg"}
                 ],
                 "shots" => [
                   %{
                     "name" => "Front",
                     "slug" => "front",
                     "prompt_suffix" => "front-facing portrait"
                   }
                 ],
                 "scene_defaults" => %{
                   "positive_prompt_prefix" =>
                     "Same exact elderly Native Alaskan man from the reference pack"
                 }
               })

      assert File.exists?(benchmark_path)

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
    end
  end
end
