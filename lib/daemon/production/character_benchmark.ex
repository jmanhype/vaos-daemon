defmodule Daemon.Production.CharacterBenchmark do
  @moduledoc """
  Expands a reusable character-benchmark brief into a ComfyUI runner brief.

  The benchmark brief keeps three things together:

  * the canonical reference pack
  * a fixed shot matrix to evaluate consistency
  * the runnable ComfyUI scene brief generated from those inputs

  This lets future workflow variants compete against the same shot/evaluation
  matrix without rebuilding ad hoc scene lists by hand.
  """

  alias Daemon.Production.ComfyUISceneRunner

  @runner_forward_keys ~w(
    image
    audio
    steps
    frames
    seed_a
    seed_b
    lora_strength
    positive_prompt
    negative_prompt
    speech_text
    unet_name
    video_vae
    audio_vae
    audio_model
    upscaler
    save_output
  )

  @default_shots [
    %{
      "name" => "Front",
      "slug" => "front",
      "prompt_suffix" => "front-facing portrait, direct to camera, calm neutral expression"
    },
    %{
      "name" => "ThreeQuarter Left",
      "slug" => "three_quarter_left",
      "prompt_suffix" =>
        "strong three-quarter left portrait, head turned about 35 degrees to his left, shoulders slightly rotated left, still recognizable as the same man, not profile"
    },
    %{
      "name" => "ThreeQuarter Right",
      "slug" => "three_quarter_right",
      "prompt_suffix" =>
        "strong three-quarter right portrait, head turned about 35 degrees to his right, shoulders slightly rotated right, still recognizable as the same man, not profile"
    },
    %{
      "name" => "Up",
      "slug" => "up",
      "prompt_suffix" =>
        "head mostly facing camera, slight upward gaze, chin gently raised, eyes looking up a little, calm expression"
    },
    %{
      "name" => "Down",
      "slug" => "down",
      "prompt_suffix" =>
        "head mostly facing camera, slight downward gaze, chin gently lowered, eyes looking down a little, calm expression, eyes open"
    }
  ]

  @default_evaluation %{
    "criteria" => [
      %{
        "key" => "identity_match",
        "weight" => 0.45,
        "question" => "Does this still look like the same exact person as the anchor reference?"
      },
      %{
        "key" => "angle_accuracy",
        "weight" => 0.20,
        "question" => "Does the image match the requested shot angle and gaze direction?"
      },
      %{
        "key" => "attribute_retention",
        "weight" => 0.20,
        "question" => "Are age, hair, sweater, and face structure preserved?"
      },
      %{
        "key" => "artifact_penalty",
        "weight" => 0.15,
        "question" => "Are there eye, hand, text, blur, or anatomy artifacts?"
      }
    ],
    "promotion_rule" => %{
      "notes" =>
        "Promote only outputs that preserve identity and add coverage without visible artifacts.",
      "required_passes" => ["identity_match", "angle_accuracy", "attribute_retention"]
    }
  }

  @spec normalize_brief(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_brief(brief) when is_map(brief) do
    with {:ok, workflow_path} <- require_string(brief, "workflow_path"),
         {:ok, reference_pack} <- normalize_reference_pack(get_any(brief, "reference_pack", [])),
         {:ok, reference_slots} <-
           normalize_reference_slots(get_any(brief, "reference_slots", []), reference_pack),
         :ok <- validate_reference_slot_coverage(reference_pack, reference_slots),
         {:ok, shots} <- normalize_shots(get_any(brief, "shots", @default_shots)) do
      title = get_any(brief, "title", "Character Benchmark")
      scene_defaults = normalize_map(get_any(brief, "scene_defaults", %{}))

      primary_reference_label =
        get_any(brief, "primary_reference_label", hd(reference_pack).label)

      reference_image = get_any(brief, "reference_image")

      local_output_dir = build_local_output_dir(brief)
      output_prefix_base = get_any(brief, "output_prefix_base", slugify(title))

      with :ok <- validate_primary_reference_label(reference_pack, primary_reference_label) do
        {:ok,
         %{
           title: title,
           workflow_path: workflow_path,
           local_output_dir: local_output_dir,
           output_prefix_base: output_prefix_base,
           remote_host: get_any(brief, "remote_host"),
           remote_user: get_any(brief, "remote_user"),
           remote_port: get_any(brief, "remote_port"),
           remote_output_dir: get_any(brief, "remote_output_dir"),
           render_timeout_ms: get_any(brief, "render_timeout_ms"),
           poll_interval_ms: get_any(brief, "poll_interval_ms"),
           output_extension:
             normalize_output_extension(get_any(brief, "output_extension", ".png")),
           output_node_id: get_any(brief, "output_node_id"),
           output_input_key: get_any(brief, "output_input_key", "filename_prefix"),
           positive_prompt_node_id: get_any(brief, "positive_prompt_node_id"),
           positive_prompt_input_key: get_any(brief, "positive_prompt_input_key", "text"),
           negative_prompt_node_id: get_any(brief, "negative_prompt_node_id"),
           negative_prompt_input_key: get_any(brief, "negative_prompt_input_key", "text"),
           primary_reference_label: primary_reference_label,
           reference_image:
             resolve_reference_image(reference_image, reference_pack, primary_reference_label),
           reference_pack: reference_pack,
           reference_slots: reference_slots,
           shots: shots,
           scene_defaults: scene_defaults,
           evaluation: get_any(brief, "evaluation", @default_evaluation)
         }}
      end
    end
  end

  @spec build_runner_brief(map()) :: map()
  def build_runner_brief(normalized) when is_map(normalized) do
    reference_node_overrides =
      reference_slot_overrides(normalized.reference_slots, normalized.reference_pack)

    scenes =
      Enum.map(normalized.shots, fn shot ->
        defaults = forward_scene_keys(normalized.scene_defaults)
        shot_forward = forward_scene_keys(shot.raw)
        output_prefix = "#{normalized.output_prefix_base}_#{shot.slug}"
        positive_prompt = build_positive_prompt(normalized, shot)

        negative_prompt =
          get_any(
            shot.raw,
            "negative_prompt",
            get_any(normalized.scene_defaults, "negative_prompt")
          )

        merged_node_overrides =
          merge_node_overrides([
            get_any(normalized.scene_defaults, "node_overrides", %{}),
            reference_node_overrides,
            output_node_override(
              normalized.output_node_id,
              normalized.output_input_key,
              output_prefix
            ),
            prompt_node_override(
              normalized.positive_prompt_node_id,
              normalized.positive_prompt_input_key,
              positive_prompt
            ),
            prompt_node_override(
              normalized.negative_prompt_node_id,
              normalized.negative_prompt_input_key,
              negative_prompt
            ),
            get_any(shot.raw, "node_overrides", %{})
          ])

        defaults
        |> Map.merge(shot_forward)
        |> Map.put("name", shot.name)
        |> Map.put("workflow_path", normalized.workflow_path)
        |> Map.put("output_prefix", output_prefix)
        |> Map.put("output_extension", normalized.output_extension)
        |> maybe_put("image", normalized.reference_image)
        |> maybe_put("positive_prompt", positive_prompt)
        |> maybe_put("node_overrides", empty_to_nil(merged_node_overrides))
      end)

    %{}
    |> maybe_put("title", normalized.title)
    |> maybe_put("remote_host", normalized.remote_host)
    |> maybe_put("remote_user", normalized.remote_user)
    |> maybe_put("remote_port", normalized.remote_port)
    |> maybe_put("remote_output_dir", normalized.remote_output_dir)
    |> maybe_put("render_timeout_ms", normalized.render_timeout_ms)
    |> maybe_put("poll_interval_ms", normalized.poll_interval_ms)
    |> maybe_put("output_extension", normalized.output_extension)
    |> Map.put("local_output_dir", normalized.local_output_dir)
    |> Map.put("scenes", scenes)
  end

  @spec produce(map()) ::
          {:ok,
           %{
             run_id: String.t(),
             local_output_dir: String.t(),
             benchmark_path: String.t(),
             shot_count: non_neg_integer(),
             reference_count: non_neg_integer()
           }}
          | {:error, term()}
  def produce(brief) when is_map(brief) do
    with {:ok, normalized} <- normalize_brief(brief),
         :ok <- File.mkdir_p(normalized.local_output_dir) do
      runner_brief = build_runner_brief(normalized)
      benchmark_path = Path.join(normalized.local_output_dir, "benchmark.brief.json")

      :ok = write_benchmark_brief(benchmark_path, normalized, runner_brief, nil)

      case ComfyUISceneRunner.produce(runner_brief) do
        {:ok, %{run_id: run_id, local_output_dir: local_output_dir}} ->
          :ok = write_benchmark_brief(benchmark_path, normalized, runner_brief, run_id)

          {:ok,
           %{
             run_id: run_id,
             local_output_dir: local_output_dir,
             benchmark_path: benchmark_path,
             shot_count: length(normalized.shots),
             reference_count: length(normalized.reference_pack)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_reference_pack(reference_pack)
       when is_list(reference_pack) and reference_pack != [] do
    normalized =
      Enum.with_index(reference_pack, 1)
      |> Enum.map(fn {entry, index} ->
        label = get_any(entry, "label", "reference_#{index}")
        path = get_any(entry, "path")

        cond do
          not is_binary(label) or label == "" ->
            {:error, "reference_pack entry #{index} is missing label"}

          not is_binary(path) or path == "" ->
            {:error, "reference_pack entry #{index} is missing path"}

          true ->
            {:ok, %{label: label, path: path}}
        end
      end)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        refs = Enum.map(normalized, fn {:ok, ref} -> ref end)

        if Enum.uniq_by(refs, & &1.label) == refs do
          {:ok, refs}
        else
          {:error, "reference_pack labels must be unique"}
        end
    end
  end

  defp normalize_reference_pack(_other),
    do: {:error, "brief must include a non-empty reference_pack"}

  defp normalize_reference_slots([], _reference_pack), do: {:ok, []}

  defp normalize_reference_slots(reference_slots, reference_pack) when is_list(reference_slots) do
    labels = MapSet.new(Enum.map(reference_pack, & &1.label))

    normalized =
      Enum.with_index(reference_slots, 1)
      |> Enum.map(fn {slot, index} ->
        label = get_any(slot, "label")
        node_id = get_any(slot, "node_id")
        input = get_any(slot, "input", "image")

        cond do
          not is_binary(label) or label == "" ->
            {:error, "reference_slots entry #{index} is missing label"}

          not MapSet.member?(labels, label) ->
            {:error, "reference_slots entry #{index} references unknown label #{label}"}

          not is_binary(node_id) or node_id == "" ->
            {:error, "reference_slots entry #{index} is missing node_id"}

          not is_binary(input) or input == "" ->
            {:error, "reference_slots entry #{index} is missing input"}

          true ->
            {:ok, %{label: label, node_id: node_id, input: input}}
        end
      end)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(normalized, fn {:ok, slot} -> slot end)}
    end
  end

  defp normalize_reference_slots(_other, _reference_pack),
    do: {:error, "reference_slots must be a list"}

  defp validate_reference_slot_coverage(reference_pack, reference_slots) do
    if length(reference_pack) <= 1 do
      :ok
    else
      cond do
        reference_slots == [] ->
          {:error, "multi-reference briefs must include reference_slots"}

        true ->
          used_labels = MapSet.new(Enum.map(reference_slots, & &1.label))

          unused_labels =
            reference_pack
            |> Enum.map(& &1.label)
            |> Enum.reject(&MapSet.member?(used_labels, &1))

          duplicate_targets =
            reference_slots
            |> Enum.group_by(fn slot -> {slot.node_id, slot.input} end)
            |> Enum.filter(fn {_target, slots} -> length(slots) > 1 end)
            |> Enum.map(fn {{node_id, input}, _slots} -> "#{node_id}:#{input}" end)

          cond do
            unused_labels != [] ->
              {:error,
               "unused reference labels in reference_slots: #{Enum.join(unused_labels, ", ")}"}

            duplicate_targets != [] ->
              {:error, "duplicate reference slot targets: #{Enum.join(duplicate_targets, ", ")}"}

            true ->
              :ok
          end
      end
    end
  end

  defp validate_primary_reference_label(reference_pack, primary_reference_label) do
    if Enum.any?(reference_pack, &(&1.label == primary_reference_label)) do
      :ok
    else
      {:error, "unknown primary_reference_label #{primary_reference_label}"}
    end
  end

  defp normalize_shots(shots) when is_list(shots) and shots != [] do
    normalized =
      Enum.with_index(shots, 1)
      |> Enum.map(fn {shot, index} ->
        raw = normalize_map(shot)
        name = get_any(raw, "name", "Shot #{index}")
        slug = get_any(raw, "slug", slugify(name))

        cond do
          not is_binary(name) or name == "" ->
            {:error, "shot #{index} is missing name"}

          not is_binary(slug) or slug == "" ->
            {:error, "shot #{index} is missing slug"}

          true ->
            {:ok,
             %{
               name: name,
               slug: slug,
               prompt_suffix: get_any(raw, "prompt_suffix"),
               raw: raw
             }}
        end
      end)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        shot_list = Enum.map(normalized, fn {:ok, shot} -> shot end)

        if Enum.uniq_by(shot_list, & &1.slug) == shot_list do
          {:ok, shot_list}
        else
          {:error, "shot slugs must be unique"}
        end
    end
  end

  defp normalize_shots(_other), do: {:error, "brief must include a non-empty shots list"}

  defp build_positive_prompt(normalized, shot) do
    cond do
      prompt = get_any(shot.raw, "positive_prompt") ->
        prompt

      prompt = get_any(normalized.scene_defaults, "positive_prompt") ->
        prompt

      true ->
        prefix = get_any(normalized.scene_defaults, "positive_prompt_prefix", normalized.title)

        case shot.prompt_suffix do
          nil -> prefix
          suffix -> "#{prefix}, #{suffix}"
        end
    end
  end

  defp reference_slot_overrides([], _reference_pack), do: %{}

  defp reference_slot_overrides(reference_slots, reference_pack) do
    by_label = Map.new(reference_pack, &{&1.label, &1.path})

    Enum.reduce(reference_slots, %{}, fn slot, acc ->
      Map.update(acc, slot.node_id, %{slot.input => by_label[slot.label]}, fn existing ->
        Map.put(existing, slot.input, by_label[slot.label])
      end)
    end)
  end

  defp forward_scene_keys(map) when is_map(map) do
    Enum.reduce(@runner_forward_keys, %{}, fn key, acc ->
      case get_any(map, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp merge_node_overrides(overrides) do
    Enum.reduce(overrides, %{}, fn override_map, acc ->
      Map.merge(acc, normalize_nested_map(override_map), fn _node_id, left_inputs, right_inputs ->
        Map.merge(left_inputs, right_inputs)
      end)
    end)
  end

  defp normalize_nested_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_value =
        if is_map(value) do
          Enum.into(value, %{}, fn {inner_key, inner_value} ->
            {to_string(inner_key), inner_value}
          end)
        else
          value
        end

      Map.put(acc, to_string(key), normalized_value)
    end)
  end

  defp normalize_nested_map(_other), do: %{}

  defp output_node_override(nil, _input_key, _output_prefix), do: %{}

  defp output_node_override(node_id, input_key, output_prefix) do
    %{to_string(node_id) => %{to_string(input_key) => output_prefix}}
  end

  defp prompt_node_override(nil, _input_key, _value), do: %{}
  defp prompt_node_override(_node_id, _input_key, nil), do: %{}

  defp prompt_node_override(node_id, input_key, value) do
    %{to_string(node_id) => %{to_string(input_key) => value}}
  end

  defp write_benchmark_brief(path, normalized, runner_brief, run_id) do
    payload = %{
      "type" => "character_benchmark",
      "title" => normalized.title,
      "workflow_path" => normalized.workflow_path,
      "local_output_dir" => normalized.local_output_dir,
      "primary_reference_label" => normalized.primary_reference_label,
      "reference_image" => normalized.reference_image,
      "output_extension" => normalized.output_extension,
      "output_node_id" => normalized.output_node_id,
      "output_input_key" => normalized.output_input_key,
      "positive_prompt_node_id" => normalized.positive_prompt_node_id,
      "positive_prompt_input_key" => normalized.positive_prompt_input_key,
      "negative_prompt_node_id" => normalized.negative_prompt_node_id,
      "negative_prompt_input_key" => normalized.negative_prompt_input_key,
      "reference_pack" =>
        Enum.map(normalized.reference_pack, &%{"label" => &1.label, "path" => &1.path}),
      "reference_slots" =>
        Enum.map(normalized.reference_slots, fn slot ->
          %{"label" => slot.label, "node_id" => slot.node_id, "input" => slot.input}
        end),
      "shots" =>
        Enum.map(normalized.shots, fn shot ->
          %{
            "name" => shot.name,
            "slug" => shot.slug,
            "prompt_suffix" => shot.prompt_suffix,
            "raw" => shot.raw
          }
        end),
      "scene_defaults" => normalized.scene_defaults,
      "evaluation" => normalized.evaluation,
      "runner_brief" => runner_brief,
      "run_id" => run_id
    }

    File.write(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp require_string(map, key) do
    case get_any(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "brief must include #{key}"}
    end
  end

  defp build_local_output_dir(brief) do
    case get_any(brief, "local_output_dir") do
      nil -> Path.join(Path.expand("~/Downloads/vaos-character-benchmark"), timestamp_id())
      path -> Path.expand(path)
    end
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_other), do: %{}

  defp resolve_reference_image(explicit_image, _reference_pack, _primary_reference_label)
       when is_binary(explicit_image) and explicit_image != "" do
    explicit_image
  end

  defp resolve_reference_image(_explicit_image, [reference], primary_reference_label)
       when reference.label == primary_reference_label do
    reference.path
  end

  defp resolve_reference_image(_explicit_image, _reference_pack, _primary_reference_label),
    do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

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
    |> to_string()
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

  defp normalize_output_extension(value) when is_binary(value) and value != "" do
    if String.starts_with?(value, "."), do: value, else: ".#{value}"
  end

  defp normalize_output_extension(_other), do: ".png"
end
