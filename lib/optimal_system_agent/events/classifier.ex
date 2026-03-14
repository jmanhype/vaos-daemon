defmodule OptimalSystemAgent.Events.Classifier do
  @moduledoc "Signal classifier — safe fallback when MiosaSignal.Classifier is unavailable."
  def auto_classify(event), do: event
  def classify(_event), do: %{}
  def sn_ratio(_event), do: 1.0
  def infer_mode(_event), do: nil
  def infer_genre(_event), do: nil
  def infer_type(_event), do: nil
  def infer_format(_event), do: nil
  def infer_structure(_event), do: nil
  def dimension_score(_event), do: 0.5
  def data_score(_event), do: 0.5
  def type_score(_event), do: 0.5
  def context_score(_event), do: 0.5
  def code_like?(_str), do: false
end
