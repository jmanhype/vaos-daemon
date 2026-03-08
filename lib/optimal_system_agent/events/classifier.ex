defmodule OptimalSystemAgent.Events.Classifier do
  @moduledoc """
  Delegation shim — forwards to `MiosaSignal.Classifier`.

  The canonical implementation lives in the `miosa_signal` package.
  This module exists only for backward-compatibility so that existing
  `alias OptimalSystemAgent.Events.Classifier` calls continue to work.
  """

  @type classification :: MiosaSignal.Classifier.classification()

  defdelegate classify(event), to: MiosaSignal.Classifier
  defdelegate auto_classify(event), to: MiosaSignal.Classifier
  defdelegate sn_ratio(event), to: MiosaSignal.Classifier
  defdelegate infer_mode(event), to: MiosaSignal.Classifier
  defdelegate infer_genre(event), to: MiosaSignal.Classifier
  defdelegate infer_type(event), to: MiosaSignal.Classifier
  defdelegate infer_format(event), to: MiosaSignal.Classifier
  defdelegate infer_structure(event), to: MiosaSignal.Classifier
  defdelegate dimension_score(event), to: MiosaSignal.Classifier
  defdelegate data_score(event), to: MiosaSignal.Classifier
  defdelegate type_score(event), to: MiosaSignal.Classifier
  defdelegate context_score(event), to: MiosaSignal.Classifier
  defdelegate code_like?(str), to: MiosaSignal.Classifier
end
