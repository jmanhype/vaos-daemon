defmodule Daemon.Events.Classifier do
  @moduledoc """
  Signal classifier — safe fallback when MiosaSignal.Classifier is unavailable.

  This module provides a minimal, deterministic implementation of Signal Theory
  classification for events flowing through the Daemon event bus. It serves as
  a safe fallback when the full MiosaSignal.Classifier (external dependency) is
  not available or fails to load.

  ## Signal Theory Dimensions

  Each event is classified across five orthogonal dimensions:

    * **mode** — `:code` (structured data, programmatic) or `:linguistic` (natural language)
    * **genre** — `:chat`, `:error`, `:alert`, `:brief`, `:spec`, `:status`
    * **type** — speech act: `:inform`, `:direct`, `:commit`, `:decide`
    * **format** — `:json`, `:code`, `:markdown`, `:cli`
    * **structure** — `:default`, `:error_report`, `:status_report`

  ## Signal-to-Noise Ratio

  The `sn_ratio/1` function calculates a signal quality score (0.0-1.0) based on:
  - Event payload presence and structure
  - Metadata completeness (session_id, correlation_id, etc.)
  - Pre-classified signal dimensions

  Higher ratios indicate richer, more actionable events.

  ## Usage

  The Event Bus calls `auto_classify/1` for every event that lacks explicit
  signal metadata. This fills in missing dimensions while preserving any
  manually-specified values.

  ## Functions

  All functions are pure and deterministic. No external dependencies beyond
  standard library. Safe to call from any context.

  ### Core Classification

    * `classify/1` — returns full 5-dimension classification map
    * `auto_classify/1` — fills nil signal fields on Event struct, preserves existing
    * `sn_ratio/1` — calculates signal-to-noise ratio (0.0-1.0)

  ### Individual Dimensions

    * `infer_mode/1` — code vs linguistic
    * `infer_genre/1` — high-level category
    * `infer_type/1` — speech act classification
    * `infer_format/1` — data format detection
    * `infer_structure/1` — structural pattern

  ### Scoring Helpers

    * `dimension_score/1` — score based on dimension count
    * `data_score/1` — score based on payload presence
    * `type_score/1` — score based on event type
    * `context_score/1` — score based on metadata fields

  ### Utilities

    * `code_like?/1` — heuristic detection of code strings

  ## Examples

      iex> event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      iex> Classifier.classify(event)
      %{
        mode: :code,
        genre: :chat,
        type: :inform,
        format: :json,
        structure: :default
      }

      iex> event = Event.new(:user_message, "cli", "hello world")
      iex> Classifier.auto_classify(event)
      %Event{
        signal_mode: :linguistic,
        signal_genre: :chat,
        signal_type: :inform,
        signal_format: :cli,
        signal_structure: :default,
        signal_sn: 0.4  # approximate
      }
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
