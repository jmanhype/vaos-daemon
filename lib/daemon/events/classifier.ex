defmodule Daemon.Events.Classifier do
  @moduledoc """
  Signal classifier stub — safe fallback when MiosaSignal.Classifier is unavailable.

  **NOTE**: This is currently a stub implementation that returns default values.
  The full classification logic should be implemented here or delegated to
  `MiosaSignal.Classifier` when available.

  ## Intended functionality

  This module should classify events along five dimensions:
    - **mode**: Communication intent (:code, :linguistic)
    - **genre**: Event category (:chat, :error, :alert, :brief, :spec)
    - **type**: Speech act (:inform, :direct, :commit, :decide)
    - **format**: Data format (:json, :code, :markdown, :cli)
    - **structure**: Event structure (:default, :error_report)

  ## Current behavior

  All functions return default/placeholder values:
    - `classify/1` - returns empty map `%{}`
    - `auto_classify/1` - returns event unchanged
    - `infer_*` functions - return `nil`
    - `*_score` functions - return `0.5`
    - `sn_ratio/1` - returns `1.0`
    - `code_like?/1` - returns `false`

  ## Integration

  The shim `MiosaSignal.Classifier` delegates to this module.
  Implement the classification logic here to enable Signal Theory features
  when the extracted miosa_signal package is unavailable.
  """
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
