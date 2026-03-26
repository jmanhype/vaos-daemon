defmodule Daemon.Investigation.PromptSelector do
  @moduledoc """
  Thompson Sampling prompt variant selector.

  Maintains a registry of prompt variants (default, GEPA-optimized, manual)
  each with a Beta(alpha, beta) posterior updated after every investigation.
  Selects between variants using Thompson Sampling — bad variants get
  deprioritized without human intervention.

  Storage: ~/.daemon/prompt_variants/registry.json
  Follows the StrategyStore pattern for JSON persistence.
  """

  require Logger

  alias Daemon.Investigation.PromptConfig

  @registry_dir Path.join(System.user_home!(), ".daemon/prompt_variants")
  @registry_file "registry.json"

  # --- Public API ---

  @doc "Thompson sample across variants, return {prompts, variant_id}."
  @spec select() :: {map(), String.t()}
  def select do
    registry = load_registry()
    registry = ensure_default_variant(registry)

    variants = registry["variants"] || %{}

    if map_size(variants) == 0 do
      {PromptConfig.hardcoded_defaults(), "default"}
    else
      # Thompson sample: draw from Beta(alpha, beta) for each variant
      {best_id, _best_sample} =
        variants
        |> Enum.map(fn {id, v} ->
          alpha = v["alpha"] || 1
          beta = v["beta"] || 1
          {id, sample_beta(alpha, beta)}
        end)
        |> Enum.max_by(fn {_id, sample} -> sample end)

      # Load prompts for the selected variant
      variant = variants[best_id]
      prompts = load_variant_prompts(variant)

      # Update last_selected_at
      updated_variant = Map.put(variant, "last_selected_at", DateTime.utc_now() |> DateTime.to_iso8601())
      updated_registry = put_in(registry, ["variants", best_id], updated_variant)
      save_registry(updated_registry)

      {prompts, best_id}
    end
  end

  @doc "Update variant's Beta posterior after an investigation."
  @spec update(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def update(variant_id, verified_count, unverified_count)
      when is_binary(variant_id) and is_integer(verified_count) and is_integer(unverified_count) do
    registry = load_registry()
    variants = registry["variants"] || %{}

    case Map.get(variants, variant_id) do
      nil ->
        Logger.debug("[prompt_selector] Unknown variant #{variant_id}, skipping update")
        :ok

      variant ->
        updated = variant
          |> Map.update("alpha", 1, &(&1 + verified_count))
          |> Map.update("beta", 1, &(&1 + unverified_count))
          |> Map.update("total_trials", 0, &(&1 + verified_count + unverified_count))

        updated_registry = put_in(registry, ["variants", variant_id], updated)
        save_registry(updated_registry)
        Logger.debug("[prompt_selector] Updated #{variant_id}: alpha=#{updated["alpha"]}, beta=#{updated["beta"]}")
        :ok
    end
  end

  @doc "Register a new prompt variant. Preserves existing posterior if same prompt_hash."
  @spec register(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register(prompts, opts \\ []) when is_map(prompts) do
    case PromptConfig.validate_prompts(prompts) do
      :ok ->
        source = Keyword.get(opts, :source, "manual")
        file_path = Keyword.get(opts, :file_path)

        hash = PromptConfig.prompt_hash(prompts)
        registry = load_registry()
        variants = registry["variants"] || %{}

        # Check if a variant with this hash already exists
        existing = Enum.find(variants, fn {_id, v} -> v["prompt_hash"] == hash end)

        case existing do
          {existing_id, _} ->
            Logger.debug("[prompt_selector] Variant with hash #{hash} already exists as #{existing_id}")
            {:ok, existing_id}

          nil ->
            variant_id = "#{source}_#{Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")}_#{String.slice(hash, 0, 6)}"

            variant = %{
              "variant_id" => variant_id,
              "source" => source,
              "file_path" => file_path,
              "prompt_hash" => hash,
              "alpha" => 1,
              "beta" => 1,
              "total_trials" => 0,
              "registered_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "last_selected_at" => nil
            }

            updated_registry = put_in(registry, ["variants", variant_id], variant)
            save_registry(updated_registry)
            Logger.info("[prompt_selector] Registered new variant #{variant_id} (source: #{source})")
            {:ok, variant_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List all variants with posterior stats."
  @spec list_variants() :: [map()]
  def list_variants do
    registry = load_registry()
    variants = registry["variants"] || %{}
    Map.values(variants)
  end

  @doc "Return the registry directory path (for testing)."
  @spec registry_dir() :: String.t()
  def registry_dir, do: @registry_dir

  # --- Beta Distribution Sampling (Marsaglia-Tsang) ---

  @doc false
  def sample_beta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0 do
    x = sample_gamma(a / 1)
    y = sample_gamma(b / 1)

    if x + y == 0.0 do
      # Degenerate case — return 0.5
      0.5
    else
      x / (x + y)
    end
  end

  # Gamma sampling: Marsaglia-Tsang for a >= 1, Ahrens-Dieter boost for a < 1
  defp sample_gamma(a) when a < 1.0 do
    # Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
    sample_gamma(a + 1.0) * :math.pow(:rand.uniform(), 1.0 / a)
  end

  defp sample_gamma(a) do
    # Marsaglia-Tsang squeeze method for a >= 1
    d = a - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)

    do_marsaglia_tsang(d, c)
  end

  defp do_marsaglia_tsang(d, c) do
    # Box-Muller for standard normal
    x = box_muller_normal()
    v = 1.0 + c * x

    if v <= 0.0 do
      do_marsaglia_tsang(d, c)
    else
      v = v * v * v
      u = :rand.uniform()
      x_sq = x * x

      if u < 1.0 - 0.0331 * x_sq * x_sq do
        d * v
      else
        if :math.log(u) < 0.5 * x_sq + d * (1.0 - v + :math.log(v)) do
          d * v
        else
          do_marsaglia_tsang(d, c)
        end
      end
    end
  end

  defp box_muller_normal do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end

  # --- Registry Persistence ---

  defp registry_path, do: Path.join(@registry_dir, @registry_file)

  defp load_registry do
    case File.read(registry_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"version" => _, "variants" => _} = registry} -> registry
          _ ->
            Logger.warning("[prompt_selector] Corrupted registry, starting fresh")
            empty_registry()
        end

      {:error, _} ->
        empty_registry()
    end
  end

  defp save_registry(registry) do
    File.mkdir_p!(@registry_dir)
    File.write!(registry_path(), Jason.encode!(registry, pretty: true))
  end

  defp empty_registry do
    %{"version" => 1, "variants" => %{}}
  end

  defp ensure_default_variant(%{"variants" => variants} = registry) do
    if Map.has_key?(variants, "default") do
      registry
    else
      defaults = PromptConfig.hardcoded_defaults()
      hash = PromptConfig.prompt_hash(defaults)

      default_variant = %{
        "variant_id" => "default",
        "source" => "hardcoded",
        "file_path" => nil,
        "prompt_hash" => hash,
        "alpha" => 1,
        "beta" => 1,
        "total_trials" => 0,
        "registered_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "last_selected_at" => nil
      }

      put_in(registry, ["variants", "default"], default_variant)
    end
  end

  defp load_variant_prompts(%{"variant_id" => "default"}), do: PromptConfig.hardcoded_defaults()

  defp load_variant_prompts(%{"file_path" => path}) when is_binary(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"prompts" => prompts}} when is_map(prompts) -> prompts
          {:ok, prompts} when is_map(prompts) -> prompts
          _ ->
            Logger.warning("[prompt_selector] Failed to decode #{path}, falling back to defaults")
            PromptConfig.hardcoded_defaults()
        end

      {:error, _} ->
        Logger.warning("[prompt_selector] Cannot read #{path}, falling back to defaults")
        PromptConfig.hardcoded_defaults()
    end
  end

  defp load_variant_prompts(_), do: PromptConfig.hardcoded_defaults()
end
