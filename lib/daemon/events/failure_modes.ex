defmodule Daemon.Events.FailureModes do
  @moduledoc """
  Signal Theory failure mode detection for Daemon events.

  Implements Shannon (information), Ashby (variety), Beer (homeostasis),
  Wiener (feedback), and adversarial noise detection.

  ## Failure Modes

    * `:routing_failure` - nil source (Shannon)
    * `:bandwidth_overload` - payload > 100KB (Shannon)
    * `:fidelity_failure` - S/N ratio < 0.3 (Shannon)
    * `:variety_failure` - no signal dimensions resolved (Ashby)
    * `:structure_failure` - partial classification (Ashby)
    * `:genre_mismatch` - declared genre contradicts inferred (Ashby)
    * `:herniation_failure` - parent_id without correlation_id (Beer)
    * `:bridge_failure` - extensions > 20 keys (Beer)
    * `:decay_failure` - event timestamp > 24 hours old (Beer)
    * `:feedback_failure` - direct type without correlation (Wiener)
    * `:adversarial_noise` - extensions > 50 keys (extreme)

  """

  alias Daemon.Events.Event

  @type failure_mode ::
          :routing_failure
          | :bandwidth_overload
          | :fidelity_failure
          | :variety_failure
          | :structure_failure
          | :genre_mismatch
          | :herniation_failure
          | :bridge_failure
          | :decay_failure
          | :feedback_failure
          | :adversarial_noise

  @type violation :: {failure_mode, String.t()}

  @doc """
  Detect all failure modes in an event.

  Returns a list of {mode, description} tuples.
  """
  @spec detect(Event.t()) :: [violation()]
  def detect(%Event{} = event) do
    []
    |> maybe_add_routing_failure(event)
    |> maybe_add_bandwidth_overload(event)
    |> maybe_add_fidelity_failure(event)
    |> maybe_add_variety_failure(event)
    |> maybe_add_structure_failure(event)
    |> maybe_add_genre_mismatch(event)
    |> maybe_add_herniation_failure(event)
    |> maybe_add_bridge_failure(event)
    |> maybe_add_decay_failure(event)
    |> maybe_add_feedback_failure(event)
    |> maybe_add_adversarial_noise(event)
  end

  @doc """
  Check a specific failure mode.

  Returns :ok if no violation, or {:violation, mode, description}.
  """
  @spec check(Event.t(), failure_mode()) :: :ok | violation()
  def check(%Event{} = event, mode) when is_atom(mode) do
    case detect(event) do
      violations ->
        case Enum.find(violations, fn {m, _} -> m == mode end) do
          nil -> :ok
          {^mode, description} -> {:violation, mode, description}
        end
    end
  end

  # Shannon violations

  defp maybe_add_routing_failure(acc, %Event{source: nil}) do
    [{:routing_failure, "source is nil (Shannon routing violation)"} | acc]
  end

  defp maybe_add_routing_failure(acc, _event), do: acc

  defp maybe_add_bandwidth_overload(acc, %Event{} = event) do
    payload_size =
      event.data
      |> inspect()
      |> byte_size()

    if payload_size > 100_000 do
      [{:bandwidth_overload, "payload exceeds 100KB (#{div(payload_size, 1024)}KB)"} | acc]
    else
      acc
    end
  end

  defp maybe_add_fidelity_failure(acc, %Event{signal_sn: sn}) when is_number(sn) do
    if sn < 0.3 do
      [{:fidelity_failure, "S/N ratio #{sn} below 0.3 threshold"} | acc]
    else
      acc
    end
  end

  defp maybe_add_fidelity_failure(acc, _event), do: acc

  # Ashby violations

  defp maybe_add_variety_failure(acc, %Event{} = event) do
    has_dimensions? =
      event.signal_mode != nil or
        event.signal_genre != nil or
        event.signal_type != nil or
        event.signal_format != nil or
        event.signal_structure != nil

    if not has_dimensions? do
      [{:variety_failure, "no signal dimensions resolved (Ashby variety violation)"} | acc]
    else
      acc
    end
  end

  defp maybe_add_structure_failure(acc, %Event{} = event) do
    dimensions = [
      event.signal_mode,
      event.signal_genre,
      event.signal_type,
      event.signal_format,
      event.signal_structure
    ]

    set_count = Enum.count(dimensions, &(&1 != nil))

    if set_count > 0 and set_count < 5 do
      [{:structure_failure, "partial classification (#{set_count}/5 dimensions)"} | acc]
    else
      acc
    end
  end

  defp maybe_add_genre_mismatch(acc, %Event{} = event) do
    inferred_genre = infer_genre_from_type(event.type)

    if event.signal_genre != nil and event.signal_genre != inferred_genre do
      [{:genre_mismatch, "declared genre #{event.signal_genre} contradicts inferred #{inferred_genre}"} | acc]
    else
      acc
    end
  end

  defp infer_genre_from_type(type) when is_atom(type) do
    type_str = to_string(type)

    cond do
      String.contains?(type_str, ["error", "failure", "crash", "exception"]) -> :error
      String.contains?(type_str, ["request", "query", "prompt"]) -> :query
      true -> :chat
    end
  end

  # Beer violations

  defp maybe_add_herniation_failure(acc, %Event{} = event) do
    if event.parent_id != nil and event.correlation_id == nil do
      [{:herniation_failure, "parent_id without correlation_id (causality break)"} | acc]
    else
      acc
    end
  end

  defp maybe_add_bridge_failure(acc, %Event{} = event) do
    extension_count = map_size(event.extensions || %{})

    if extension_count > 20 do
      [{:bridge_failure, "extensions exceed 20 keys (#{extension_count} total)"} | acc]
    else
      acc
    end
  end

  defp maybe_add_decay_failure(acc, %Event{} = event) do
    if event.time != nil do
      age_seconds = DateTime.diff(DateTime.utc_now(), event.time)

      if age_seconds > 86_400 do
        [{:decay_failure, "event timestamp is #{div(age_seconds, 3600)} hours old"} | acc]
      else
        acc
      end
    else
      acc
    end
  end

  # Wiener violations

  defp maybe_add_feedback_failure(acc, %Event{} = event) do
    if event.signal_type == :direct and event.correlation_id == nil do
      [{:feedback_failure, "direct type without correlation_id (feedback loop broken)"} | acc]
    else
      acc
    end
  end

  # Adversarial noise

  defp maybe_add_adversarial_noise(acc, %Event{} = event) do
    extension_count = map_size(event.extensions || %{})

    if extension_count > 50 do
      [{:adversarial_noise, "extreme extension count (#{extension_count} keys) suggests adversarial input"} | acc]
    else
      acc
    end
  end
end
