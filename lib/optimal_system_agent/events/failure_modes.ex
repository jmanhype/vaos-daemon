defmodule OptimalSystemAgent.Events.FailureModes do
  @moduledoc """
  Delegation shim — forwards to `MiosaSignal.FailureModes`.

  The canonical implementation lives in the `miosa_signal` package.
  This module exists only for backward-compatibility so that existing
  `alias OptimalSystemAgent.Events.FailureModes` calls continue to work.
  """

  @type failure_mode :: MiosaSignal.FailureModes.failure_mode()

  defdelegate detect(event), to: MiosaSignal.FailureModes
  defdelegate check(event, mode), to: MiosaSignal.FailureModes
end
