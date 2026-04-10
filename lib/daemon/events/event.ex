defmodule Daemon.Events.Event do
  @moduledoc """
  CloudEvents v1.0.2 event struct for the Daemon event bus.

  Provides `new/2..4`, `child/3..5`, `to_map/1`, and `to_cloud_event/1`.
  Previously delegated to `MiosaSignal.Event` which delegated back here
  (circular delegation — silently crashed every Bus.emit call).
  """

  defstruct [
    # CloudEvents v1.0.2 required
    :id,
    :type,
    :source,
    :time,
    # CloudEvents v1.0.2 optional
    :subject,
    :data,
    :dataschema,
    # Tracing
    :parent_id,
    :session_id,
    :correlation_id,
    # Signal Theory S=(M,G,T,F,W)
    :signal_mode,
    :signal_genre,
    :signal_type,
    :signal_format,
    :signal_structure,
    :signal_sn,
    # Defaults
    specversion: "1.0.2",
    datacontenttype: "application/json",
    extensions: %{}
  ]

  @type t :: %__MODULE__{}
  @type signal_mode :: :utility | :specialist | :elite | nil
  @type signal_genre :: atom() | nil
  @type signal_type :: atom() | nil
  @type signal_format :: atom() | nil

  @doc "Create a new event with type and source."
  def new(type, source), do: new(type, source, nil, [])

  @doc "Create a new event with type, source, and data."
  def new(type, source, data), do: new(type, source, data, [])

  @doc "Create a new event with type, source, data, and options."
  def new(type, source, data, opts) when is_list(opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      type: type,
      source: to_string(source),
      time: Keyword.get(opts, :time, DateTime.utc_now()),
      subject: Keyword.get(opts, :subject),
      data: data,
      dataschema: Keyword.get(opts, :dataschema),
      session_id: Keyword.get(opts, :session_id) || extract_session_id(data),
      parent_id: Keyword.get(opts, :parent_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      signal_mode: Keyword.get(opts, :signal_mode),
      signal_genre: Keyword.get(opts, :signal_genre),
      signal_type: Keyword.get(opts, :signal_type),
      signal_format: Keyword.get(opts, :signal_format),
      signal_structure: Keyword.get(opts, :signal_structure),
      signal_sn: Keyword.get(opts, :signal_sn),
      datacontenttype: Keyword.get(opts, :datacontenttype, "application/json"),
      extensions: Keyword.get(opts, :extensions, %{})
    }
  end

  @doc "Create a child event derived from a parent."
  def child(parent, type, source), do: child(parent, type, source, nil, [])
  def child(parent, type, source, data), do: child(parent, type, source, data, [])

  def child(%__MODULE__{} = parent, type, source, data, opts) do
    inherited = [
      parent_id: parent.id,
      session_id: parent.session_id,
      correlation_id: parent.correlation_id || parent.id
    ]

    new(type, source, data, Keyword.merge(inherited, opts))
  end

  @doc "Convert an Event struct to a plain map (all fields)."
  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def to_map(other) when is_map(other), do: other

  @doc "Convert to CloudEvents v1.0.2 format."
  def to_cloud_event(%__MODULE__{} = event) do
    base =
      %{
        "specversion" => event.specversion,
        "type" => to_string(event.type),
        "source" => event.source,
        "id" => event.id,
        "time" => iso8601_time(event.time),
        "subject" => event.subject,
        "data" => event.data,
        "dataschema" => event.dataschema,
        "datacontenttype" => event.datacontenttype,
        "parent_id" => event.parent_id,
        "session_id" => event.session_id,
        "correlation_id" => event.correlation_id,
        "signal_mode" => stringify_atom(event.signal_mode),
        "signal_genre" => stringify_atom(event.signal_genre),
        "signal_type" => stringify_atom(event.signal_type),
        "signal_format" => stringify_atom(event.signal_format),
        "signal_structure" => stringify_atom(event.signal_structure),
        "signal_sn" => event.signal_sn
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.merge(base, stringify_extension_keys(event.extensions))
  end

  defp generate_id do
    timestamp = System.system_time(:microsecond)
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "evt_#{timestamp}_#{suffix}"
  end

  defp extract_session_id(%{session_id: sid}) when is_binary(sid), do: sid
  defp extract_session_id(%{"session_id" => sid}) when is_binary(sid), do: sid
  defp extract_session_id(_), do: nil

  defp iso8601_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso8601_time(time) when is_binary(time), do: time
  defp iso8601_time(_), do: nil

  defp stringify_atom(nil), do: nil
  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value), do: value

  defp stringify_extension_keys(nil), do: %{}

  defp stringify_extension_keys(extensions) when is_map(extensions) do
    Map.new(extensions, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end
end
