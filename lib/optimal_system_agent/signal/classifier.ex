defmodule OptimalSystemAgent.Signal.Classifier do
  @moduledoc """
  OSA-wired Signal Theory 5-tuple classifier.

  Thin wrapper around `MiosaSignal.MessageClassifier` that injects the OSA
  LLM provider and event bus into the classifier's async enrichment path.

  Architecture:
  - PRIMARY: LLM classification via `MiosaProviders.Registry`
  - FALLBACK: Deterministic pattern matching from `MiosaSignal.MessageClassifier`
  - CACHE: ETS-backed, 10-minute TTL (managed in `MiosaSignal.MessageClassifier`)

  Reference: Luna, R. (2026). Signal Theory: The Architecture of Optimal
  Intent Encoding in Communication Systems. https://zenodo.org/records/18774174
  """

  require Logger

  alias MiosaProviders.Registry, as: Providers
  alias OptimalSystemAgent.PromptLoader
  alias OptimalSystemAgent.Events.Bus

  # Re-export the struct and type from MiosaSignal.MessageClassifier
  @type t :: MiosaSignal.MessageClassifier.t()

  @classification_prompt_fallback """
  You are a Signal Theory classifier. Classify this message into exactly 4 fields.
  Respond ONLY with a JSON object. No explanation, no markdown, no wrapping.

  ## Signal Theory Dimensions

  **mode** — What operational action does this message require?
  - EXECUTE: The user wants something done NOW (run, send, deploy, delete, trigger, sync, import, export)
  - BUILD: The user wants something CREATED (create, generate, write, scaffold, design, develop, implement, make something new)
  - ANALYZE: The user wants INSIGHT (analyze, report, compare, metrics, trend, dashboard, kpi, review data)
  - MAINTAIN: The user wants something FIXED or UPDATED (fix, update, migrate, backup, restore, rollback, patch, upgrade, debug)
  - ASSIST: The user wants HELP or GUIDANCE (explain, how do I, what is, help me understand, teach, clarify)

  Important: Classify by the PRIMARY INTENT, not by individual words.
  "Help me build a rocket" = BUILD (they want to build something)
  "Can you run the tests?" = EXECUTE (they want tests run)
  "What caused the crash?" = ANALYZE (they want analysis)
  "I need to fix the login" = MAINTAIN (they want a fix)

  **genre** — What is the communicative purpose?
  - DIRECT: A command or instruction — the user is telling you to do something
  - INFORM: Sharing information — the user is giving you facts or status
  - COMMIT: Making a promise — "I will", "let me", "I'll handle it"
  - DECIDE: Making or requesting a decision — approve, reject, confirm, cancel, choose
  - EXPRESS: Emotional expression — gratitude, frustration, praise, complaint

  **type** — Domain category:
  - question: Asking for information (contains ?, or starts with who/what/when/where/why/how)
  - request: Asking for an action to be performed
  - issue: Reporting a problem (error, bug, broken, crash, fail)
  - scheduling: Time-related (remind, schedule, later, tomorrow, next week)
  - summary: Asking for condensed information (summarize, recap, brief, overview)
  - report: Providing status or results
  - general: None of the above

  **weight** — Informational density (0.0 to 1.0):
  - 0.0-0.2: Noise (greetings, filler, single words)
  - 0.3-0.5: Low information (simple acknowledgments, short responses)
  - 0.5-0.7: Medium (standard questions, simple requests)
  - 0.7-0.9: High (complex tasks, multi-part requests, technical content)
  - 0.9-1.0: Critical (urgent issues, emergencies, production problems)

  ## Message to classify

  Channel: %CHANNEL%
  Message: "%MESSAGE%"

  Respond with ONLY: {"mode":"...","genre":"...","type":"...","weight":0.0}
  """

  @doc """
  Fast deterministic classification — always <1ms, `confidence: :low`.
  """
  def classify_fast(message, channel \\ :cli) do
    MiosaSignal.MessageClassifier.classify_fast(message, channel)
  end

  @doc """
  Async LLM enrichment — fire-and-forget.

  Spawns a supervised Task that calls the LLM classifier and emits
  `Bus.emit(:signal_classified, ...)` with the enriched signal.
  """
  def classify_async(message, channel \\ :cli, session_id \\ nil) do
    if llm_enabled?() do
      Task.Supervisor.start_child(
        OptimalSystemAgent.Events.TaskSupervisor,
        fn ->
          case call_llm(message, channel) do
            {:ok, data} ->
              Bus.emit(:signal_classified, %{
                signal: data,
                session_id: session_id,
                source: :llm
              })

            {:error, reason} ->
              Logger.debug("[Classifier] Async enrichment failed: #{inspect(reason)}")
          end
        end
      )
    end

    :ok
  end

  @doc """
  Classify a raw message into a Signal 5-tuple.

  Uses the OSA LLM provider when enabled; falls back to deterministic.
  """
  def classify(message, channel \\ :cli) do
    if llm_enabled?() do
      case call_llm(message, channel) do
        {:ok, data} ->
          data

        {:error, _} ->
          Logger.warning(
            "[Classifier] LLM unavailable, falling back to deterministic classification"
          )

          MiosaSignal.MessageClassifier.classify_deterministic(message, channel)
      end
    else
      MiosaSignal.MessageClassifier.classify_deterministic(message, channel)
    end
  end

  @doc """
  Calculate the informational weight of a signal.
  """
  defdelegate calculate_weight(msg), to: MiosaSignal.MessageClassifier

  # ---------------------------------------------------------------------------
  # Private — LLM call via OSA Providers.Registry
  # ---------------------------------------------------------------------------

  defp call_llm(message, channel) do
    safe_message =
      message
      |> String.slice(0, 1000)
      |> String.replace("\"", "'")
      |> String.replace("\n", " ")

    prompt =
      classification_prompt()
      |> String.replace("%MESSAGE%", safe_message)
      |> String.replace("%CHANNEL%", to_string(channel))

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.0, max_tokens: 80) do
      {:ok, %{content: content}} ->
        parse_llm_result(content, message, channel)

      {:error, _} = err ->
        err
    end
  rescue
    e ->
      Logger.warning("[Classifier] LLM classification error: #{Exception.message(e)}")
      {:error, :llm_exception}
  end

  defp parse_llm_result(content, message, channel) do
    json_str =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(json_str) do
      {:ok, data} when is_map(data) ->
        build_signal(data, message, channel)

      {:error, _} ->
        case Regex.run(~r/\{[^}]+\}/, json_str) do
          [json_match] ->
            case Jason.decode(json_match) do
              {:ok, data} -> build_signal(data, message, channel)
              _ -> {:error, :parse_failed}
            end

          _ ->
            {:error, :parse_failed}
        end
    end
  end

  defp build_signal(data, message, channel) do
    mode = parse_mode(data["mode"])
    genre = parse_genre(data["genre"])
    type = parse_type(data["type"])
    weight = parse_weight(data["weight"])

    {:ok,
     %MiosaSignal.MessageClassifier{
       mode: mode || :assist,
       genre: genre || :inform,
       type: type || "general",
       format: classify_format(message, channel),
       weight: weight || MiosaSignal.MessageClassifier.calculate_weight(message),
       raw: message,
       channel: channel,
       timestamp: DateTime.utc_now(),
       confidence: :high
     }}
  end

  defp classification_prompt do
    PromptLoader.get(:classifier, @classification_prompt_fallback)
  end

  defp classify_format(_msg, channel) do
    case channel do
      :cli -> :command
      :telegram -> :message
      :discord -> :message
      :slack -> :message
      :whatsapp -> :message
      :webhook -> :notification
      :filesystem -> :document
      _ -> :message
    end
  end

  defp llm_enabled? do
    Application.get_env(:optimal_system_agent, :classifier_llm_enabled, true)
  end

  defp parse_mode(str) when is_binary(str) do
    case String.downcase(String.trim(str)) do
      "execute" -> :execute
      "assist" -> :assist
      "analyze" -> :analyze
      "build" -> :build
      "maintain" -> :maintain
      _ -> nil
    end
  end

  defp parse_mode(_), do: nil

  defp parse_genre(str) when is_binary(str) do
    case String.downcase(String.trim(str)) do
      "direct" -> :direct
      "inform" -> :inform
      "commit" -> :commit
      "decide" -> :decide
      "express" -> :express
      _ -> nil
    end
  end

  defp parse_genre(_), do: nil

  defp parse_type(str) when is_binary(str) do
    valid = ~w(question request issue scheduling summary report general)
    cleaned = String.downcase(String.trim(str))
    if cleaned in valid, do: cleaned, else: nil
  end

  defp parse_type(_), do: nil

  defp parse_weight(val) when is_float(val), do: max(0.0, min(1.0, val))
  defp parse_weight(val) when is_integer(val), do: max(0.0, min(1.0, val * 1.0))
  defp parse_weight(_), do: nil
end
