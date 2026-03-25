defmodule Daemon.Protocol.CloudEvent do
  @moduledoc """
  Backward-compatibility shim for `MiosaSignal.CloudEvent`.

  The canonical CloudEvent implementation lives in the `miosa_signal` package.
  This module re-exports the struct and delegates all functions so that existing
  code using `alias Daemon.Protocol.CloudEvent` continues to work.
  """

  # Re-export the struct so that %CloudEvent{...} pattern matches compile.
  defstruct [
    :specversion, :type, :source, :subject, :id, :time,
    :datacontenttype, :data
  ]

  @type t :: MiosaSignal.CloudEvent.t()

  defdelegate new(attrs), to: MiosaSignal.CloudEvent
  defdelegate encode(event), to: MiosaSignal.CloudEvent
  defdelegate decode(json), to: MiosaSignal.CloudEvent
  defdelegate from_bus_event(event_map), to: MiosaSignal.CloudEvent
  defdelegate to_bus_event(event), to: MiosaSignal.CloudEvent
end
