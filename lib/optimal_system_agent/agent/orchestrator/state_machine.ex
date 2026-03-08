defmodule OptimalSystemAgent.Agent.Orchestrator.StateMachine do
  @moduledoc """
  Pure functional state machine for orchestrator task lifecycle.

  States: :idle → :planning → :executing → :verifying → :completed
                                    ↘                ↘
                                  :error_recovery ←──┘

  Each phase constrains what agents can do:
    - :planning    → READ-ONLY (grep, read, glob)
    - :executing   → FULL tool access
    - :verifying   → READ-ONLY + test commands only
    - Others       → no tool access

  This module has zero side effects — it transforms state structs and
  returns tagged tuples. The orchestrator GenServer owns all effects.
  """

  # ── State Struct ─────────────────────────────────────────────────────

  defstruct phase: :idle,
            task_id: nil,
            plan: nil,
            wave_results: [],
            verification: nil,
            error_count: 0,
            started_at: nil,
            transitions: []

  @type phase :: :idle | :planning | :executing | :verifying | :error_recovery | :completed

  @type t :: %__MODULE__{
          phase: phase(),
          task_id: String.t() | nil,
          plan: map() | nil,
          wave_results: list(),
          verification: map() | nil,
          error_count: non_neg_integer(),
          started_at: DateTime.t() | nil,
          transitions: list(transition_entry())
        }

  @type transition_entry :: %{
          from: phase(),
          to: phase(),
          event: atom(),
          timestamp: DateTime.t()
        }

  @type permission_tier :: :read_only | :full | :read_and_test | :none

  # ── Valid Transitions ────────────────────────────────────────────────

  @valid_transitions %{
    idle: [:planning],
    planning: [:executing, :idle],
    executing: [:verifying, :error_recovery],
    verifying: [:completed, :error_recovery],
    error_recovery: [:planning, :completed]
  }

  # ── Permission Tiers per Phase ───────────────────────────────────────

  @phase_permissions %{
    idle: :none,
    planning: :read_only,
    executing: :full,
    verifying: :read_and_test,
    error_recovery: :read_only,
    completed: :none
  }

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Create a new state machine in :idle phase for the given task.
  """
  @spec new(String.t()) :: t()
  def new(task_id) when is_binary(task_id) do
    %__MODULE__{
      task_id: task_id,
      phase: :idle,
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Transition to a new phase via an event.

  Events:
    - :start_planning   → idle → planning
    - :approve_plan     → planning → executing
    - :reject_plan      → planning → idle
    - :waves_complete   → executing → verifying
    - :wave_failure     → executing → error_recovery
    - :verification_passed → verifying → completed
    - :verification_failed → verifying → error_recovery
    - :replan           → error_recovery → planning
    - :manual_override  → error_recovery → completed

  Returns `{:ok, new_state}` or `{:error, :invalid_transition}`.
  """
  @spec transition(t(), atom()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{} = state, event) do
    case resolve_target(state.phase, event) do
      {:ok, target} ->
        entry = %{
          from: state.phase,
          to: target,
          event: event,
          timestamp: DateTime.utc_now()
        }

        new_state =
          state
          |> Map.put(:phase, target)
          |> Map.update!(:transitions, &[entry | &1])
          |> maybe_increment_error_count(target)

        {:ok, new_state}

      :error ->
        {:error, :invalid_transition}
    end
  end

  @doc """
  Check whether transitioning to `target` phase is valid from current phase.
  """
  @spec can_transition?(t(), phase()) :: boolean()
  def can_transition?(%__MODULE__{phase: current}, target) do
    target in Map.get(@valid_transitions, current, [])
  end

  @doc """
  Return the current phase atom.
  """
  @spec current_phase(t()) :: phase()
  def current_phase(%__MODULE__{phase: phase}), do: phase

  @doc """
  Return the transition log, oldest first.
  """
  @spec history(t()) :: list(transition_entry())
  def history(%__MODULE__{transitions: transitions}), do: Enum.reverse(transitions)

  @doc """
  Return the permission tier for the current phase.

  - `:read_only`     — grep, read, glob only
  - `:full`          — all tools
  - `:read_and_test` — read tools + test shell commands
  - `:none`          — no tool access
  """
  @spec permission_tier(t()) :: permission_tier()
  def permission_tier(%__MODULE__{phase: phase}) do
    Map.fetch!(@phase_permissions, phase)
  end

  @doc """
  Store a plan on the state (only valid in :planning phase).
  """
  @spec set_plan(t(), map()) :: {:ok, t()} | {:error, :wrong_phase}
  def set_plan(%__MODULE__{phase: :planning} = state, plan) when is_map(plan) do
    {:ok, %{state | plan: plan}}
  end

  def set_plan(%__MODULE__{}, _plan), do: {:error, :wrong_phase}

  @doc """
  Append a wave result (only valid in :executing phase).
  """
  @spec add_wave_result(t(), map()) :: {:ok, t()} | {:error, :wrong_phase}
  def add_wave_result(%__MODULE__{phase: :executing} = state, result) when is_map(result) do
    {:ok, %{state | wave_results: state.wave_results ++ [result]}}
  end

  def add_wave_result(%__MODULE__{}, _result), do: {:error, :wrong_phase}

  @doc """
  Store verification results (only valid in :verifying phase).
  """
  @spec set_verification(t(), map()) :: {:ok, t()} | {:error, :wrong_phase}
  def set_verification(%__MODULE__{phase: :verifying} = state, verification) when is_map(verification) do
    {:ok, %{state | verification: verification}}
  end

  def set_verification(%__MODULE__{}, _verification), do: {:error, :wrong_phase}

  @doc """
  Return all valid phases.
  """
  @spec phases() :: list(phase())
  def phases, do: [:idle, :planning, :executing, :verifying, :error_recovery, :completed]

  # ── Private ──────────────────────────────────────────────────────────

  # Map events to target phases
  @event_map %{
    # idle →
    {:idle, :start_planning} => :planning,
    # planning →
    {:planning, :approve_plan} => :executing,
    {:planning, :reject_plan} => :idle,
    # executing →
    {:executing, :waves_complete} => :verifying,
    {:executing, :wave_failure} => :error_recovery,
    # verifying →
    {:verifying, :verification_passed} => :completed,
    {:verifying, :verification_failed} => :error_recovery,
    # error_recovery →
    {:error_recovery, :replan} => :planning,
    {:error_recovery, :manual_override} => :completed
  }

  defp resolve_target(current_phase, event) do
    case Map.get(@event_map, {current_phase, event}) do
      nil -> :error
      target -> {:ok, target}
    end
  end

  defp maybe_increment_error_count(state, :error_recovery) do
    %{state | error_count: state.error_count + 1}
  end

  defp maybe_increment_error_count(state, _), do: state
end
