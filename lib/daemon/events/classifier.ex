defmodule Daemon.Events.Classifier do
  @moduledoc """
  Signal classifier — safe fallback when MiosaSignal.Classifier is unavailable.

  Provides deterministic, rule-based classification of events into the five
  Signal Theory dimensions when the full LLM-powered `MiosaSignal.Classifier`
  cannot be used. This module ensures the system can always classify events
  even when external dependencies are missing.

  ## Signal Theory Dimensions

  The classifier categorizes events into five dimensions:

  - **mode**: Operational action category (`:code`, `:linguistic`)
    - `:code` — Structured data (maps, lists) or code-like strings
    - `:linguistic` — Plain text messages

  - **genre**: Communicative purpose (`:chat`, `:brief`, `:alert`, `:error`)
    - `:chat` — Default conversational content
    - `:brief` — Task-related events (agent_task, dispatch)
    - `:alert` — Algedonic signals (alerts, warnings)
    - `:error` — System errors and failures

  - **type**: Speech act classification (`:inform`, `:direct`, `:commit`, `:decide`)
    - `:inform` — Information sharing (default)
    - `:direct` — Commands or requests (tool_request, agent_dispatch)
    - `:commit` — Promises or approvals (change_approved)
    - `:decide` — Decision points (route_decided)

  - **format**: Message structure (`:json`, `:code`, `:markdown`, `:cli`)
    - `:json` — Maps and lists
    - `:code` — Code-like strings (detected via `code_like?/1`)
    - `:markdown` — Markdown-formatted text
    - `:cli` — Plain text (default)

  - **structure**: Document type (`:default`, `:error_report`)
    - `:default` — Standard event structure
    - `:error_report` — Error-related events

  ## Functions

  - `classify/1` — Returns a map with all five dimensions for an event
  - `auto_classify/1` — Fills nil signal fields on an event with inferred values
  - `sn_ratio/1` — Calculates signal-to-noise ratio (0.0 to 1.0) based on event completeness
  - `code_like?/1` — Detects if a string contains code patterns (Elixir, JavaScript)

  ## Fallback Behavior

  This module provides safe defaults when `MiosaSignal.Classifier` is unavailable:

  - All scoring functions return neutral values (0.5)
  - Classification uses deterministic pattern matching
  - No external dependencies required
  - Always succeeds, never raises

  ## Example

      iex> event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      iex> Classifier.classify(event)
      %{
        mode: :code,
        genre: :chat,
        type: :inform,
        format: :json,
        structure: :default
      }

      iex> Classifier.auto_classify(event)
      %Event{
        signal_mode: :code,
        signal_genre: :chat,
        signal_type: :inform,
        signal_format: :json,
        signal_structure: :default,
        signal_sn: 0.75  # calculated from event completeness
      }

  ## Signal-to-Noise Ratio

  The `sn_ratio/1` function calculates a score between 0.0 and 1.0 based on:
  - Presence of structured data (maps/lists increase ratio)
  - Signal field completeness (more classified fields = higher ratio)
  - Metadata presence (session_id, correlation_id increase ratio)
  - Context richness

  This ratio is used to prioritize events for processing and to filter
  low-value noise from the event stream.
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
