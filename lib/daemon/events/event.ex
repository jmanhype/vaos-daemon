defmodule Daemon.Events.Event do
  @moduledoc """
  CloudEvents v1.0.2 event struct for the Daemon event bus.

  Provides `new/2..4`, `child/3..5`, `to_map/1`, and `to_cloud_event/1`.
  Previously delegated to `MiosaSignal.Event` which delegated back here
  (circular delegation — silently crashed every Bus.emit call).
  """

  defstruct [
    # CloudEvents v1.0.2 required
    :id, :type, :source, :time,
    # CloudEvents v1.0.2 optional
    :subject, :data, :dataschema,
    # Tracing
    :parent_id, :session_id, :correlation_id,
    # Signal Theory S=(M,G,T,F,W)
    :signal_mode, :signal_genre, :signal_type, :signal_format, :signal_structure, :signal_sn,
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
      data: data,
      subject: Keyword.get(opts, :subject),
      session_id: Keyword.get(opts, :session_id) || extract_session_id(data),
      parent_id: Keyword.get(opts, :parent_id),
      correlation_id: Keyword.get(opts, :correlation_id)
    }
  end

  @doc "Create a child event derived from a parent."
  def child(parent, type, source), do: child(parent, type, source, nil, [])
  def child(parent, type, source, data), do: child(parent, type, source, data, [])

  def child(%__MODULE__{} = parent, type, source, data, opts) do
    new(type, source, data,
      Keyword.merge(opts,
        parent_id: parent.id,
        session_id: parent.session_id,
        correlation_id: parent.correlation_id || parent.id
      )
    )
  end

  @doc "Convert an Event struct to a plain map (all fields)."
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  def to_map(other) when is_map(other), do: other

  @doc "Convert to CloudEvents v1.0.2 format."
  def to_cloud_event(%__MODULE__{} = event) do
    %{
      specversion: event.specversion,
      type: to_string(event.type),
      source: event.source,
      id: event.id,
      time: if(event.time, do: DateTime.to_iso8601(event.time)),
      subject: event.subject,
      datacontenttype: event.datacontenttype,
      data: event.data
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp extract_session_id(%{session_id: sid}) when is_binary(sid), do: sid
  defp extract_session_id(_), do: nil
end
