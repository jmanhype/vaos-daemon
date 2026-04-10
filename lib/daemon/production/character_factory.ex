defmodule Daemon.Production.CharacterFactory do
  @moduledoc """
  Builds a reusable multi-character production program for:

  * Qwen anchor generation
  * Flux Klein edit reference-pack expansion
  * Wan LoRA training
  * 16-second talking-video planning

  The module writes artifact-first JSON plans so a whole roster can be prepared
  once and then executed character-by-character without rebuilding the shape of
  the pipeline each time.
  """

  @reference_slots [
    %{"label" => "anchor", "node_id" => "80", "input" => "image"},
    %{"label" => "front", "node_id" => "100", "input" => "image"},
    %{"label" => "left", "node_id" => "110", "input" => "image"},
    %{"label" => "right", "node_id" => "120", "input" => "image"},
    %{"label" => "up", "node_id" => "130", "input" => "image"},
    %{"label" => "down", "node_id" => "140", "input" => "image"}
  ]

  @benchmark_shots [
    %{
      "name" => "Front",
      "slug" => "front",
      "prompt_suffix" => "front-facing portrait, direct to camera, calm neutral expression"
    },
    %{
      "name" => "ThreeQuarter Left",
      "slug" => "three_quarter_left",
      "prompt_suffix" =>
        "strong three-quarter left portrait, head turned about 35 degrees to camera left, still recognizable as the same character, not profile"
    },
    %{
      "name" => "ThreeQuarter Right",
      "slug" => "three_quarter_right",
      "prompt_suffix" =>
        "strong three-quarter right portrait, head turned about 35 degrees to camera right, still recognizable as the same character, not profile"
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

  @dataset_angles [
    {"front", "front-facing portrait, direct to camera"},
    {"three_quarter_left",
     "strong three-quarter left portrait, head turned about 35 degrees to camera left"},
    {"three_quarter_right",
     "strong three-quarter right portrait, head turned about 35 degrees to camera right"},
    {"up", "head mostly facing camera, slight upward gaze, chin gently raised"},
    {"down", "head mostly facing camera, slight downward gaze, chin gently lowered, eyes open"}
  ]

  @dataset_expressions [
    {"neutral", "calm neutral expression"},
    {"soft_smile", "soft natural smile"},
    {"serious", "serious attentive expression"},
    {"emphatic", "emphatic speaking expression, mouth clearly shaped for speech"}
  ]

  @dataset_framings [
    {"close", "tight portrait close-up"},
    {"medium", "medium close-up portrait including shoulders"}
  ]

  @default_negative_prompt "blurry, low quality, distorted face, duplicate features, closed eyes, text, watermark"

  @default_characters [
    %{
      "slug" => "elder_man",
      "name" => "Elder Man",
      "kind" => "human",
      "gender" => "male",
      "environment" => "warm wooden cabin beside a window",
      "anchor_prompt" =>
        "Portrait photo of an elderly Native Alaskan man with a weathered face, kind eyes, silver hair, and a patterned grey sweater, seated inside a warm wooden cabin beside a window, photorealistic, natural warm light, shallow depth of field, direct eye contact, no text",
      "positive_prompt_prefix" =>
        "Same exact elderly Native Alaskan man as the reference pack, seated indoors in a warm wooden cabin beside a window, natural warm cabin light, photorealistic, preserve facial identity, same silver hair, same weathered face, same kind eyes, same patterned grey sweater, realistic skin detail, high fidelity portrait",
      "voice_style" => "elderly grounded storyteller, calm and credible",
      "speech_text_16s" =>
        "Our grandparents taught us that health changes slowly at first, and if you listen early enough, you can change the path before the real damage settles in.",
      "ip_note" => "original human character"
    },
    %{
      "slug" => "harbor_woman",
      "name" => "Harbor Woman",
      "kind" => "human",
      "gender" => "female",
      "environment" => "coastal clinic office with soft morning light",
      "anchor_prompt" =>
        "Portrait photo of a confident adult woman with dark curly hair, intelligent eyes, and a navy sweater, seated in a bright coastal clinic office with soft morning light, photorealistic, shallow depth of field, direct eye contact, no text",
      "positive_prompt_prefix" =>
        "Same exact adult woman as the reference pack, seated inside a bright coastal clinic office, soft morning window light, photorealistic, preserve facial identity, same dark curly hair, same intelligent eyes, same navy sweater, realistic skin detail, high fidelity portrait",
      "voice_style" => "confident female explainer, warm and steady",
      "speech_text_16s" =>
        "People think stress stays in the mind, but you can see it in sleep, focus, appetite, and posture long before any chart or lab report catches up.",
      "ip_note" => "original human character"
    },
    %{
      "slug" => "yellow_sponge_cook",
      "name" => "Yellow Sponge Cook",
      "kind" => "cartoon",
      "gender" => "male-coded",
      "environment" => "cheerful undersea diner kitchen",
      "anchor_prompt" =>
        "Bright cartoon character portrait of a cheerful yellow sea sponge fry cook with a square body, big blue eyes, a gap-toothed smile, white shirt, red tie, and brown shorts, standing inside a cheerful undersea diner kitchen, clean polished animation style, no text",
      "positive_prompt_prefix" =>
        "Same exact cheerful yellow sea sponge fry cook as the reference pack, inside a cheerful undersea diner kitchen, preserve facial identity, same square sponge body, same blue eyes, same buck teeth, same white shirt, same red tie, same brown shorts, polished cartoon render, high fidelity character portrait",
      "voice_style" => "hyper cheerful cartoon fry cook, elastic and bright",
      "speech_text_16s" =>
        "Every morning I fire up the grill, hum a little tune, and get to work, because the happiest kitchen in the ocean runs on rhythm, patience, and perfect timing.",
      "ip_note" => "inspired-by cartoon sponge archetype, avoid logos and exact branded text"
    },
    %{
      "slug" => "masked_space_lord",
      "name" => "Masked Space Lord",
      "kind" => "stylized_humanoid",
      "gender" => "male-coded",
      "environment" => "dark starship command chamber with red accent lights",
      "anchor_prompt" =>
        "Cinematic portrait of a towering black-armored space warlord with a glossy black helmet, chest panel lights, a long black cape, and an imposing posture, standing inside a dark starship command chamber with red accent lights, dramatic sci-fi realism, no text",
      "positive_prompt_prefix" =>
        "Same exact black-armored space warlord as the reference pack, standing inside a dark starship command chamber with red accent lights, preserve character identity, same glossy helmet, same chest lights, same black cape, same imposing silhouette, cinematic sci-fi portrait, high fidelity render",
      "voice_style" => "deep masked villain, deliberate and heavy",
      "speech_text_16s" =>
        "Power does not come from noise. It comes from patience, discipline, and the certainty that every room changes the instant you decide to enter it.",
      "ip_note" =>
        "inspired-by black-armored space villain archetype, avoid direct franchise insignia"
    },
    %{
      "slug" => "talking_golden_retriever",
      "name" => "Talking Golden Retriever",
      "kind" => "animal",
      "gender" => "male-coded",
      "environment" => "cozy family living room with warm afternoon light",
      "anchor_prompt" =>
        "Photoreal portrait of a friendly golden retriever sitting upright like a talking host in a cozy family living room with warm afternoon light, expressive eyes, detailed fur, gentle smile, cinematic depth of field, no text",
      "positive_prompt_prefix" =>
        "Same exact golden retriever as the reference pack, seated in a cozy family living room, warm afternoon light, preserve facial identity, same expressive eyes, same fur color, same muzzle shape, photoreal fur detail, high fidelity portrait",
      "voice_style" => "friendly talking dog, sincere and observant",
      "speech_text_16s" =>
        "I know three important things about this family: where the snacks live, who needs comfort, and exactly when the front door means adventure.",
      "ip_note" => "original talking animal character"
    },
    %{
      "slug" => "chrome_android_host",
      "name" => "Chrome Android Host",
      "kind" => "android",
      "gender" => "female-coded",
      "environment" => "futuristic chrome newsroom with blue edge lights",
      "anchor_prompt" =>
        "Portrait of a sleek chrome android host with expressive illuminated eyes, subtle synthetic facial seams, and elegant metallic features, seated in a futuristic chrome newsroom with cool blue edge lights, cinematic realism, no text",
      "positive_prompt_prefix" =>
        "Same exact chrome android host as the reference pack, seated in a futuristic chrome newsroom with cool blue edge lights, preserve facial identity, same illuminated eyes, same synthetic facial seams, same metallic finish, high fidelity sci-fi portrait",
      "voice_style" => "precise synthetic presenter, calm and articulate",
      "speech_text_16s" =>
        "I was built to translate chaos into clarity, and the fastest way to calm a room is to speak slowly, observe carefully, and make one good decision at a time.",
      "ip_note" => "original sci-fi character"
    }
  ]

  @spec default_characters() :: [map()]
  def default_characters, do: @default_characters

  @spec normalize_brief(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_brief(brief) when is_map(brief) do
    title = get_any(brief, "title", "Six Character LoRA Factory")
    base_output_dir = get_any(brief, "base_output_dir", default_output_dir())

    with {:ok, qwen_workflow_path} <- require_string(brief, "qwen_workflow_path"),
         {:ok, klein_workflow_path} <- require_string(brief, "klein_workflow_path"),
         {:ok, characters} <-
           normalize_characters(get_any(brief, "characters", @default_characters)) do
      {:ok,
       %{
         title: title,
         base_output_dir: Path.expand(base_output_dir),
         qwen_workflow_path: Path.expand(qwen_workflow_path),
         klein_workflow_path: Path.expand(klein_workflow_path),
         no_id_video_ui_path: optional_expand(get_any(brief, "no_id_video_ui_path")),
         no_id_video_api_path: optional_expand(get_any(brief, "no_id_video_api_path")),
         fallback_video_api_path: optional_expand(get_any(brief, "fallback_video_api_path")),
         characters: characters
       }}
    end
  end

  def normalize_brief(_other), do: {:error, "brief must be a map"}

  @spec produce(map()) ::
          {:ok,
           %{
             program_path: String.t(),
             base_output_dir: String.t(),
             character_count: non_neg_integer()
           }}
          | {:error, term()}
  def produce(brief) when is_map(brief) do
    with {:ok, normalized} <- normalize_brief(brief),
         :ok <- File.mkdir_p(normalized.base_output_dir) do
      characters =
        Enum.map(normalized.characters, fn character ->
          build_character(normalized, character)
        end)

      program =
        %{
          "type" => "character_factory_program",
          "title" => normalized.title,
          "qwen_workflow_path" => normalized.qwen_workflow_path,
          "klein_workflow_path" => normalized.klein_workflow_path,
          "no_id_video_ui_path" => normalized.no_id_video_ui_path,
          "no_id_video_api_path" => normalized.no_id_video_api_path,
          "fallback_video_api_path" => normalized.fallback_video_api_path,
          "characters" => characters
        }

      program_path = Path.join(normalized.base_output_dir, "program.json")
      :ok = write_json(program_path, program)

      {:ok,
       %{
         program_path: program_path,
         base_output_dir: normalized.base_output_dir,
         character_count: length(characters)
       }}
    end
  end

  defp normalize_characters(characters) when is_list(characters) and characters != [] do
    normalized =
      Enum.with_index(characters, 1)
      |> Enum.map(fn {character, index} ->
        slug = get_any(character, "slug", "character_#{index}")
        name = get_any(character, "name", "Character #{index}")

        cond do
          not is_binary(slug) or slug == "" ->
            {:error, "character #{index} is missing slug"}

          not is_binary(name) or name == "" ->
            {:error, "character #{index} is missing name"}

          true ->
            {:ok,
             %{
               slug: slugify(slug),
               name: name,
               kind: get_any(character, "kind", "character"),
               gender: get_any(character, "gender", "unspecified"),
               environment: get_any(character, "environment", "studio portrait setting"),
               anchor_prompt: get_any(character, "anchor_prompt"),
               positive_prompt_prefix: get_any(character, "positive_prompt_prefix"),
               voice_style: get_any(character, "voice_style", "clear neutral narrator"),
               speech_text_16s: get_any(character, "speech_text_16s"),
               ip_note: get_any(character, "ip_note", "original character")
             }}
        end
      end)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        chars = Enum.map(normalized, fn {:ok, char} -> char end)

        if Enum.uniq_by(chars, & &1.slug) == chars do
          {:ok, chars}
        else
          {:error, "character slugs must be unique"}
        end
    end
  end

  defp normalize_characters(_other),
    do: {:error, "brief must include a non-empty characters list"}

  defp build_character(program, character) do
    character_dir = Path.join(program.base_output_dir, character.slug)
    refs_dir = Path.join(character_dir, "refs")
    dataset_dir = Path.join(character_dir, "dataset")
    dataset_images_dir = Path.join(dataset_dir, "images")
    output_dir = Path.join(character_dir, "output")

    :ok = File.mkdir_p!(refs_dir)
    :ok = File.mkdir_p!(dataset_images_dir)
    :ok = File.mkdir_p!(output_dir)

    anchor_output_path = Path.join(refs_dir, "#{character.slug}_anchor_qwen.png")
    benchmark_output_dir = Path.join(character_dir, "benchmark_run")
    refpack_plan_path = Path.join(character_dir, "klein_refpack.plan.json")
    benchmark_path = Path.join(character_dir, "benchmark.brief.json")
    qwen_anchor_path = Path.join(character_dir, "qwen_anchor.plan.json")
    lora_path = Path.join(character_dir, "lora_training.plan.json")
    video_path = Path.join(character_dir, "video_16s.plan.json")
    character_path = Path.join(character_dir, "character.json")

    reference_pack = reference_pack_paths(refs_dir, character.slug)

    benchmark_brief = %{
      "title" => "#{character.name} Character Benchmark",
      "workflow_path" => program.klein_workflow_path,
      "local_output_dir" => benchmark_output_dir,
      "output_extension" => ".png",
      "output_node_id" => "98",
      "output_input_key" => "filename_prefix",
      "positive_prompt_node_id" => "86",
      "positive_prompt_input_key" => "text",
      "negative_prompt_node_id" => "87",
      "negative_prompt_input_key" => "text",
      "output_prefix_base" => "#{character.slug}_flux_multi_ref_benchmark",
      "primary_reference_label" => "anchor",
      "reference_pack" => reference_pack,
      "reference_slots" => @reference_slots,
      "scene_defaults" => %{
        "steps" => 24,
        "seed_a" => 811,
        "negative_prompt" => @default_negative_prompt,
        "positive_prompt_prefix" => character.positive_prompt_prefix
      },
      "shots" => @benchmark_shots
    }

    qwen_anchor_plan = %{
      "type" => "qwen_anchor_plan",
      "name" => character.name,
      "workflow_path" => program.qwen_workflow_path,
      "output_path" => anchor_output_path,
      "output_prefix" => "#{character.slug}_anchor_qwen",
      "positive_prompt" => character.anchor_prompt,
      "negative_prompt" => "text, watermark, logo, blurry, duplicate face, extra limbs",
      "note" =>
        "Generate a single clean canonical anchor first. This becomes the identity root for the Klein edit/refpack stage."
    }

    refpack_plan = %{
      "type" => "klein_refpack_plan",
      "name" => character.name,
      "workflow_path" => program.klein_workflow_path,
      "reference_strategy" =>
        "Use the Qwen anchor first, then promote front/left/right/up/down hero stills into refs/ before running the benchmark.",
      "reference_files" => reference_pack,
      "hero_targets" => hero_targets(character.slug, refs_dir),
      "dataset_targets" => dataset_targets(character, dataset_images_dir)
    }

    lora_training_plan = %{
      "type" => "wan_lora_training_plan",
      "name" => character.name,
      "dataset_directory" => dataset_dir,
      "image_directory" => dataset_images_dir,
      "cache_directory" => Path.join(character_dir, "cache"),
      "output_directory" => output_dir,
      "trigger_token" => character.slug,
      "voice_style" => character.voice_style,
      "training_recipe" => %{
        "family" => "Wan 2.2 I2V low-noise image-LoRA",
        "dataset_resolution" => [512, 512],
        "batch_size" => 1,
        "mixed_precision" => "fp16",
        "fp8_base" => true,
        "blocks_to_swap" => 20,
        "gradient_checkpointing" => true,
        "optimizer_type" => "adamw8bit",
        "learning_rate" => 1.0e-5,
        "network_module" => "networks.lora_wan",
        "network_dim" => 16,
        "network_alpha" => 16,
        "timestep_sampling" => "shift",
        "discrete_flow_shift" => 5.0,
        "max_train_epochs_from_scratch" => 16,
        "max_train_epochs_refine" => 8,
        "save_every_n_epochs" => 2,
        "seed" => 42
      },
      "dataset_targets" => %{
        "minimum_promoted_refs" => 6,
        "minimum_dataset_images" => 40,
        "preferred_total_images" => 46
      },
      "notes" => [
        "Cold-start LoRA training should begin after the hero refpack and 40-image dataset are generated.",
        "If a first LoRA already exists, use the 8-epoch refine recipe against the promoted winners."
      ]
    }

    video_plan = %{
      "type" => "video_16s_plan",
      "name" => character.name,
      "speech_text" => character.speech_text_16s,
      "voice_style" => character.voice_style,
      "duration_seconds" => 16,
      "frames" => 385,
      "fps" => 24,
      "still_image_path" => anchor_output_path,
      "audio_path" => Path.join([character_dir, "audio", "#{character.slug}_16s.wav"]),
      "no_id_video_ui_path" => program.no_id_video_ui_path,
      "no_id_video_api_path" => program.no_id_video_api_path,
      "fallback_video_api_path" => program.fallback_video_api_path,
      "notes" => [
        "Preferred target is the no-id LTX workflow once it exists in API-format JSON.",
        "Until that export exists, use the fallback API workflow only for dry-run validation, not as the final locked pipeline."
      ]
    }

    character_doc = %{
      "name" => character.name,
      "slug" => character.slug,
      "kind" => character.kind,
      "gender" => character.gender,
      "environment" => character.environment,
      "voice_style" => character.voice_style,
      "ip_note" => character.ip_note,
      "artifact_paths" => %{
        "anchor_plan" => qwen_anchor_path,
        "refpack_plan" => refpack_plan_path,
        "benchmark_brief" => benchmark_path,
        "lora_training_plan" => lora_path,
        "video_plan" => video_path
      }
    }

    :ok = write_json(character_path, character_doc)
    :ok = write_json(qwen_anchor_path, qwen_anchor_plan)
    :ok = write_json(refpack_plan_path, refpack_plan)
    :ok = write_json(benchmark_path, benchmark_brief)
    :ok = write_json(lora_path, lora_training_plan)
    :ok = write_json(video_path, video_plan)

    %{
      "name" => character.name,
      "slug" => character.slug,
      "character_path" => character_path,
      "artifact_paths" => %{
        "anchor_plan" => qwen_anchor_path,
        "refpack_plan" => refpack_plan_path,
        "benchmark_brief" => benchmark_path,
        "lora_training_plan" => lora_path,
        "video_plan" => video_path
      }
    }
  end

  defp reference_pack_paths(refs_dir, slug) do
    [
      %{"label" => "anchor", "path" => Path.join(refs_dir, "#{slug}_anchor_qwen.png")},
      %{"label" => "front", "path" => Path.join(refs_dir, "#{slug}_front_klein.png")},
      %{"label" => "left", "path" => Path.join(refs_dir, "#{slug}_three_quarter_left_klein.png")},
      %{
        "label" => "right",
        "path" => Path.join(refs_dir, "#{slug}_three_quarter_right_klein.png")
      },
      %{"label" => "up", "path" => Path.join(refs_dir, "#{slug}_up_klein.png")},
      %{"label" => "down", "path" => Path.join(refs_dir, "#{slug}_down_klein.png")}
    ]
  end

  defp hero_targets(slug, refs_dir) do
    Enum.map(@benchmark_shots, fn shot ->
      %{
        "slug" => shot["slug"],
        "output_path" => Path.join(refs_dir, "#{slug}_#{shot["slug"]}_klein.png"),
        "prompt_suffix" => shot["prompt_suffix"]
      }
    end)
  end

  defp dataset_targets(character, dataset_images_dir) do
    for {angle_slug, angle_prompt} <- @dataset_angles,
        {expression_slug, expression_prompt} <- @dataset_expressions,
        {framing_slug, framing_prompt} <- @dataset_framings do
      %{
        "slug" => "#{angle_slug}_#{expression_slug}_#{framing_slug}",
        "output_path" =>
          Path.join(
            dataset_images_dir,
            "#{character.slug}_#{angle_slug}_#{expression_slug}_#{framing_slug}.png"
          ),
        "caption_path" =>
          Path.join(
            dataset_images_dir,
            "#{character.slug}_#{angle_slug}_#{expression_slug}_#{framing_slug}.txt"
          ),
        "positive_prompt" =>
          Enum.join(
            [
              character.positive_prompt_prefix,
              angle_prompt,
              expression_prompt,
              framing_prompt
            ],
            ", "
          ),
        "seed" => shot_seed(angle_slug, expression_slug, framing_slug)
      }
    end
  end

  defp shot_seed(angle_slug, expression_slug, framing_slug) do
    :erlang.phash2({angle_slug, expression_slug, framing_slug}, 9_999_999)
  end

  defp write_json(path, payload) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
    :ok
  end

  defp default_output_dir do
    Path.expand("~/Downloads/character-factory-v1")
  end

  defp optional_expand(nil), do: nil
  defp optional_expand(value) when is_binary(value), do: Path.expand(value)
  defp optional_expand(_other), do: nil

  defp require_string(map, key) do
    case get_any(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "brief is missing #{key}"}
    end
  end

  defp get_any(map, key, default \\ nil) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      is_binary(key) and Map.has_key?(map, String.to_atom(key)) ->
        Map.get(map, String.to_atom(key))

      true ->
        default
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end
end
