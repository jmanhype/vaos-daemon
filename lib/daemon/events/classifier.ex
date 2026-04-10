defmodule Daemon.Events.Classifier do
  @moduledoc "Heuristic signal classifier used by the event bus compatibility layer."

  alias Daemon.Events.Event

  @type classification :: %{
          mode: atom(),
          genre: atom(),
          type: atom(),
          format: atom(),
          structure: atom()
        }

  def classify(%Event{} = event) do
    %{
      mode: infer_mode(event),
      genre: infer_genre(event),
      type: infer_type(event),
      format: infer_format(event),
      structure: infer_structure(event)
    }
  end

  def classify(event) when is_map(event), do: classify(struct(Event, event))

  def auto_classify(%Event{} = event) do
    inferred = classify(event)

    %{
      event
      | signal_mode: event.signal_mode || inferred.mode,
        signal_genre: event.signal_genre || inferred.genre,
        signal_type: event.signal_type || inferred.type,
        signal_format: event.signal_format || inferred.format,
        signal_structure: event.signal_structure || inferred.structure,
        signal_sn: event.signal_sn || sn_ratio(event)
    }
  end

  def auto_classify(event), do: event

  def sn_ratio(%Event{} = event) do
    score =
      (dimension_score(event) + data_score(event) + type_score(event) + context_score(event)) / 4

    score
    |> max(0.0)
    |> min(1.0)
  end

  def sn_ratio(_event), do: 0.0

  def infer_mode(%Event{data: data}) when is_map(data) or is_list(data), do: :code
  def infer_mode(%Event{data: nil}), do: :linguistic

  def infer_mode(%Event{data: data}) when is_binary(data) do
    if code_like?(data), do: :code, else: :linguistic
  end

  def infer_mode(_event), do: :linguistic

  def infer_genre(%Event{type: type}) do
    type_string = type_string(type)

    cond do
      String.contains?(type_string, "error") -> :error
      String.contains?(type_string, "alert") -> :alert
      String.contains?(type_string, "task") -> :brief
      true -> :chat
    end
  end

  def infer_type(%Event{type: type}) do
    type_string = type_string(type)

    cond do
      String.contains?(type_string, "request") or String.contains?(type_string, "dispatch") ->
        :direct

      String.contains?(type_string, "approved") ->
        :commit

      String.contains?(type_string, "decided") ->
        :decide

      true ->
        :inform
    end
  end

  def infer_format(%Event{data: data}) when is_map(data) or is_list(data), do: :json
  def infer_format(%Event{data: nil}), do: :cli

  def infer_format(%Event{data: data}) when is_binary(data) do
    cond do
      code_like?(data) -> :code
      markdown_like?(data) -> :markdown
      true -> :cli
    end
  end

  def infer_format(_event), do: :json

  def infer_structure(%Event{type: type}) do
    if String.contains?(type_string(type), "error"), do: :error_report, else: :default
  end

  def dimension_score(%Event{} = event) do
    populated =
      [
        event.signal_mode,
        event.signal_genre,
        event.signal_type,
        event.signal_format,
        event.signal_structure
      ]
      |> Enum.count(&(not is_nil(&1)))

    populated / 5
  end

  def data_score(%Event{data: nil}), do: 0.1
  def data_score(%Event{data: data}) when is_map(data) or is_list(data), do: 0.8

  def data_score(%Event{data: data}) when is_binary(data) do
    cond do
      code_like?(data) -> 0.75
      markdown_like?(data) -> 0.55
      true -> 0.35
    end
  end

  def data_score(_event), do: 0.2

  def type_score(%Event{type: nil}), do: 0.0
  def type_score(%Event{}), do: 0.7

  def context_score(%Event{} = event) do
    present =
      [
        event.parent_id,
        event.session_id,
        event.correlation_id,
        event.subject
      ]
      |> Enum.count(&present?/1)

    present / 4
  end

  def context_score(_event), do: 0.0

  def code_like?(str) when is_binary(str) do
    Enum.any?(code_patterns(), &Regex.match?(&1, str))
  end

  def code_like?(_str), do: false

  defp markdown_like?(str) do
    String.starts_with?(str, "#") or
      String.contains?(str, "\n- ") or
      String.contains?(str, "\n* ") or
      String.contains?(str, "```")
  end

  defp type_string(type) when is_atom(type), do: Atom.to_string(type)
  defp type_string(type) when is_binary(type), do: type
  defp type_string(_type), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp code_patterns do
    [
      ~r/\bdefmodule\b/,
      ~r/\bdefp?\b/,
      ~r/\bfn\b.+->/,
      ~r/\|>/,
      ~r/\bconst\b.+=>/,
      ~r/\blet\b.+function\s*\(/,
      ~r/\bclass\s+\w+/
    ]
  end
end
