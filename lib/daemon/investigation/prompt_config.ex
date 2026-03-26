defmodule Daemon.Investigation.PromptConfig do
  @moduledoc """
  Load and render investigation prompt templates from JSON config.

  Fallback chain: ~/.daemon/prompts/investigation_optimized.json
               -> priv/prompts/investigation_default.json
               -> hardcoded defaults

  Uses ~key~ interpolation (NOT {{key}}) to avoid collision with paper
  abstracts that may contain curly braces.
  """

  require Logger

  @user_dir Path.join(System.user_home!(), ".daemon/prompts")
  @default_filename "investigation_default.json"

  @doc "Load prompt templates. Tries optimized → default → hardcoded."
  @spec load() :: map()
  def load do
    with :error <- load_json(Path.join(@user_dir, "investigation_optimized.json")),
         :error <- load_json(priv_path(@default_filename)) do
      hardcoded_defaults()
    else
      {:ok, prompts} -> prompts
    end
  end

  @doc "Render a prompt template by replacing ~key~ placeholders with bindings."
  @spec render(String.t(), keyword()) :: String.t()
  def render(template, bindings) when is_binary(template) do
    Enum.reduce(bindings, template, fn {key, val}, acc ->
      String.replace(acc, "~#{key}~", to_string(val))
    end)
  end

  @doc "Save GEPA-optimized prompts to user directory."
  @spec save_optimized(map()) :: :ok
  def save_optimized(prompts) when is_map(prompts) do
    File.mkdir_p!(@user_dir)
    path = Path.join(@user_dir, "investigation_optimized.json")

    data = %{
      "version" => 1,
      "optimized_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "optimizer" => "gepa",
      "prompts" => prompts
    }

    File.write!(path, Jason.encode!(data, pretty: true))
    Logger.info("[prompt_config] Saved optimized prompts to #{path}")

    # Auto-register with PromptSelector for Thompson Sampling
    try do
      Daemon.Investigation.PromptSelector.register(prompts, source: "gepa", file_path: path)
    rescue
      _ -> :ok
    end

    :ok
  end

  @doc "Compute a short hash of the current prompt set (for feedback tracking). Deterministic across restarts."
  @spec prompt_hash(map()) :: String.t()
  def prompt_hash(prompts) when is_map(prompts) do
    sorted = prompts |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {k, v} -> [k, v] end) |> Jason.encode!()
    :crypto.hash(:sha256, sorted)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc "Return the user directory path (for testing)."
  @spec user_dir() :: String.t()
  def user_dir, do: @user_dir

  # -- Private --

  defp load_json(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"prompts" => prompts}} when is_map(prompts) ->
            case validate_prompts(prompts) do
              :ok ->
                Logger.debug("[prompt_config] Loaded prompts from #{path}")
                {:ok, prompts}
              {:error, reason} ->
                Logger.warning("[prompt_config] #{path} failed validation: #{reason}")
                :error
            end

          {:ok, %{"version" => _}} ->
            Logger.warning("[prompt_config] #{path} missing 'prompts' key")
            :error

          {:ok, prompts} when is_map(prompts) ->
            # Bare map without wrapper (legacy format)
            {:ok, prompts}

          _ ->
            Logger.warning("[prompt_config] Failed to decode #{path}")
            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp priv_path(filename) do
    case :code.priv_dir(:daemon) do
      {:error, _} ->
        # Fallback: try Application.app_dir, then relative path as last resort
        case Application.app_dir(:daemon, "priv") do
          path when is_binary(path) -> Path.join([path, "prompts", filename])
          _ -> Path.join([File.cwd!(), "priv", "prompts", filename])
        end

      priv ->
        Path.join([to_string(priv), "prompts", filename])
    end
  end

  @doc "Validate that a prompt map has all required keys as non-empty strings."
  @spec validate_prompts(map()) :: :ok | {:error, String.t()}
  def validate_prompts(prompts) when is_map(prompts) do
    required = ~w(for_system against_system advocate_user_template
                  example_format verify_prompt no_papers_fallback)

    missing = Enum.filter(required, fn key -> !Map.has_key?(prompts, key) end)

    cond do
      missing != [] ->
        {:error, "Missing required prompt keys: #{Enum.join(missing, ", ")}"}

      Enum.any?(required, fn key ->
        val = prompts[key]
        !is_binary(val) or String.trim(val) == ""
      end) ->
        empty = Enum.filter(required, fn key ->
          val = prompts[key]
          !is_binary(val) or String.trim(val) == ""
        end)
        {:error, "Empty or non-string prompt values: #{Enum.join(empty, ", ")}"}

      true ->
        :ok
    end
  end

  @doc "Return hardcoded default prompts. Used as fallback and by PromptSelector for the default variant."
  def hardcoded_defaults do
    %{
      "for_system" => "You are an intellectually honest researcher making the strongest case FOR a claim. Vary your strength ratings — not every argument is equally strong.",
      "against_system" => "You are an intellectually honest researcher making the strongest case AGAINST a claim. Vary your strength ratings — not every argument is equally strong.",
      "advocate_user_template" => """
      You are a researcher who genuinely believes the following claim is ~position~.
      Using the papers provided and your knowledge, make the STRONGEST possible case~direction~.

      Claim: ~claim~

      ~papers_context~
      ~prior_text~

      Present your 3-5 strongest ~arg_type~. For each argument:
      - Write a FULL paragraph (2-4 sentences minimum) explaining the evidence
      - Cite a specific paper as [Paper N] within your paragraph text
      - Rate the argument strength 1-10
      - Tag as [SOURCED] if backed by a paper, [REASONING] if from your analysis
      - Do NOT just write a title — write a substantive argument with evidence

      ~example_format~

      Now write your ~arg_type~:
      1. [SOURCED/REASONING] (strength: N) Your detailed ~arg_word~ here [Paper N if applicable]\
      """,
      "example_format" => """
      Example of correct format:
      1. [SOURCED] (strength: 8) [Paper 3] reports improved accuracy on mathematical reasoning benchmarks using MCTS-guided search compared to baseline sampling (as stated in the abstract). The paper demonstrates this across multiple task types.
      2. [REASONING] (strength: 5) The mechanism of action is biologically plausible because...

      Important: Only claim what the paper's abstract explicitly states. Do not fabricate statistics or findings not present in the abstract text.\
      """,
      "citation_instructions" => """

      Papers are sorted by relevance. Citation counts are shown for each paper.
      When citing papers, only claim what the abstract actually states. Do NOT infer findings beyond what is written.
      If a paper's abstract doesn't explicitly support your claim, use [REASONING] instead of citing it.
      You MUST cite specific papers by number [Paper N] when your arguments are based on them.\
      """,
      "verify_prompt" => """
      Paper title: ~paper_title~
      Paper abstract: ~paper_abstract~

      Claim: ~claim~

      Two questions:
      1. Does this paper's abstract support the specific claim? VERIFIED / PARTIAL / UNVERIFIED
      2. Paper type? REVIEW (systematic review/meta-analysis), TRIAL (RCT/experiment), STUDY (observational/single study), OTHER

      Answer format: WORD WORD (e.g., VERIFIED REVIEW or UNVERIFIED STUDY)\
      """,
      "no_papers_fallback" => "No relevant papers found. Base your arguments on your training knowledge, but mark everything as [REASONING]."
    }
  end
end
