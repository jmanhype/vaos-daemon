defmodule OptimalSystemAgent.Intelligence.CommCoach do
  @moduledoc """
  Observes outbound messages and scores communication quality.
  Compares drafts against profiles to suggest improvements.

  Scoring dimensions (each 0.0–1.0, averaged for final score):
  - Length appropriateness: matches expected length for signal mode / user profile
  - Formality alignment: matches the user's established formality level
  - Clarity: readable structure, no walls of text or excessively long sentences
  - Actionability: concrete next steps present when context demands action
  - Empathy alignment: acknowledges emotion in express-genre conversations

  Verdict thresholds:
  - >= 0.7  :good
  - >= 0.4  :needs_work
  - < 0.4   :poor

  Channel defaults (overrides neutral baseline when no profile exists):
  - :email   → formal, long
  - :slack   → casual, short
  - :cli     → technical, terse
  - :discord → casual, medium
  - :sms     → casual, short
  - :api     → technical, medium

  Signal Theory — outbound message quality optimization.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Intelligence.CommProfiler

  defstruct scores: [],
            total_scored: 0

  # Channel defaults: {formality_float, preferred_length_atom, technical_depth_atom}
  @channel_defaults %{
    email:   %{formality: 0.8, preferred_length: :long,   technical_depth: :moderate},
    slack:   %{formality: 0.2, preferred_length: :short,  technical_depth: :moderate},
    cli:     %{formality: 0.5, preferred_length: :short,  technical_depth: :expert},
    discord: %{formality: 0.2, preferred_length: :medium, technical_depth: :moderate},
    sms:     %{formality: 0.2, preferred_length: :short,  technical_depth: :simple},
    api:     %{formality: 0.5, preferred_length: :medium, technical_depth: :expert}
  }

  # Inbound clarity threshold — below this we ask the user to clarify
  @inbound_clarity_threshold 0.4

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  @doc """
  Score an outbound message against the user's profile and optional channel.

      CommCoach.score_response(message, user_id, channel)
      CommCoach.score_response(message, user_id)   # channel defaults to :unknown

  Returns `{:ok, result_map}`.
  """
  def score_response(message, user_id \\ nil, channel \\ :unknown) do
    GenServer.call(__MODULE__, {:score_response, message, user_id, channel})
  end

  @doc "Backward-compatible alias for score_response/3."
  def score(message, user_id \\ nil), do: score_response(message, user_id)

  @doc """
  Score an inbound user message for clarity.
  Returns `{:ok, result_map}` where result includes `:clarification_needed` and
  `:clarification_prompt` when the message scores below #{@inbound_clarity_threshold}.
  """
  def score_inbound(message, user_id \\ nil) do
    GenServer.call(__MODULE__, {:score_inbound, message, user_id})
  end

  @doc "Get coaching statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:score_response, message, user_id, channel}, _from, state) do
    profile = build_effective_profile(user_id, channel)

    scores = %{
      length:        score_length(message, profile),
      formality:     score_formality(message, profile),
      clarity:       score_clarity(message),
      actionability: score_actionability(message),
      empathy:       score_empathy(message)
    }

    avg = scores |> Map.values() |> Enum.sum() |> Kernel./(5) |> Float.round(4)

    verdict =
      cond do
        avg >= 0.7 -> :good
        avg >= 0.4 -> :needs_work
        true -> :poor
      end

    suggestions = generate_suggestions(scores, profile)

    result = %{
      score:       Float.round(avg, 2),
      suggestions: suggestions,
      verdict:     verdict,
      details:     scores,
      channel:     channel
    }

    Logger.debug("[CommCoach] outbound len=#{String.length(message)} avg=#{avg} verdict=#{verdict} channel=#{channel}")

    # Persist the score into the user's profile if we have a user_id
    if user_id, do: CommProfiler.update_profile(user_id, %{score: avg})

    new_state = %{state |
      total_scored: state.total_scored + 1,
      scores: [avg | Enum.take(state.scores, 99)]
    }

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:score_inbound, message, user_id}, _from, state) do
    clarity = score_clarity(message)
    len = String.length(message)

    # Very short messages with no punctuation are ambiguous
    ambiguity_penalty =
      if len < 15 and not Regex.match?(~r/[?!.]/, message), do: 0.2, else: 0.0

    adjusted_clarity = max(0.0, clarity - ambiguity_penalty)

    {clarification_needed, clarification_prompt} =
      if adjusted_clarity < @inbound_clarity_threshold do
        topic = extract_ambiguous_topic(message)
        prompt = "Could you clarify what you mean by #{topic}?"
        {true, prompt}
      else
        {false, nil}
      end

    result = %{
      score:                adjusted_clarity,
      clarification_needed: clarification_needed,
      clarification_prompt: clarification_prompt,
      user_id:              user_id
    }

    Logger.debug("[CommCoach] inbound len=#{len} clarity=#{adjusted_clarity} clarify=#{clarification_needed}")

    # Record the inbound message for profile learning
    if user_id, do: CommProfiler.record(user_id, message)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    avg_score =
      case state.scores do
        []     -> 0.0
        scores -> Float.round(Enum.sum(scores) / length(scores), 2)
      end

    result = %{
      total_scored: state.total_scored,
      avg_score:    avg_score,
      common_issues: common_issues(state.scores)
    }

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Profile resolution: merge user profile + channel defaults
  # ---------------------------------------------------------------------------

  # Build an effective profile by starting from channel defaults (if any),
  # then overlaying the user's learned preferences.
  defp build_effective_profile(user_id, channel) do
    channel_base = Map.get(@channel_defaults, channel, %{})

    user_profile =
      if user_id do
        case CommProfiler.get_profile(user_id) do
          {:ok, p} -> p
          _ -> %{}
        end
      else
        %{}
      end

    # Build a merged profile. User learned values take priority over channel defaults.
    base = %{
      avg_length:      Map.get(user_profile, :avg_length, 0),
      message_count:   Map.get(user_profile, :message_count, 0),
      formality:       formality_to_float(Map.get(user_profile, :formality, :neutral), channel_base),
      preferred_length: Map.get(user_profile, :preferred_length, Map.get(channel_base, :preferred_length, :medium)),
      technical_depth:  Map.get(user_profile, :technical_depth, Map.get(channel_base, :technical_depth, :moderate))
    }

    base
  end

  # If user has seen enough messages, use their learned formality; otherwise lean on channel.
  defp formality_to_float(user_formality_atom, channel_base) do
    channel_float = Map.get(channel_base, :formality, 0.5)

    case user_formality_atom do
      :casual  -> blend(0.2, channel_float)
      :formal  -> blend(0.8, channel_float)
      :neutral -> blend(0.5, channel_float)
      _        -> channel_float
    end
  end

  # 70% user learned, 30% channel default when both exist
  defp blend(user_val, channel_val), do: user_val * 0.7 + channel_val * 0.3

  # ---------------------------------------------------------------------------
  # Scoring: Length Appropriateness
  # ---------------------------------------------------------------------------

  @execute_max 200
  @analyze_min 500

  defp score_length(message, profile) do
    len = String.length(message)
    mode_score = infer_mode_length_score(message, len, profile.preferred_length)

    case profile do
      %{avg_length: avg_len} when is_number(avg_len) and avg_len > 0 ->
        profile_score = length_similarity(len, avg_len)
        Float.round(mode_score * 0.6 + profile_score * 0.4, 4)

      _ ->
        mode_score
    end
  end

  defp infer_mode_length_score(message, len, preferred_length) do
    has_code_block? = String.contains?(message, "```")
    has_steps?      = Regex.match?(~r/^\d+\./m, message)
    has_analysis?   = Regex.match?(~r/\b(analysis|because|therefore|however|thus)\b/i, message)

    # Channel/profile preferred length adjusts the target bands
    {short_max, long_min} =
      case preferred_length do
        :short  -> {150, 400}
        :long   -> {400, 800}
        _       -> {200, 500}
      end

    cond do
      has_steps? and len > short_max * 3 ->
        penalise_ratio(len, short_max)

      has_analysis? and len < long_min ->
        penalise_ratio(long_min, len)

      has_code_block? and len < 50 ->
        0.5

      true ->
        cond do
          len < 10         -> 0.4
          len < 20         -> 0.6
          len < 2_000      -> 1.0
          len < 4_000      -> 0.8
          true             -> 0.5
        end
    end
  end

  defp length_similarity(actual, expected) when expected > 0 do
    ratio = actual / expected

    cond do
      ratio > 3.0 -> max(0.2, 1.0 - (ratio - 3.0) * 0.1)
      ratio < 1 / 3 -> max(0.2, ratio * 3.0)
      true -> 1.0
    end
  end

  defp length_similarity(_actual, _expected), do: 1.0

  defp penalise_ratio(numerator, denominator) when denominator > 0 do
    ratio = numerator / denominator
    max(0.1, 1.0 - (ratio - 1.0) * 0.2)
  end

  defp penalise_ratio(_, _), do: 0.5

  # ---------------------------------------------------------------------------
  # Scoring: Formality Alignment
  # ---------------------------------------------------------------------------

  @formal_markers ~w(therefore regarding additionally consequently furthermore accordingly
                     henceforth aforementioned pursuant herewith kindly)
  @informal_markers ~w(yeah cool nah gonna lol haha wanna kinda sorta yo sup bruh
                       hey tbh tbf idk omg lmao wtf)

  defp score_formality(message, profile) do
    response_formality = estimate_response_formality(message)

    case profile do
      %{formality: user_formality} when is_float(user_formality) ->
        diff = abs(user_formality - response_formality)
        Float.round(1.0 - diff, 4)

      _ ->
        mid_penalty = abs(response_formality - 0.5) * 0.2
        Float.round(1.0 - mid_penalty, 4)
    end
  end

  defp estimate_response_formality(message) do
    lower = String.downcase(message)
    words = max(1, length(String.split(lower, ~r/\W+/, trim: true)))

    formal_count   = Enum.count(@formal_markers, &String.contains?(lower, &1))
    informal_count = Enum.count(@informal_markers, &String.contains?(lower, &1))

    formal_density   = min(formal_count / words * 10, 0.5)
    informal_density = min(informal_count / words * 10, 0.5)

    clamped = 0.5 + formal_density - informal_density
    max(0.0, min(1.0, clamped))
  end

  # ---------------------------------------------------------------------------
  # Scoring: Clarity
  # ---------------------------------------------------------------------------

  @jargon_words ~w(synergize leverage paradigm ecosystem holistic scalable
                   agile robust mission-critical best-of-breed bandwidth)

  defp score_clarity(message) do
    len = String.length(message)
    sentences = split_sentences(message)

    long_sentence_penalty =
      sentences
      |> Enum.count(fn s ->
        word_count = s |> String.split(~r/\s+/, trim: true) |> length()
        word_count > 40
      end)
      |> then(&(&1 * 0.1))

    lower = String.downcase(message)
    words = max(1, length(String.split(lower, ~r/\W+/, trim: true)))
    jargon_count   = Enum.count(@jargon_words, &String.contains?(lower, &1))
    jargon_penalty = min(jargon_count / words * 5, 0.3)

    wall_penalty =
      if len > 500 and not String.contains?(message, "\n\n"), do: 0.2, else: 0.0

    has_bullets?  = Regex.match?(~r/^\s*[-*]\s+/m, message)
    has_headers?  = Regex.match?(~r/^#+\s+\S/m, message)
    has_numbers?  = Regex.match?(~r/^\d+\.\s+/m, message)
    structure_bonus = if has_bullets? or has_headers? or has_numbers?, do: 0.1, else: 0.0

    score = 1.0 - long_sentence_penalty - jargon_penalty - wall_penalty + structure_bonus
    Float.round(max(0.0, min(1.0, score)), 4)
  end

  defp split_sentences(message) do
    Regex.split(~r/(?<=[.?!])\s+/, message)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  # ---------------------------------------------------------------------------
  # Scoring: Actionability
  # ---------------------------------------------------------------------------

  @action_verbs ~w(run execute install configure update create delete open close
                   click navigate go start stop restart check verify test deploy
                   set enable disable add remove save export import)

  @vague_phrases [
    "you could maybe",
    "it might be possible",
    "you might want to",
    "it could be that",
    "perhaps you should",
    "you may want to",
    "it is possible that"
  ]

  defp score_actionability(message) do
    lower = String.downcase(message)

    has_action_verb? =
      Enum.any?(@action_verbs, fn verb ->
        Regex.match?(~r/\b#{Regex.escape(verb)}\b/, lower)
      end)

    has_numbered_steps? = Regex.match?(~r/^\d+\./m, message)
    has_code_block?     = String.contains?(message, "```")

    vague_count = Enum.count(@vague_phrases, &String.contains?(lower, &1))

    base =
      cond do
        has_numbered_steps? -> 0.9
        has_code_block?     -> 0.85
        has_action_verb?    -> 0.75
        true                -> 0.5
      end

    Float.round(max(0.0, min(1.0, base - vague_count * 0.15)), 4)
  end

  # ---------------------------------------------------------------------------
  # Scoring: Empathy Alignment
  # ---------------------------------------------------------------------------

  @empathy_phrases [
    "i understand", "that makes sense", "good point", "i can see",
    "i appreciate", "that's valid", "i hear you", "fair enough", "you're right"
  ]

  @empathy_marker_words ~w(understand appreciate acknowledge)
  @dismissive_words ~w(just simply obviously clearly merely trivially)

  defp score_empathy(message) do
    lower = String.downcase(message)

    empathy_phrase_count =
      Enum.count(@empathy_phrases, &String.contains?(lower, &1))

    empathy_word_count =
      Enum.count(@empathy_marker_words, fn w ->
        Regex.match?(~r/\b#{Regex.escape(w)}\b/, lower)
      end)

    dismissive_count =
      Enum.count(@dismissive_words, fn w ->
        Regex.match?(~r/\b#{Regex.escape(w)}\b/, lower)
      end)

    base =
      cond do
        empathy_phrase_count > 0 -> 0.9
        empathy_word_count > 1   -> 0.75
        empathy_word_count == 1  -> 0.65
        true                     -> 0.6
      end

    Float.round(max(0.0, min(1.0, base - dismissive_count * 0.1)), 4)
  end

  # ---------------------------------------------------------------------------
  # Suggestion Generation
  # ---------------------------------------------------------------------------

  @suggestion_threshold 0.6

  defp generate_suggestions(scores, profile) do
    []
    |> maybe_add_length_suggestion(scores.length, profile)
    |> maybe_add_formality_suggestion(scores.formality, profile)
    |> maybe_add_clarity_suggestion(scores.clarity)
    |> maybe_add_actionability_suggestion(scores.actionability)
    |> maybe_add_empathy_suggestion(scores.empathy)
  end

  defp maybe_add_length_suggestion(suggestions, score, profile) do
    if score < @suggestion_threshold do
      hint =
        case profile do
          %{avg_length: avg} when is_number(avg) and avg > 0 ->
            "Consider adjusting your response length — the user typically sends ~#{round(avg)} character messages"

          _ ->
            "Consider shortening your response for clarity"
        end

      [hint | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_formality_suggestion(suggestions, score, profile) do
    if score < @suggestion_threshold do
      hint =
        case profile do
          %{formality: f} when is_float(f) and f < 0.4 ->
            "Your response is more formal than the user's style — consider a more casual tone"

          %{formality: f} when is_float(f) and f > 0.7 ->
            "Your response is more casual than the user's style — consider a more formal tone"

          _ ->
            "Consider adjusting the tone to better match the user's communication style"
        end

      [hint | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_clarity_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Break up long paragraphs and use bullet points for readability" | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_actionability_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Add specific next steps or concrete recommendations" | suggestions]
    else
      suggestions
    end
  end

  defp maybe_add_empathy_suggestion(suggestions, score) do
    if score < @suggestion_threshold do
      ["Acknowledge the user's perspective before providing information" | suggestions]
    else
      suggestions
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound: extract the most ambiguous fragment for clarification prompt
  # ---------------------------------------------------------------------------

  defp extract_ambiguous_topic(message) do
    words = String.split(message, ~r/\W+/, trim: true)

    # Prefer nouns/verbs that aren't stopwords
    stopwords = ~w(the a an is are was were be been being have has had do does did will would could should may might must can this that these those i you he she we they it)

    topic =
      words
      |> Enum.reject(&(String.downcase(&1) in stopwords))
      |> Enum.take(3)
      |> Enum.join(" ")

    if topic == "", do: "\"#{String.slice(message, 0, 30)}\"", else: "\"#{topic}\""
  end

  # ---------------------------------------------------------------------------
  # Analytics helpers
  # ---------------------------------------------------------------------------

  defp common_issues([]), do: []

  defp common_issues(scores) do
    poor_count       = Enum.count(scores, &(&1 < 0.4))
    needs_work_count = Enum.count(scores, &(&1 >= 0.4 and &1 < 0.7))

    []
    |> then(fn acc ->
      if poor_count > 0, do: ["#{poor_count} message(s) scored :poor overall" | acc], else: acc
    end)
    |> then(fn acc ->
      if needs_work_count > 0,
        do: ["#{needs_work_count} message(s) scored :needs_work overall" | acc],
        else: acc
    end)
  end
end
