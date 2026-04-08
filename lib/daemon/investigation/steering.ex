defmodule Daemon.Investigation.Steering do
  @moduledoc false

  @spec trial(atom() | String.t(), atom() | String.t() | nil) :: String.t()
  def trial(event_type, bottleneck) do
    bottleneck = normalize_bottleneck(bottleneck)

    [trial_intro(normalize_name(event_type), bottleneck), trial_guidance(bottleneck)]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  @spec quality(map() | nil) :: String.t()
  def quality(nil), do: ""

  def quality(diagnosis) when is_map(diagnosis) do
    case normalize_bottleneck(payload_value(diagnosis, :bottleneck)) do
      :low_verification ->
        """
        QUALITY STEERING (from #{format_percent(payload_value(diagnosis, :avg_verification_rate))} verification rate across recent investigations):
        #{numbered_lines(guidance_lines(:low_verification))}
        """

      :high_fraud ->
        """
        QUALITY STEERING (#{format_percent(payload_value(diagnosis, :avg_fraud_penalty))} fraudulent citations detected recently):
        #{numbered_lines(guidance_lines(:high_fraud))}
        """

      :low_grounded ->
        """
        QUALITY STEERING (only #{format_percent(payload_value(diagnosis, :avg_grounded_ratio))} of evidence grounded in papers):
        #{numbered_lines(guidance_lines(:low_grounded))}
        """

      :low_certainty ->
        """
        QUALITY STEERING:
        #{numbered_lines(guidance_lines(:low_certainty))}
        """

      nil ->
        ""
    end
    |> String.trim()
  end

  def quality(_), do: ""

  defp trial_intro("meta_reflect_requested", bottleneck) do
    "TRIAL STEERING: Treat this investigation as a reflection pass. Slow down, verify independently, and repair the current bottleneck#{format_bottleneck_suffix(bottleneck)}."
  end

  defp trial_intro("meta_consolidate_requested", bottleneck) do
    "TRIAL STEERING: Treat this investigation as a consolidation pass. Prefer verified synthesis, connect corroborating evidence, and reduce open-loop sprawl#{format_bottleneck_suffix(bottleneck)}."
  end

  defp trial_intro("meta_pivot_requested", bottleneck) do
    "TRIAL STEERING: Treat this investigation as a pivot pass. Challenge the default angle, test alternative evidence paths, and explicitly target the current bottleneck#{format_bottleneck_suffix(bottleneck)}."
  end

  defp trial_intro(_event_type, bottleneck) do
    "TRIAL STEERING: Run a bounded corrective investigation and target the current bottleneck#{format_bottleneck_suffix(bottleneck)}."
  end

  defp trial_guidance(nil), do: ""

  defp trial_guidance(bottleneck) do
    "CORRECTIVE FOCUS:\n" <> numbered_lines(guidance_lines(bottleneck))
  end

  defp guidance_lines(:low_verification) do
    [
      "For EVERY claim you attribute to a paper, quote the EXACT sentence from the abstract that supports it",
      "If the abstract does not EXPLICITLY state your claim, do NOT attribute it to that paper — instead present it as analytical inference",
      ~s(Use the format: "According to [Author et al.], '[exact quote from abstract]', which suggests [your claim]"),
      "Fewer well-verified claims are worth MORE than many unverified ones",
      "When a paper is only tangentially related, say \"While [paper] addresses [related topic], this specific claim is our analytical assessment\""
    ]
  end

  defp guidance_lines(:high_fraud) do
    [
      "ONLY reference papers that appear in the provided search results above",
      "NEVER fabricate paper titles, authors, DOIs, or publication years",
      "If no paper supports a claim, state it as expert analysis without citation",
      "Double-check every author name and title against the papers context"
    ]
  end

  defp guidance_lines(:low_grounded) do
    [
      "Base EVERY argument primarily on findings from the provided papers",
      "Each claim needs at least one paper citation from the search results",
      "Prefer fewer, well-sourced arguments over many unsourced ones",
      "If you make a claim without paper support, explicitly mark it as [UNSOURCED ANALYSIS]"
    ]
  end

  defp guidance_lines(:low_certainty) do
    [
      "Narrow the claim into a more specific sub-question where evidence can be decisive",
      "Say explicitly when the evidence is contested instead of forcing a strong verdict",
      "Prefer a bounded conclusion over speculative coverage"
    ]
  end

  defp guidance_lines(_), do: []

  defp numbered_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, index} -> "#{index}. #{line}" end)
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_, _), do: nil

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(_), do: ""

  defp normalize_bottleneck(value) when is_atom(value), do: value
  defp normalize_bottleneck("low_verification"), do: :low_verification
  defp normalize_bottleneck("high_fraud"), do: :high_fraud
  defp normalize_bottleneck("low_grounded"), do: :low_grounded
  defp normalize_bottleneck("low_certainty"), do: :low_certainty
  defp normalize_bottleneck(_), do: nil

  defp format_percent(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_percent(_), do: "0.0%"

  defp format_bottleneck_suffix(nil), do: ""
  defp format_bottleneck_suffix(bottleneck), do: " (#{bottleneck})"

  defp blank?(value), do: value in [nil, ""]
end
