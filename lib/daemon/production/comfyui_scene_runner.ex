defmodule Daemon.Production.ComfyUISceneRunner do
  @moduledoc """
  Remote ComfyUI/LTX scene runner for repeatable ID-LoRA batches.

  The runner patches API-form ComfyUI workflow JSON, submits it to a remote
  ComfyUI instance over SSH, waits for rendered `.mp4` outputs, and copies the
  outputs plus a manifest into a local output directory.

  Intended use case:

      Daemon.Production.ComfyUISceneRunner.produce(%{
        "title" => "Kinuk ID-LoRA",
        "remote_host" => "192.168.1.143",
        "remote_user" => "straughter",
        "scenes" => [
          %{
            "name" => "scene01",
            "workflow_path" => "/home/straughter/kinuk_reel_mini_v9_run/scene01.workflow.json",
            "output_prefix" => "kinuk_reel_scene01"
          }
        ]
      })
  """
  use GenServer

  require Logger

  alias Daemon.Tools.Builtins.ComputerUse.Adapters.RemoteSSH

  @poll_interval_ms 10_000
  @render_timeout_ms 45 * 60 * 1000

  @node_ids %{
    image: "100",
    audio: "101",
    steps: "5294",
    frames: "5530",
    video_combine: "5645",
    seed_a: "5698",
    seed_b: "5703",
    lora: "5717",
    positive_prompt: "5730",
    negative_prompt: "5731",
    unet: "5716",
    video_vae: "5734",
    audio_vae: "5735",
    audio_model: "5736",
    upscaler: "5737"
  }

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec produce(map()) ::
          {:ok, %{run_id: String.t(), local_output_dir: String.t()}}
          | {:error, term()}
  def produce(brief) when is_map(brief) do
    GenServer.call(__MODULE__, {:produce, brief}, :infinity)
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @spec abort() :: :ok
  def abort do
    GenServer.call(__MODULE__, :abort)
  end

  @doc false
  @spec normalize_brief(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_brief(brief) when is_map(brief) do
    scenes = get_any(brief, "scenes", [])

    cond do
      not is_list(scenes) or scenes == [] ->
        {:error, "brief must include a non-empty scenes list"}

      true ->
        run_id = timestamp_id()
        title = get_any(brief, "title", "ComfyUI Scene Run")
        local_output_dir = build_local_output_dir(brief, run_id)

        normalized_scenes =
          scenes
          |> Enum.with_index(1)
          |> Enum.map(fn {scene, index} -> normalize_scene(scene, index, run_id) end)

        case Enum.find(normalized_scenes, &match?({:error, _}, &1)) do
          {:error, reason} ->
            {:error, reason}

          nil ->
            {:ok,
             %{
               run_id: run_id,
               title: title,
               remote_host:
                 get_any(
                   brief,
                   "remote_host",
                   System.get_env("COMFYUI_REMOTE_HOST", "192.168.1.143")
                 ),
               remote_user:
                 get_any(
                   brief,
                   "remote_user",
                   System.get_env("COMFYUI_REMOTE_USER", "straughter")
                 ),
               remote_port: get_any(brief, "remote_port", 22),
               remote_output_dir:
                 get_any(brief, "remote_output_dir", "/home/straughter/ComfyUI/output"),
               remote_input_dir:
                 get_any(brief, "remote_input_dir", "/home/straughter/ComfyUI/input"),
               local_output_dir: local_output_dir,
               render_timeout_ms: get_any(brief, "render_timeout_ms", @render_timeout_ms),
               poll_interval_ms: get_any(brief, "poll_interval_ms", @poll_interval_ms),
               scenes: Enum.map(normalized_scenes, fn {:ok, scene} -> scene end)
             }}
        end
    end
  end

  @doc false
  @spec patch_workflow(map(), map()) :: map()
  def patch_workflow(%{"prompt" => prompt}, scene) when is_map(prompt) do
    patched_prompt =
      prompt
      |> maybe_put_input(@node_ids.image, "image", scene[:image])
      |> maybe_put_input(@node_ids.audio, "audio", scene[:audio])
      |> maybe_put_input(@node_ids.steps, "value", scene[:steps])
      |> maybe_put_input(@node_ids.frames, "value", scene[:frames])
      |> maybe_put_input(@node_ids.seed_a, "noise_seed", scene[:seed_a])
      |> maybe_put_input(@node_ids.seed_b, "noise_seed", scene[:seed_b])
      |> maybe_put_input(@node_ids.lora, "strength_model", scene[:lora_strength])
      |> maybe_put_input(@node_ids.unet, "unet_name", scene[:unet_name])
      |> maybe_put_input(@node_ids.video_vae, "vae_name", scene[:video_vae])
      |> maybe_put_input(@node_ids.audio_vae, "vae_name", scene[:audio_vae])
      |> maybe_put_input(@node_ids.audio_model, "model_name", scene[:audio_model])
      |> maybe_put_input(@node_ids.upscaler, "model_name", scene[:upscaler])
      |> maybe_put_input(@node_ids.video_combine, "filename_prefix", scene[:output_prefix])
      |> maybe_put_input(
        @node_ids.video_combine,
        "save_output",
        get_any(scene, :save_output, nil)
      )
      |> maybe_put_input(@node_ids.negative_prompt, "text", scene[:negative_prompt])
      |> put_positive_prompt(scene)
      |> apply_node_overrides(scene[:node_overrides])

    %{"prompt" => patched_prompt}
  end

  @doc false
  @spec patch_workflow_strict(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def patch_workflow_strict(%{"prompt" => prompt} = workflow, scene) when is_map(prompt) do
    case validate_patch_targets(prompt, scene) do
      :ok -> {:ok, patch_workflow(workflow, scene)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec prepare_scene_assets(map()) ::
          {map(), [%{local_path: String.t(), remote_name: String.t()}]}
  def prepare_scene_assets(scene) when is_map(scene) do
    asset_map =
      scene
      |> collect_scene_asset_paths()
      |> Enum.reduce(%{}, fn local_path, acc ->
        if Map.has_key?(acc, local_path) do
          acc
        else
          Map.put(acc, local_path, build_remote_asset_name(scene.output_prefix, local_path, acc))
        end
      end)

    prepared_scene = rewrite_scene_asset_refs(scene, asset_map)

    uploads =
      asset_map
      |> Enum.map(fn {local_path, remote_name} ->
        %{local_path: local_path, remote_name: remote_name}
      end)
      |> Enum.sort_by(& &1.remote_name)

    {prepared_scene, uploads}
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:produce, brief}, _from, %{state: :idle} = state) do
    with {:ok, normalized} <- normalize_brief(brief),
         :ok <- File.mkdir_p(normalized.local_output_dir) do
      write_manifest(
        normalized.local_output_dir,
        manifest_from_state(%{
          state
          | state: :running,
            run_id: normalized.run_id,
            title: normalized.title,
            current_scene: 0,
            total_scenes: length(normalized.scenes),
            local_output_dir: normalized.local_output_dir,
            remote_output_dir: normalized.remote_output_dir,
            started_at: DateTime.utc_now(),
            outputs: [],
            errors: []
        })
      )

      parent = self()

      {:ok, worker_pid} =
        Task.start(fn ->
          try do
            run_brief(parent, normalized)
          rescue
            error ->
              send(parent, {:run_failed, Exception.format(:error, error, __STACKTRACE__), nil})
          catch
            kind, reason ->
              send(parent, {:run_failed, Exception.format(kind, reason, __STACKTRACE__), nil})
          end
        end)

      new_state = %{
        state
        | state: :running,
          run_id: normalized.run_id,
          title: normalized.title,
          current_scene: 0,
          total_scenes: length(normalized.scenes),
          local_output_dir: normalized.local_output_dir,
          remote_output_dir: normalized.remote_output_dir,
          started_at: DateTime.utc_now(),
          outputs: [],
          errors: [],
          worker_pid: worker_pid
      }

      {:reply, {:ok, %{run_id: normalized.run_id, local_output_dir: normalized.local_output_dir}},
       new_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason, _conn} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:produce, _brief}, _from, state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, manifest_from_state(state), state}
  end

  def handle_call(:abort, _from, state) do
    if is_pid(state.worker_pid) and Process.alive?(state.worker_pid) do
      Process.exit(state.worker_pid, :kill)
    end

    new_state = %{
      state
      | state: :aborted,
        finished_at: DateTime.utc_now(),
        errors: state.errors ++ ["run aborted"]
    }

    maybe_write_manifest(new_state)
    broadcast(:aborted, %{run_id: state.run_id, title: state.title})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:scene_started, index, scene}, state) do
    new_state = %{state | current_scene: index}
    maybe_write_manifest(new_state)
    broadcast(:scene_started, %{run_id: state.run_id, scene: index, name: scene[:name]})
    {:noreply, new_state}
  end

  def handle_info({:scene_complete, output}, state) do
    new_state = %{state | outputs: state.outputs ++ [output]}
    maybe_write_manifest(new_state)

    broadcast(:scene_complete, %{
      run_id: state.run_id,
      scene: output.scene_index,
      local_output_path: output.local_output_path
    })

    {:noreply, new_state}
  end

  def handle_info({:run_failed, reason, partial_outputs}, state) do
    outputs = partial_outputs || state.outputs

    new_state = %{
      state
      | state: :failed,
        outputs: outputs,
        errors: state.errors ++ [reason],
        finished_at: DateTime.utc_now(),
        worker_pid: nil
    }

    maybe_write_manifest(new_state)
    broadcast(:failed, %{run_id: state.run_id, reason: reason})
    {:noreply, new_state}
  end

  def handle_info({:run_finished, outputs}, state) do
    new_state = %{
      state
      | state: :complete,
        outputs: outputs,
        finished_at: DateTime.utc_now(),
        worker_pid: nil
    }

    maybe_write_manifest(new_state)

    broadcast(:complete, %{
      run_id: state.run_id,
      title: state.title,
      outputs: Enum.map(outputs, & &1.local_output_path)
    })

    {:noreply, new_state}
  end

  # ── Worker ──────────────────────────────────────────────────────────────

  defp run_brief(parent, brief) do
    outputs =
      Enum.reduce_while(Enum.with_index(brief.scenes, 1), [], fn {scene, index}, acc ->
        send(parent, {:scene_started, index, scene})

        case run_scene(brief, scene, index) do
          {:ok, output} ->
            next_outputs = acc ++ [output]
            send(parent, {:scene_complete, output})
            {:cont, next_outputs}

          {:error, reason} ->
            send(parent, {:run_failed, reason, acc})
            {:halt, :failed}
        end
      end)

    if is_list(outputs) do
      send(parent, {:run_finished, outputs})
    end
  end

  defp run_scene(brief, scene, index) do
    with {:ok, workflow} <- load_workflow(brief, scene.workflow_path),
         {prepared_scene, uploads} = prepare_scene_assets(scene),
         :ok <- stage_scene_assets(brief, uploads),
         {:ok, patched_workflow} <- patch_workflow_strict(workflow, prepared_scene),
         {:ok, local_workflow_path} <- write_patched_workflow(brief, scene, patched_workflow),
         remote_workflow_path = "/tmp/#{scene.output_prefix}.workflow.json",
         :ok <- scp_to_remote(brief, local_workflow_path, remote_workflow_path),
         {:ok, prompt_id} <- submit_remote_workflow(brief, remote_workflow_path),
         {:ok, remote_output_path} <-
           wait_for_remote_output(
             brief,
             prepared_scene.output_prefix,
             prepared_scene.output_extension
           ),
         {:ok, local_output_path} <-
           copy_remote_output(brief, remote_output_path, brief.local_output_dir) do
      {:ok,
       %{
         scene_index: index,
         scene_name: scene.name,
         workflow_path: scene.workflow_path,
         patched_workflow_path: local_workflow_path,
         output_prefix: prepared_scene.output_prefix,
         prompt_id: prompt_id,
         remote_output_path: remote_output_path,
         local_output_path: local_output_path
       }}
    end
  end

  # ── Remote interaction ─────────────────────────────────────────────────

  defp load_workflow(brief, workflow_path) do
    if File.exists?(workflow_path) do
      case File.read(workflow_path) do
        {:ok, json} ->
          decode_workflow(json, workflow_path)

        {:error, reason} ->
          {:error, "failed to read workflow #{workflow_path}: #{:file.format_error(reason)}"}
      end
    else
      script = """
      python3 - <<'PY'
      import pathlib
      print(pathlib.Path(#{inspect(workflow_path)}).read_text())
      PY
      """

      case remote_cmd(brief, script) do
        {:ok, json} -> decode_workflow(json, workflow_path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_workflow(json, source_path) do
    case Jason.decode(json) do
      {:ok, %{"prompt" => _} = workflow} ->
        {:ok, workflow}

      {:ok, _other} ->
        {:error, "workflow #{source_path} is not an API-format ComfyUI prompt"}

      {:error, reason} ->
        {:error, "failed to decode workflow #{source_path}: #{Exception.message(reason)}"}
    end
  end

  defp write_patched_workflow(brief, scene, workflow) do
    path = Path.join(brief.local_output_dir, "#{scene.output_prefix}.workflow.json")

    case File.write(path, Jason.encode_to_iodata!(workflow, pretty: true)) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        {:error, "failed to write patched workflow: #{:file.format_error(reason)}"}
    end
  rescue
    e ->
      {:error, "failed to write patched workflow: #{Exception.message(e)}"}
  end

  defp submit_remote_workflow(brief, remote_workflow_path) do
    command = """
    curl -sS -X POST -H 'Content-Type: application/json' --data-binary @#{RemoteSSH.shell_escape(remote_workflow_path)} http://127.0.0.1:8188/prompt
    """

    with {:ok, body} <- remote_cmd(brief, command),
         {:ok, %{"prompt_id" => prompt_id}} <- Jason.decode(body) do
      {:ok, prompt_id}
    else
      {:ok, %{"error" => error}} -> {:error, "ComfyUI rejected prompt: #{error}"}
      {:ok, decoded} -> {:error, "unexpected ComfyUI response: #{inspect(decoded)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_remote_output(brief, output_prefix, output_extension) do
    deadline = System.monotonic_time(:millisecond) + brief.render_timeout_ms
    do_wait_for_remote_output(brief, output_prefix, output_extension, deadline, nil, 0)
  end

  defp do_wait_for_remote_output(
         brief,
         output_prefix,
         output_extension,
         deadline,
         last_size,
         stable_count
       ) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "timed out waiting for remote output for #{output_prefix}"}
    else
      case latest_remote_output(brief, output_prefix, output_extension) do
        {:ok, nil} ->
          Process.sleep(brief.poll_interval_ms)

          do_wait_for_remote_output(
            brief,
            output_prefix,
            output_extension,
            deadline,
            last_size,
            stable_count
          )

        {:ok, %{path: path, size: size}} when size > 0 ->
          next_stable = if size == last_size, do: stable_count + 1, else: 1

          if next_stable >= 2 do
            {:ok, path}
          else
            Process.sleep(brief.poll_interval_ms)

            do_wait_for_remote_output(
              brief,
              output_prefix,
              output_extension,
              deadline,
              size,
              next_stable
            )
          end

        {:ok, _} ->
          Process.sleep(brief.poll_interval_ms)

          do_wait_for_remote_output(
            brief,
            output_prefix,
            output_extension,
            deadline,
            last_size,
            stable_count
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp latest_remote_output(brief, output_prefix, output_extension) do
    pattern = Path.join(brief.remote_output_dir, "#{output_prefix}_*#{output_extension}")

    script = """
    python3 - <<'PY'
    import glob
    import json
    import os

    matches = sorted(glob.glob(#{inspect(pattern)}), key=os.path.getmtime, reverse=True)

    if matches:
      path = matches[0]
      print(json.dumps({"path": path, "size": os.path.getsize(path)}))
    else:
      print("null")
    PY
    """

    with {:ok, body} <- remote_cmd(brief, script),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        nil ->
          {:ok, nil}

        %{"path" => path, "size" => size} ->
          {:ok, %{path: path, size: size}}

        other ->
          {:error, "unexpected latest-output payload: #{inspect(other)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_remote_output(brief, remote_output_path, local_output_dir) do
    local_output_path = Path.join(local_output_dir, Path.basename(remote_output_path))

    args =
      build_scp_args(brief) ++
        ["#{brief.remote_user}@#{brief.remote_host}:#{remote_output_path}", local_output_path]

    case System.cmd("scp", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, local_output_path}

      {output, code} ->
        {:error, "scp failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e ->
      {:error, "scp raised: #{Exception.message(e)}"}
  end

  defp scp_to_remote(brief, local_path, remote_path) do
    args =
      build_scp_args(brief) ++
        [local_path, "#{brief.remote_user}@#{brief.remote_host}:#{remote_path}"]

    case System.cmd("scp", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "scp failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e ->
      {:error, "scp raised: #{Exception.message(e)}"}
  end

  defp remote_cmd(brief, command) do
    args =
      build_ssh_args(brief) ++
        ["#{brief.remote_user}@#{brief.remote_host}", command]

    case System.cmd("ssh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, "ssh failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e ->
      {:error, "ssh raised: #{Exception.message(e)}"}
  end

  # ── Workflow patching helpers ──────────────────────────────────────────

  defp validate_patch_targets(prompt, scene) do
    targets =
      built_in_patch_targets(scene)
      |> Enum.filter(fn {node_id, _input_key} -> Map.has_key?(prompt, node_id) end)
      |> Kernel.++(
        node_override_targets(get_any(scene, :node_overrides, nil))
      )

    case Enum.find(targets, fn {node_id, input_key} ->
           not patch_target_exists?(prompt, node_id, input_key)
         end) do
      nil ->
        :ok

      {node_id, input_key} ->
        {:error, "workflow patch target missing node/input #{node_id}:#{input_key}"}
    end
  end

  defp built_in_patch_targets(scene) do
    [
      {scene[:image], @node_ids.image, "image"},
      {scene[:audio], @node_ids.audio, "audio"},
      {scene[:steps], @node_ids.steps, "value"},
      {scene[:frames], @node_ids.frames, "value"},
      {scene[:seed_a], @node_ids.seed_a, "noise_seed"},
      {scene[:seed_b], @node_ids.seed_b, "noise_seed"},
      {scene[:lora_strength], @node_ids.lora, "strength_model"},
      {scene[:unet_name], @node_ids.unet, "unet_name"},
      {scene[:video_vae], @node_ids.video_vae, "vae_name"},
      {scene[:audio_vae], @node_ids.audio_vae, "vae_name"},
      {scene[:audio_model], @node_ids.audio_model, "model_name"},
      {scene[:upscaler], @node_ids.upscaler, "model_name"},
      {scene[:output_prefix], @node_ids.video_combine, "filename_prefix"},
      {get_any(scene, :save_output, nil), @node_ids.video_combine, "save_output"},
      {scene[:negative_prompt], @node_ids.negative_prompt, "text"},
      {positive_prompt_target(scene), @node_ids.positive_prompt, "text"}
    ]
    |> Enum.flat_map(fn
      {nil, _node_id, _input_key} -> []
      {_value, node_id, input_key} -> [{node_id, input_key}]
    end)
  end

  defp positive_prompt_target(scene) do
    cond do
      scene[:positive_prompt] -> scene[:positive_prompt]
      scene[:speech_text] -> scene[:speech_text]
      true -> nil
    end
  end

  defp node_override_targets(nil), do: []

  defp node_override_targets(overrides) when is_map(overrides) do
    Enum.flat_map(overrides, fn {node_id, inputs} ->
      if is_map(inputs) do
        Enum.map(inputs, fn {input_key, _value} -> {to_string(node_id), to_string(input_key)} end)
      else
        []
      end
    end)
  end

  defp node_override_targets(_other), do: []

  defp patch_target_exists?(prompt, node_id, input_key) do
    case get_in(prompt, [to_string(node_id), "inputs"]) do
      inputs when is_map(inputs) -> Map.has_key?(inputs, to_string(input_key))
      _other -> false
    end
  end

  defp collect_scene_asset_paths(scene) do
    top_level =
      [scene[:image], scene[:audio]]
      |> Enum.filter(&local_asset_path?/1)

    override_paths =
      scene
      |> get_any(:node_overrides, %{})
      |> collect_override_asset_paths()

    Enum.uniq(top_level ++ override_paths)
  end

  defp collect_override_asset_paths(overrides) when is_map(overrides) do
    overrides
    |> Map.values()
    |> Enum.flat_map(fn
      inputs when is_map(inputs) ->
        inputs
        |> Map.values()
        |> Enum.filter(&local_asset_path?/1)

      _other ->
        []
    end)
  end

  defp collect_override_asset_paths(_other), do: []

  defp local_asset_path?(value) when is_binary(value), do: File.exists?(value)
  defp local_asset_path?(_other), do: false

  defp build_remote_asset_name(output_prefix, local_path, existing_map) do
    basename = Path.basename(local_path)
    candidate = "#{output_prefix}__#{basename}"

    if Enum.any?(existing_map, fn {_path, remote_name} -> remote_name == candidate end) do
      ext = Path.extname(basename)
      stem = Path.rootname(basename, ext)
      index = map_size(existing_map) + 1
      "#{output_prefix}__#{stem}_#{index}#{ext}"
    else
      candidate
    end
  end

  defp rewrite_scene_asset_refs(scene, asset_map) do
    rewritten_overrides =
      scene
      |> get_any(:node_overrides, %{})
      |> rewrite_override_asset_paths(asset_map)

    scene
    |> maybe_rewrite_scene_asset(:image, asset_map)
    |> maybe_rewrite_scene_asset(:audio, asset_map)
    |> Map.put(:node_overrides, rewritten_overrides)
  end

  defp rewrite_override_asset_paths(overrides, asset_map) when is_map(overrides) do
    Enum.into(overrides, %{}, fn {node_id, inputs} ->
      rewritten_inputs =
        if is_map(inputs) do
          Enum.into(inputs, %{}, fn {input_key, value} ->
            {input_key, Map.get(asset_map, value, value)}
          end)
        else
          inputs
        end

      {node_id, rewritten_inputs}
    end)
  end

  defp rewrite_override_asset_paths(_other, _asset_map), do: %{}

  defp maybe_rewrite_scene_asset(scene, key, asset_map) do
    case Map.get(scene, key) do
      value when is_binary(value) ->
        Map.put(scene, key, Map.get(asset_map, value, value))

      _other ->
        scene
    end
  end

  defp stage_scene_assets(_brief, []), do: :ok

  defp stage_scene_assets(brief, uploads) do
    with :ok <- ensure_remote_dir(brief, brief.remote_input_dir) do
      Enum.reduce_while(uploads, :ok, fn upload, :ok ->
        remote_path = Path.join(brief.remote_input_dir, upload.remote_name)

        case scp_to_remote(brief, upload.local_path, remote_path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ensure_remote_dir(brief, remote_dir) do
    command = "mkdir -p #{RemoteSSH.shell_escape(remote_dir)}"

    case remote_cmd(brief, command) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_positive_prompt(prompt, scene) do
    positive_prompt =
      cond do
        scene[:positive_prompt] ->
          scene[:positive_prompt]

        scene[:speech_text] ->
          current = get_in(prompt, [@node_ids.positive_prompt, "inputs", "text"]) || ""
          replace_speech_text(current, scene[:speech_text])

        true ->
          nil
      end

    maybe_put_input(prompt, @node_ids.positive_prompt, "text", positive_prompt)
  end

  defp replace_speech_text(existing_prompt, speech_text)
       when is_binary(existing_prompt) and is_binary(speech_text) do
    Regex.replace(
      ~r/\[SPEECH\]: He says: .*?(?=\n\[SOUND\]:|\z)/s,
      existing_prompt,
      "[SPEECH]: He says: #{speech_text}"
    )
  end

  defp maybe_put_input(prompt, _node_id, _key, nil), do: prompt

  defp maybe_put_input(prompt, node_id, key, value) do
    if get_in(prompt, [node_id, "inputs"]) do
      put_in(prompt, [node_id, "inputs", key], value)
    else
      prompt
    end
  end

  defp normalize_scene(scene, index, run_id) when is_map(scene) do
    workflow_path = get_any(scene, "workflow_path")

    if is_binary(workflow_path) and workflow_path != "" do
      name = get_any(scene, "name", "scene#{index}")
      base_prefix = get_any(scene, "output_prefix", Path.rootname(Path.basename(workflow_path)))
      scene_slug = slugify(name)

      {:ok,
       %{
         name: name,
         slug: scene_slug,
         workflow_path: workflow_path,
         output_prefix:
           "#{base_prefix}_#{run_id}_#{String.pad_leading(Integer.to_string(index), 2, "0")}",
         image: get_any(scene, "image"),
         audio: get_any(scene, "audio"),
         steps: get_any(scene, "steps"),
         frames: get_any(scene, "frames"),
         seed_a: get_any(scene, "seed_a"),
         seed_b: get_any(scene, "seed_b"),
         lora_strength: get_any(scene, "lora_strength"),
         positive_prompt: get_any(scene, "positive_prompt"),
         negative_prompt: get_any(scene, "negative_prompt"),
         speech_text: get_any(scene, "speech_text"),
         unet_name: get_any(scene, "unet_name"),
         video_vae: get_any(scene, "video_vae"),
         audio_vae: get_any(scene, "audio_vae"),
         audio_model: get_any(scene, "audio_model"),
         upscaler: get_any(scene, "upscaler"),
         save_output: get_any(scene, "save_output"),
         node_overrides: get_any(scene, "node_overrides"),
         output_extension: normalize_output_extension(get_any(scene, "output_extension", ".mp4"))
       }}
    else
      {:error, "scene #{index} is missing workflow_path"}
    end
  end

  defp apply_node_overrides(prompt, nil), do: prompt

  defp apply_node_overrides(prompt, overrides) when is_map(overrides) do
    Enum.reduce(overrides, prompt, fn {node_id, inputs}, acc ->
      node_id = to_string(node_id)

      if is_map(inputs) do
        Enum.reduce(inputs, acc, fn {input_key, value}, prompt_acc ->
          maybe_put_input(prompt_acc, node_id, to_string(input_key), value)
        end)
      else
        acc
      end
    end)
  end

  defp apply_node_overrides(prompt, _other), do: prompt

  defp normalize_output_extension(value) when is_binary(value) and value != "" do
    if String.starts_with?(value, "."), do: value, else: ".#{value}"
  end

  defp normalize_output_extension(_other), do: ".mp4"

  # ── State / manifest ───────────────────────────────────────────────────

  defp initial_state do
    %{
      state: :idle,
      run_id: nil,
      title: nil,
      current_scene: 0,
      total_scenes: 0,
      local_output_dir: nil,
      remote_output_dir: nil,
      outputs: [],
      errors: [],
      started_at: nil,
      finished_at: nil,
      worker_pid: nil
    }
  end

  defp manifest_from_state(state) do
    %{
      state: state.state,
      run_id: state.run_id,
      title: state.title,
      current_scene: state.current_scene,
      total_scenes: state.total_scenes,
      local_output_dir: state.local_output_dir,
      remote_output_dir: state.remote_output_dir,
      outputs: state.outputs,
      errors: state.errors,
      started_at: iso_datetime(state.started_at),
      finished_at: iso_datetime(state.finished_at)
    }
  end

  defp maybe_write_manifest(%{local_output_dir: nil}), do: :ok

  defp maybe_write_manifest(state) do
    write_manifest(state.local_output_dir, manifest_from_state(state))
  end

  defp write_manifest(dir, manifest) do
    File.write!(Path.join(dir, "manifest.json"), Jason.encode_to_iodata!(manifest, pretty: true))
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(
      Daemon.PubSub,
      "osa:production",
      {:comfyui_scene_runner, event, payload}
    )
  end

  # ── Generic helpers ────────────────────────────────────────────────────

  defp build_local_output_dir(brief, run_id) do
    case get_any(brief, "local_output_dir") do
      nil ->
        Path.join(Path.expand("~/Downloads/vaos-comfyui"), run_id)

      path ->
        Path.expand(path)
    end
  end

  defp build_ssh_args(brief) do
    base = [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "BatchMode=yes"
    ]

    if brief.remote_port && brief.remote_port != 22 do
      base ++ ["-p", to_string(brief.remote_port)]
    else
      base
    end
  end

  defp build_scp_args(brief) do
    base = [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "BatchMode=yes"
    ]

    if brief.remote_port && brief.remote_port != 22 do
      base ++ ["-P", to_string(brief.remote_port)]
    else
      base
    end
  end

  defp get_any(map, key, default \\ nil) do
    keys =
      [key]
      |> maybe_prepend_string_key(key)
      |> maybe_prepend_atom_key(key)

    Enum.reduce_while(keys, default, fn candidate, _acc ->
      case Map.fetch(map, candidate) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, default}
      end
    end)
  end

  defp maybe_prepend_string_key(keys, key) when is_atom(key), do: [Atom.to_string(key) | keys]
  defp maybe_prepend_string_key(keys, _key), do: keys

  defp maybe_prepend_atom_key(keys, key) when is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if atom_key, do: [atom_key | keys], else: keys
  end

  defp maybe_prepend_atom_key(keys, _key), do: keys

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp timestamp_id do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9]/, "")
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
