defmodule OptimalSystemAgent.Events.Event do
  @moduledoc """
  Backward-compatibility shim for `MiosaSignal.Event`.

  The canonical Event implementation lives in the `miosa_signal` package.
  This module re-exports the struct and delegates all functions so that existing
  code using `alias OptimalSystemAgent.Events.Event` continues to work.
  """

  # Re-export the struct so that %Event{...} pattern matches compile.
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

  @type t :: MiosaSignal.Event.t()
  @type signal_mode :: MiosaSignal.Event.signal_mode()
  @type signal_genre :: MiosaSignal.Event.signal_genre()
  @type signal_type :: MiosaSignal.Event.signal_type()
  @type signal_format :: MiosaSignal.Event.signal_format()

  defdelegate new(type, source), to: MiosaSignal.Event
  defdelegate new(type, source, data), to: MiosaSignal.Event
  defdelegate new(type, source, data, opts), to: MiosaSignal.Event
  defdelegate child(parent, type, source), to: MiosaSignal.Event
  defdelegate child(parent, type, source, data), to: MiosaSignal.Event
  defdelegate child(parent, type, source, data, opts), to: MiosaSignal.Event
  defdelegate to_map(event), to: MiosaSignal.Event
  defdelegate to_cloud_event(event), to: MiosaSignal.Event
end
