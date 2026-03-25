defmodule Daemon.Signal do
  @moduledoc """
  Delegation shim — forwards to `MiosaSignal`.

  The canonical implementation lives in the `miosa_signal` package.
  This module exists only for backward-compatibility so that existing
  `alias Daemon.Signal` calls continue to work.
  """

  @type t :: MiosaSignal.t()
  @type signal_mode :: MiosaSignal.signal_mode()
  @type signal_genre :: MiosaSignal.signal_genre()
  @type signal_type :: MiosaSignal.signal_type()
  @type signal_format :: MiosaSignal.signal_format()
  @type signal_structure :: MiosaSignal.signal_structure()

  defdelegate new(attrs), to: MiosaSignal
  defdelegate valid?(signal), to: MiosaSignal
  defdelegate to_cloud_event(signal), to: MiosaSignal
  defdelegate from_cloud_event(map), to: MiosaSignal
  defdelegate measure_sn_ratio(signal), to: MiosaSignal
end
