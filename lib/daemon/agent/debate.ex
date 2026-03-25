defmodule Daemon.Agent.Debate do
  @moduledoc """
  Multi-agent debate: run the same prompt across N providers in parallel,
  then synthesize the best answer.

  Each provider receives the same message independently. A designated
  synthesizer provider then reviews all responses, identifies agreements
  and disagreements, and produces a final answer.

  ## Usage

      {:ok, result} = Daemon.Agent.Debate.run("What is recursion?", providers: ["anthropic", "groq"])
      result.synthesis  # final synthesized answer
      result.debate     # [%{provider: "anthropic", response: "..."}, ...]
      result.participants  # number of providers that responded
  """

  require Logger

  alias Daemon.Providers.Registry, as: Providers

  @default_providers ["anthropic", "groq", "ollama"]
  @default_timeout_ms 30_000

  @doc """
  Run a multi-provider debate for the given message.

  ## Options

    - `:providers`            — list of provider name strings (default: first 3 from config or #{inspect(@default_providers)})
    - `:model`                — optional model name override applied to all providers
    - `:timeout`              — ms to wait per agent (default: #{@default_timeout_ms})
    - `:synthesizer_provider` — provider used for the synthesis pass (default: first provider)
    - `:user_id`              — user identifier (informational, passed to logger)

  Returns `{:ok, %{synthesis: String.t(), debate: [map()], participants: non_neg_integer()}}` or
  `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(message, opts \\ []) when is_binary(message) do
    providers = resolve_providers(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    model = Keyword.get(opts, :model)
    user_id = Keyword.get(opts, :user_id, "anonymous")
    synthesizer = Keyword.get(opts, :synthesizer_provider) || List.first(providers)

    if providers == [] do
      {:error, :no_providers}
    else
      Logger.info("[debate] Starting debate — providers=#{inspect(providers)} user=#{user_id}")

      debate_results = run_parallel_debate(message, providers, model, timeout)

      successful = Enum.filter(debate_results, fn {_p, r} -> match?({:ok, _}, r) end)

      if successful == [] do
        Logger.warning("[debate] All providers failed — no successful responses")
        {:error, :all_providers_failed}
      else
        debate_entries =
          Enum.map(successful, fn {provider, {:ok, response}} ->
            %{provider: provider, response: response}
          end)

        synthesis_result = synthesize(message, debate_entries, synthesizer, model, timeout)

        case synthesis_result do
          {:ok, synthesis_text} ->
            {:ok,
             %{
               synthesis: synthesis_text,
               debate: debate_entries,
               participants: length(debate_entries)
             }}

          {:error, reason} ->
            Logger.error("[debate] Synthesis failed: #{inspect(reason)}")
            # Graceful degradation: return best individual response
            %{provider: _p, response: best} = List.first(debate_entries)

            {:ok,
             %{
               synthesis: best,
               debate: debate_entries,
               participants: length(debate_entries)
             }}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_providers(opts) do
    case Keyword.get(opts, :providers) do
      nil ->
        Application.get_env(:daemon, :debate_providers, @default_providers)
        |> Enum.take(3)

      list when is_list(list) ->
        list
    end
  end

  # Dispatch one Task per provider, await all with yield_many, collect results.
  defp run_parallel_debate(message, providers, model, timeout) do
    user_messages = [%{role: "user", content: message}]

    tasks =
      Enum.map(providers, fn provider ->
        provider_atom = safe_provider_atom(provider)
        chat_opts = build_chat_opts(provider_atom, model)

        task =
          Task.async(fn ->
            Providers.chat(user_messages, chat_opts)
          end)

        {provider, task}
      end)

    # Await all tasks with the per-agent timeout
    task_list = Enum.map(tasks, fn {_p, t} -> t end)
    yields = Task.yield_many(task_list, timeout)

    # Zip providers back with their yield results
    Enum.zip(providers, yields)
    |> Enum.map(fn {provider, {_task, yield_result}} ->
      outcome =
        case yield_result do
          {:ok, {:ok, %{content: content}}} when is_binary(content) and content != "" ->
            {:ok, content}

          {:ok, {:ok, %{content: content}}} when is_binary(content) ->
            {:ok, "(empty response)"}

          {:ok, {:error, reason}} ->
            Logger.warning("[debate] Provider #{provider} error: #{inspect(reason)}")
            {:error, reason}

          nil ->
            Logger.warning("[debate] Provider #{provider} timed out after #{timeout}ms")
            {:error, :timeout}

          {:exit, reason} ->
            Logger.warning("[debate] Provider #{provider} crashed: #{inspect(reason)}")
            {:error, reason}

          other ->
            Logger.warning("[debate] Provider #{provider} unexpected result: #{inspect(other)}")
            {:error, :unexpected}
        end

      {provider, outcome}
    end)
  after
    # Ensure all tasks are shut down to avoid zombie tasks
    :ok
  end

  # Build synthesis prompt and call the synthesizer provider synchronously.
  defp synthesize(original_message, debate_entries, synthesizer, model, timeout) do
    responses_text =
      debate_entries
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {%{provider: p, response: r}, idx} ->
        "### Response #{idx} (Provider: #{p})\n#{r}"
      end)

    synthesis_prompt = """
    You are a synthesis expert. Multiple AI agents were asked the same question and provided independent responses below. Your task is to:

    1. Identify key points of **agreement** across responses
    2. Note significant **disagreements** or nuances
    3. Produce a **single, comprehensive final answer** that integrates the best insights

    ## Original Question
    #{original_message}

    ## Agent Responses
    #{responses_text}

    ## Your Task
    Synthesize the above responses into one authoritative answer. Start directly with the answer — do not narrate your synthesis process.
    """

    messages = [%{role: "user", content: synthesis_prompt}]
    provider_atom = safe_provider_atom(synthesizer)
    chat_opts = build_chat_opts(provider_atom, model)

    task = Task.async(fn -> Providers.chat(messages, chat_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, %{content: content}}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, {:ok, _}} ->
        {:error, :empty_synthesis}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :synthesis_timeout}

      {:exit, reason} ->
        {:error, reason}
    end
  end

  defp safe_provider_atom(provider) when is_atom(provider), do: provider

  defp safe_provider_atom(provider) when is_binary(provider) do
    known = ~w(anthropic groq ollama openai google cohere together fireworks deepseek perplexity
               mistral openrouter replicate qwen moonshot zhipu volcengine baichuan mock)

    if provider in known do
      String.to_existing_atom(provider)
    else
      :ollama
    end
  end

  defp build_chat_opts(provider_atom, nil), do: [provider: provider_atom]
  defp build_chat_opts(provider_atom, model), do: [provider: provider_atom, model: model]
end
