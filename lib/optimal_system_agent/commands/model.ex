defmodule OptimalSystemAgent.Commands.Model do
  @moduledoc """
  Model/provider switching commands.

  Handles `/model`, `/models`, `/providers` and all related sub-commands
  for provider selection, Ollama model management, and tier routing display.
  """

  @doc "Handle the `/model` command with subcommand routing."
  def cmd_model(arg, _session_id) do
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        cmd_model_show()

      trimmed == "list" ->
        cmd_model_list()

      trimmed == "ollama" ->
        cmd_model_switch("ollama", nil)

      trimmed == "ollama list" or trimmed == "ollama ls" or trimmed == "models" ->
        cmd_ollama_models()

      String.starts_with?(trimmed, "ollama-url ") ->
        url = String.trim(String.trim_leading(trimmed, "ollama-url"))
        cmd_model_set_ollama_url(url)

      String.starts_with?(trimmed, "ollama ") ->
        model = String.trim(String.trim_leading(trimmed, "ollama"))
        cmd_model_switch("ollama", model)

      true ->
        case String.split(trimmed, ~r/\s+/, parts: 2) do
          [provider_str, model_str] ->
            cmd_model_switch(provider_str, String.trim(model_str))

          [provider_str] ->
            cmd_model_switch(provider_str, nil)
        end
    end
  end

  @doc "Handle the `/models` shortcut command."
  def cmd_models_shortcut(_arg, _session_id) do
    cmd_ollama_models()
  end

  @doc "Handle the `/providers` command."
  def cmd_providers(_arg, _session_id) do
    alias OptimalSystemAgent.Providers.Registry, as: ProvReg

    providers = ProvReg.list_providers()
    default = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    lines =
      providers
      |> Enum.sort()
      |> Enum.map(fn p ->
        configured = ProvReg.provider_configured?(p)
        active_marker = if p == default, do: " *", else: "  "
        status = if configured, do: "configured", else: "no API key"

        model =
          case ProvReg.provider_info(p) do
            {:ok, info} -> info.default_model || "—"
            _ -> "—"
          end

        "#{active_marker}#{String.pad_trailing(to_string(p), 16)} #{String.pad_trailing(status, 14)} #{model}"
      end)

    header = "LLM Providers (* = active, #{length(providers)} total):\n"
    footer = "\n\nSwitch: /model <provider> [model]"
    {:command, header <> Enum.join(lines, "\n") <> footer}
  end

  @doc "Get the active model for a provider."
  def active_model_for(provider) do
    model_key = :"#{provider}_model"

    case Application.get_env(:optimal_system_agent, model_key) do
      nil ->
        case OptimalSystemAgent.Providers.Registry.provider_info(provider) do
          {:ok, info} -> info.default_model
          _ -> "unknown"
        end

      model ->
        model
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp cmd_model_show do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = active_model_for(provider)
    registry = OptimalSystemAgent.Providers.Registry
    tier_mod = OptimalSystemAgent.Agent.Tier

    configured =
      registry.list_providers()
      |> Enum.filter(&registry.provider_configured?/1)
      |> Enum.map(&to_string/1)
      |> Enum.join(", ")

    tier_lines =
      [:elite, :specialist, :utility]
      |> Enum.map(fn tier ->
        tier_model = tier_mod.model_for(tier, provider)
        budget = tier_mod.total_budget(tier)
        temp = tier_mod.temperature(tier)
        iters = tier_mod.max_iterations(tier)

        "  #{String.pad_trailing(to_string(tier), 12)} #{String.pad_trailing(tier_model, 32)} #{budget}t  T=#{temp}  max=#{iters}"
      end)
      |> Enum.join("\n")

    output =
      """
      Active: #{provider} / #{model}

      Tier routing (#{provider}):
      #{tier_lines}

      Configured providers: #{configured}

      Switch:  /model <provider> [model]
      List:    /model list
      Tiers:   /tiers
      Ollama:  /model ollama-url <url>
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_model_list do
    registry = OptimalSystemAgent.Providers.Registry
    current = Application.get_env(:optimal_system_agent, :default_provider, :unknown)

    lines =
      registry.list_providers()
      |> Enum.sort()
      |> Enum.map(fn p ->
        configured = registry.provider_configured?(p)
        marker = if p == current, do: " *", else: "  "

        {:ok, info} = registry.provider_info(p)
        status = if configured, do: "ready", else: "no key"

        "#{marker}#{String.pad_trailing(to_string(p), 14)} #{String.pad_trailing(info.default_model, 40)} [#{status}]"
      end)

    header = "Providers (* = active):\n"
    footer = "\n\nSwitch: /model <provider> [model]"

    {:command, header <> Enum.join(lines, "\n") <> footer}
  end

  defp cmd_model_switch(provider_str, model_override) do
    provider =
      try do
        String.to_existing_atom(provider_str)
      rescue
        ArgumentError -> nil
      end
    registry = OptimalSystemAgent.Providers.Registry
    available = registry.list_providers()

    cond do
      provider not in available ->
        {:command,
         "Unknown provider: #{provider_str}\n\nUse /model list to see available providers."}

      not registry.provider_configured?(provider) ->
        key_name = String.upcase("#{provider}_API_KEY")

        {:command,
         "Provider #{provider_str} is not configured.\nSet #{key_name} environment variable and restart, or use /model list."}

      provider == :ollama and model_override != nil ->
        case validate_ollama_model(model_override) do
          :ok -> do_model_switch(provider, model_override)
          {:warn, msg} -> do_model_switch(provider, model_override, msg)
          {:error, msg} -> {:command, msg}
        end

      true ->
        do_model_switch(provider, model_override)
    end
  end

  defp do_model_switch(provider, model_override, extra_warning \\ nil) do
    Application.put_env(:optimal_system_agent, :default_provider, provider)

    if model_override do
      model_key = :"#{provider}_model"
      Application.put_env(:optimal_system_agent, model_key, model_override)
    else
      if provider == :ollama do
        OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      end
    end

    model = active_model_for(provider)
    parts = ["Switched to #{provider} / #{model}"]

    parts =
      if provider == :ollama do
        parts ++ [format_tier_refresh()]
      else
        parts
      end

    parts =
      if provider == :ollama and model_override != nil and
           not OptimalSystemAgent.Providers.Ollama.model_supports_tools?(model_override) do
        parts ++
          [
            "⚠ #{model_override} does not support tool calling — tools will be disabled for this model."
          ]
      else
        parts
      end

    parts = if extra_warning, do: parts ++ [extra_warning], else: parts

    {:command, Enum.join(parts, "\n")}
  end

  @doc "Format tier routing table after Ollama model change."
  def format_tier_refresh do
    alias OptimalSystemAgent.Agent.Tier

    case Tier.detect_ollama_tiers() do
      {:ok, mapping} ->
        sizes = Tier.ollama_model_sizes()

        lines =
          [:elite, :specialist, :utility]
          |> Enum.map(fn tier ->
            model = mapping[tier] || "none"
            size = Map.get(sizes, model, 0)
            size_gb = Float.round(size / 1_000_000_000, 1)
            "    #{String.pad_trailing(to_string(tier), 13)}#{String.pad_trailing(model, 34)}#{size_gb} GB"
          end)

        "\nTier routing updated:\n" <> Enum.join(lines, "\n")

      {:error, :no_models} ->
        "\n⚠ No Ollama models found — tier routing cleared."
    end
  end

  defp validate_ollama_model(model_name) do
    case OptimalSystemAgent.Providers.Ollama.list_models() do
      {:ok, models} ->
        names = Enum.map(models, & &1.name)

        if model_name in names do
          :ok
        else
          installed = Enum.join(names, ", ")

          {:error,
           "Model '#{model_name}' not found on Ollama.\n\nInstalled: #{installed}\n\nPull it first: ollama pull #{model_name}"}
        end

      {:error, _} ->
        {:warn, "⚠ Could not reach Ollama to verify model — switching anyway."}
    end
  end

  defp cmd_ollama_models do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
    current_model = Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")

    case OptimalSystemAgent.Providers.Ollama.list_models(url) do
      {:ok, models} ->
        if models == [] do
          {:command, "No models installed.\n\nPull one: ollama pull llama3.2"}
        else
          lines =
            models
            |> Enum.sort_by(fn m -> m.size end, :desc)
            |> Enum.map(fn m ->
              marker = if m.name == current_model, do: " *", else: "  "
              size_gb = Float.round(m.size / 1_000_000_000, 1)
              "#{marker}#{String.pad_trailing(m.name, 36)} #{size_gb} GB"
            end)

          header = "Ollama models at #{url} (* = active):\n"
          footer = "\n\nSwitch: /model ollama <name>"

          {:command, header <> Enum.join(lines, "\n") <> footer}
        end

      {:error, reason} ->
        {:command,
         "Cannot reach Ollama at #{url}: #{reason}\n\nIs Ollama running? Try: ollama serve"}
    end
  end

  defp cmd_model_set_ollama_url(url) do
    if url == "" do
      current = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
      {:command, "Current Ollama URL: #{current}\n\nUsage: /model ollama-url <url>"}
    else
      Application.put_env(:optimal_system_agent, :ollama_url, url)
      {:command, "Ollama URL set to: #{url}\n" <> format_tier_refresh()}
    end
  end
end
