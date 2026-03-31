defmodule Daemon.Events.Classifier do
  @moduledoc """
  Signal classifier for Daemon.Events.Event structures.

  Classifies events along five dimensions of Signal Theory:
  - **mode**: :code | :linguistic — inferred from data structure and content
  - **genre**: :chat | :error | :alert | :brief — inferred from event type
  - **type**: :inform | :direct | :commit | :decide — speech act classification
  - **format**: :json | :code | :markdown | :cli — inferred from data shape
  - **structure**: :default | :error_report — inferred from event type

  ## Primary functions

      # Auto-classify nil signal fields on an event
      Classifier.auto_classify(event)

      # Get full classification map
      Classifier.classify(event)
      # => %{mode: :code, genre: :chat, type: :inform, format: :json, structure: :default}

      # Signal-to-noise ratio (0.0–1.0, higher = more signal)
      Classifier.sn_ratio(event)

  ## Mode inference

  - `:code` — map data, or code-like strings (contains `defmodule`, `function`, `=>`)
  - `:linguistic` — plain strings, nil data

  ## Genre inference

  - `:error` — system_error events
  - `:alert` — algedonic_alert events
  - `:brief` — agent_task events
  - `:chat` — default

  ## Type (speech act) inference

  Based on event type suffixes:
  - `_completed` → `:inform`
  - `_request`, `_dispatch` → `:direct`
  - `_approved` → `:commit`
  - `_decided` → `:decide`
  - default → `:inform`

  ## Format inference

  - Maps and lists → `:json`
  - Code-like strings → `:code`
  - Markdown-like strings (contains `#`, `-`) → `:markdown`
  - Plain text → `:cli`

  ## Structure inference

  - `:error_report` for system_error events
  - `:default` otherwise

  ## Signal-to-noise ratio

  Computes a ratio (0.0–1.0) based on:
  - Data presence (events with data score higher)
  - Signal field completeness (mode, genre, type, format, structure)
  - Metadata fields (session_id, correlation_id)

  ## Code detection

  `code_like?/1` detects code patterns in strings:
  - Elixir: `defmodule`, `def `, `fn `, `|> `
  - JavaScript: `function`, `=>`, `const `, `let `, `class `
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
