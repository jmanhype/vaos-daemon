defmodule Daemon.Intelligence.AdaptationTrials do
  @moduledoc """
  Turns trusted adaptation intents into bounded, observable steering trials.

  The initial scope is intentionally narrow: a single research steering trial
  can be active at a time, it is consumed once by `ActiveLearner`, and it is
  completed or expired explicitly in the adaptation journal.
  """
  use GenServer

  alias Daemon.Events.Bus
  alias Daemon.Intelligence.DecisionJournal
  alias Daemon.Investigation.Retrospector

  @default_trial_ttl_ms :timer.minutes(15)
  @default_subscribe_retry_ms 1_000
  @default_promotion_threshold 2
  @default_suppression_threshold 2
  @default_promotion_ttl_ms :timer.minutes(30)
  @default_suppression_ttl_ms :timer.minutes(30)
  @supported_intents MapSet.new([
                       "meta_reflect_requested",
                       "meta_consolidate_requested",
                       "meta_pivot_requested"
                     ])

  defstruct journal: DecisionJournal,
            bus: Bus,
            scorer: &Retrospector.compute_quality/1,
            subscribe?: true,
            subscription_ref: nil,
            subscribe_retry_ms: @default_subscribe_retry_ms,
            evidence: %{},
            promotions: %{},
            suppressions: %{},
            promotion_threshold: @default_promotion_threshold,
            suppression_threshold: @default_suppression_threshold,
            promotion_ttl_ms: @default_promotion_ttl_ms,
            suppression_ttl_ms: @default_suppression_ttl_ms,
            trial_ttl_ms: @default_trial_ttl_ms,
            current_trial: nil,
            expiry_ref: nil

  @type trial :: map()
  @type state :: %__MODULE__{}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the active bounded adaptation trial, if one exists."
  def current_trial(server \\ __MODULE__) do
    GenServer.call(server, :current_trial)
  catch
    :exit, _ -> nil
  end

  @doc "Return the current trial, promotions, and suppressions."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _ -> %{current_trial: nil, active_promotions: [], active_suppressions: []}
  end

  @doc "Return promoted steering for the given bottleneck, if active."
  def promoted_steering(bottleneck, server \\ __MODULE__) do
    GenServer.call(server, {:promoted_steering, bottleneck})
  catch
    :exit, _ -> nil
  end

  @doc "Consider starting a bounded trial from a trusted meta intent."
  def consider_intent(event_type, context, server \\ __MODULE__) when is_map(context) do
    GenServer.call(server, {:consider_intent, event_type, context})
  catch
    :exit, _ -> :ignored
  end

  @doc "Consume the active trial once for the next chained investigation."
  def consume_trial(topic, server \\ __MODULE__) when is_binary(topic) do
    GenServer.call(server, {:consume_trial, topic})
  catch
    :exit, _ -> :none
  end

  @doc "Observe an investigation outcome and complete the active trial when matched."
  def observe_investigation(meta, server \\ __MODULE__) when is_map(meta) do
    GenServer.call(server, {:observe_investigation, meta})
  catch
    :exit, _ -> :ok
  end

  @doc "Observe a blocked investigation so the active trial gets an explicit terminal state."
  def observe_failure(topic, reason, server \\ __MODULE__) when is_binary(topic) do
    GenServer.call(server, {:observe_failure, topic, reason})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      journal: Keyword.get(opts, :journal, DecisionJournal),
      bus: Keyword.get(opts, :bus, Bus),
      scorer: Keyword.get(opts, :scorer, &Retrospector.compute_quality/1),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      subscribe_retry_ms: Keyword.get(opts, :subscribe_retry_ms, @default_subscribe_retry_ms),
      promotion_threshold: Keyword.get(opts, :promotion_threshold, @default_promotion_threshold),
      suppression_threshold:
        Keyword.get(opts, :suppression_threshold, @default_suppression_threshold),
      promotion_ttl_ms: Keyword.get(opts, :promotion_ttl_ms, @default_promotion_ttl_ms),
      suppression_ttl_ms: Keyword.get(opts, :suppression_ttl_ms, @default_suppression_ttl_ms),
      trial_ttl_ms:
        Keyword.get(
          opts,
          :trial_ttl_ms,
          Application.get_env(:daemon, :adaptation_trial_ttl_ms, @default_trial_ttl_ms)
        )
    }

    if state.subscribe?, do: send(self(), :subscribe)
    {:ok, state}
  end

  @impl true
  def handle_call(:current_trial, _from, state) do
    state = sweep_transients(state)
    {:reply, state.current_trial, state}
  end

  def handle_call(:snapshot, _from, state) do
    state = sweep_transients(state)
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:promoted_steering, bottleneck}, _from, state) do
    state = sweep_transients(state)
    {:reply, promoted_steering_for_bottleneck(state, bottleneck), state}
  end

  def handle_call({:consider_intent, event_type, context}, _from, state) do
    state = sweep_transients(state)

    {result, next_state} =
      do_consider_intent(normalize_name(event_type), normalize_context(context), state)

    {:reply, result, next_state}
  end

  def handle_call({:consume_trial, topic}, _from, state) do
    state = sweep_transients(state)
    {result, next_state} = do_consume_trial(topic, state)
    {:reply, result, next_state}
  end

  def handle_call({:observe_investigation, meta}, _from, state) do
    state = sweep_transients(state)
    {:reply, :ok, do_observe_investigation(normalize_context(meta), state)}
  end

  def handle_call({:observe_failure, topic, reason}, _from, state) do
    state = sweep_transients(state)
    {:reply, :ok, do_observe_failure(topic, normalize_name(reason), state)}
  end

  @impl true
  def handle_info(:subscribe, state) do
    {:noreply, maybe_subscribe(state)}
  end

  def handle_info({:system_event, payload}, state) do
    {:noreply, maybe_handle_system_event(payload, state)}
  end

  def handle_info({:expire_trial, trial_id}, %{current_trial: %{trial_id: trial_id}} = state) do
    state =
      record_trial_event(
        state,
        "trial_expired",
        trial_context(state.current_trial, %{status: :expired})
      )

    {:noreply, clear_trial(state)}
  end

  def handle_info({:expire_trial, _trial_id}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.subscribe? and state.subscription_ref do
      state.bus.unregister_handler(:system_event, state.subscription_ref)
    end

    :ok
  end

  defp maybe_subscribe(%{subscription_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_subscribe(state) do
    case Process.whereis(state.bus) do
      nil ->
        schedule_subscribe_retry(state)

      _pid ->
        owner = self()

        ref =
          state.bus.register_handler(:system_event, fn payload ->
            send(owner, {:system_event, payload})
          end)

        %{state | subscription_ref: ref}
    end
  catch
    :exit, _ -> schedule_subscribe_retry(state)
  end

  defp maybe_handle_system_event(payload, state) do
    case extract_adaptation_signal(payload) do
      {event_type, context} ->
        {_result, next_state} = do_consider_intent(event_type, context, state)
        next_state

      nil ->
        state
    end
  end

  defp extract_adaptation_signal(payload) when is_map(payload) do
    event = payload_value(payload, :event)
    domain = normalize_name(payload_value(payload, :domain))
    event_type = normalize_name(payload_value(payload, :event_type))

    if normalize_name(event) == "adaptation_signal" and domain == "coordination" and
         MapSet.member?(@supported_intents, event_type) do
      {event_type, normalize_context(payload_value(payload, :context) || %{})}
    else
      nil
    end
  end

  defp extract_adaptation_signal(_), do: nil

  defp do_consider_intent(_event_type, _context, %{current_trial: %{} = _trial} = state) do
    {:ignored, state}
  end

  defp do_consider_intent(event_type, context, state) do
    authority_domain = authority_domain(context)
    signature = trial_signature(event_type, context)

    cond do
      not MapSet.member?(@supported_intents, event_type) ->
        {:ignored, state}

      authority_domain not in ["research", nil] ->
        {:ignored, state}

      suppression = Map.get(state.suppressions, signature) ->
        state =
          record_trial_event(
            state,
            "trial_suppressed",
            Map.take(suppression, [
              :trigger_event,
              :bottleneck,
              :negative_streak,
              :reason,
              :expires_at
            ])
          )

        {:suppressed, state}

      true ->
        trial = build_trial(event_type, context, authority_domain, state.trial_ttl_ms)

        state =
          state
          |> schedule_trial_expiry(trial.trial_id)
          |> Map.put(:current_trial, trial)
          |> record_trial_event("trial_started", trial_context(trial))

        {{:started, trial}, state}
    end
  end

  defp do_consume_trial(_topic, %{current_trial: nil} = state), do: {:none, state}

  defp do_consume_trial(_topic, %{current_trial: %{status: status}} = state)
       when status != :pending do
    {:none, state}
  end

  defp do_consume_trial(topic, %{current_trial: trial} = state) do
    consumed =
      trial
      |> Map.put(:status, :awaiting_outcome)
      |> Map.put(:remaining_uses, 0)
      |> Map.put(:applied_topic, topic)
      |> Map.put(:applied_topic_key, normalize_topic(topic))
      |> Map.put(:applied_at, DateTime.utc_now())

    state =
      state
      |> Map.put(:current_trial, consumed)
      |> record_trial_event("trial_applied", trial_context(consumed, %{topic: topic}))

    {{:ok, consumed}, state}
  end

  defp do_observe_investigation(_meta, %{current_trial: nil} = state), do: state

  defp do_observe_investigation(
         meta,
         %{current_trial: %{status: :awaiting_outcome} = trial} = state
       ) do
    topic = payload_value(meta, :topic)

    if normalize_topic(topic || "") == Map.get(trial, :applied_topic_key) do
      quality = score_trial(meta, state.scorer)
      outcome = classify_outcome(quality)

      state =
        state
        |> record_trial_event(
          "trial_completed",
          trial_context(trial, %{
            topic: topic,
            quality: quality,
            outcome: outcome,
            strategy_hash: payload_value(meta, :strategy_hash)
          })
        )
        |> clear_trial()
        |> register_trial_outcome(trial, outcome)

      state
    else
      state
    end
  end

  defp do_observe_investigation(_meta, state), do: state

  defp do_observe_failure(_topic, _reason, %{current_trial: nil} = state), do: state

  defp do_observe_failure(
         topic,
         reason,
         %{current_trial: %{status: :awaiting_outcome} = trial} = state
       ) do
    if normalize_topic(topic) == Map.get(trial, :applied_topic_key) do
      state
      |> record_trial_event(
        "trial_blocked",
        trial_context(trial, %{
          topic: topic,
          outcome: "blocked",
          reason: reason
        })
      )
      |> clear_trial()
    else
      state
    end
  end

  defp do_observe_failure(_topic, _reason, state), do: state

  defp register_trial_outcome(state, trial, outcome) do
    signature = trial_signature(trial)
    evidence = trial_evidence(state, signature, trial)

    case outcome do
      "helpful" ->
        evidence =
          evidence
          |> Map.put(:helpful_streak, evidence.helpful_streak + 1)
          |> Map.put(:negative_streak, 0)
          |> Map.put(:last_outcome, outcome)

        state = put_in(state.evidence[signature], evidence)
        maybe_promote_trial(state, signature, evidence)

      "inconclusive" ->
        state
        |> clear_promotion(signature, trial, outcome)
        |> record_negative_outcome(signature, evidence, outcome)

      "not_helpful" ->
        state
        |> clear_promotion(signature, trial, outcome)
        |> record_negative_outcome(signature, evidence, outcome)

      _ ->
        state
    end
  end

  defp record_negative_outcome(state, signature, evidence, outcome) do
    evidence =
      evidence
      |> Map.put(:helpful_streak, 0)
      |> Map.put(:negative_streak, evidence.negative_streak + 1)
      |> Map.put(:last_outcome, outcome)

    state = put_in(state.evidence[signature], evidence)

    if evidence.negative_streak >= state.suppression_threshold do
      suppression = %{
        signature: signature,
        trigger_event: evidence.trigger_event,
        bottleneck: evidence.bottleneck,
        negative_streak: evidence.negative_streak,
        reason: "repeated_#{outcome}",
        suppressed_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), state.suppression_ttl_ms, :millisecond)
      }

      state
      |> put_in([Access.key(:suppressions), signature], suppression)
      |> record_trial_event(
        "trial_suppression_started",
        Map.take(suppression, [
          :trigger_event,
          :bottleneck,
          :negative_streak,
          :reason,
          :expires_at
        ])
      )
    else
      state
    end
  end

  defp maybe_promote_trial(state, signature, evidence) do
    if evidence.helpful_streak >= state.promotion_threshold and
         not Map.has_key?(state.promotions, signature) do
      promotion = %{
        signature: signature,
        trigger_event: evidence.trigger_event,
        bottleneck: evidence.bottleneck,
        helpful_streak: evidence.helpful_streak,
        steering: evidence.steering,
        promoted_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), state.promotion_ttl_ms, :millisecond)
      }

      state
      |> put_in([Access.key(:promotions), signature], promotion)
      |> record_trial_event(
        "trial_promoted",
        Map.take(promotion, [:trigger_event, :bottleneck, :helpful_streak, :expires_at, :steering])
      )
    else
      state
    end
  end

  defp clear_promotion(state, signature, trial, outcome) do
    case Map.pop(state.promotions, signature) do
      {nil, _promotions} ->
        state

      {promotion, promotions} ->
        state
        |> Map.put(:promotions, promotions)
        |> record_trial_event(
          "trial_promotion_cleared",
          %{
            trigger_event: trial.trigger_event,
            bottleneck: trial.bottleneck,
            prior_helpful_streak: promotion.helpful_streak,
            outcome: outcome
          }
        )
    end
  end

  defp trial_evidence(state, signature, trial) do
    Map.get(state.evidence, signature, %{
      trigger_event: trial.trigger_event,
      bottleneck: trial.bottleneck,
      steering: trial.steering,
      helpful_streak: 0,
      negative_streak: 0,
      last_outcome: nil
    })
  end

  defp build_trial(event_type, context, authority_domain, trial_ttl_ms) do
    now = DateTime.utc_now()
    bottleneck = context_value(context, "bottleneck")
    trial_id = System.unique_integer([:positive])

    %{
      trial_id: trial_id,
      trial_type: "steering",
      domain: authority_domain || "research",
      trigger_event: event_type,
      status: :pending,
      remaining_uses: 1,
      bottleneck: bottleneck,
      steering: build_steering(event_type, bottleneck),
      created_at: now,
      expires_at: DateTime.add(now, trial_ttl_ms, :millisecond)
    }
  end

  defp build_steering("meta_reflect_requested", bottleneck) do
    """
    TRIAL STEERING: Treat this investigation as a reflection pass. Slow down, verify independently, and repair the current bottleneck#{format_bottleneck_suffix(bottleneck)}.
    """
    |> String.trim()
  end

  defp build_steering("meta_consolidate_requested", bottleneck) do
    """
    TRIAL STEERING: Treat this investigation as a consolidation pass. Prefer verified synthesis, connect corroborating evidence, and reduce open-loop sprawl#{format_bottleneck_suffix(bottleneck)}.
    """
    |> String.trim()
  end

  defp build_steering("meta_pivot_requested", bottleneck) do
    """
    TRIAL STEERING: Treat this investigation as a pivot pass. Challenge the default angle, test alternative evidence paths, and explicitly target the current bottleneck#{format_bottleneck_suffix(bottleneck)}.
    """
    |> String.trim()
  end

  defp build_steering(_event_type, bottleneck) do
    """
    TRIAL STEERING: Run a bounded corrective investigation and target the current bottleneck#{format_bottleneck_suffix(bottleneck)}.
    """
    |> String.trim()
  end

  defp format_bottleneck_suffix(nil), do: ""
  defp format_bottleneck_suffix(""), do: ""
  defp format_bottleneck_suffix(bottleneck), do: " (#{bottleneck})"

  defp score_trial(meta, scorer) when is_function(scorer, 1) do
    scorer.(meta)
  rescue
    _ -> 0.0
  end

  defp score_trial(meta, scorer) do
    apply(scorer, :compute_quality, [meta])
  rescue
    _ -> 0.0
  end

  defp classify_outcome(quality) when is_number(quality) and quality >= 0.6, do: "helpful"
  defp classify_outcome(quality) when is_number(quality) and quality >= 0.35, do: "inconclusive"
  defp classify_outcome(_quality), do: "not_helpful"

  defp schedule_trial_expiry(state, trial_id) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)
    expiry_ref = Process.send_after(self(), {:expire_trial, trial_id}, state.trial_ttl_ms)
    %{state | expiry_ref: expiry_ref}
  end

  defp schedule_subscribe_retry(state) do
    Process.send_after(self(), :subscribe, state.subscribe_retry_ms)
    state
  end

  defp sweep_transients(state) do
    now = DateTime.utc_now()

    promotions =
      state.promotions
      |> Enum.filter(fn {_signature, promotion} -> not expired?(promotion.expires_at, now) end)
      |> Map.new()

    suppressions =
      state.suppressions
      |> Enum.filter(fn {_signature, suppression} ->
        not expired?(suppression.expires_at, now)
      end)
      |> Map.new()

    %{state | promotions: promotions, suppressions: suppressions}
  end

  defp clear_trial(state) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)
    %{state | current_trial: nil, expiry_ref: nil}
  end

  defp record_trial_event(state, event_type, context) do
    state.journal.record_adaptation(:coordination, event_type, context)
    state
  end

  defp trial_context(trial, extra \\ %{}) do
    %{
      authority_domain: trial.domain,
      bottleneck: trial.bottleneck,
      trial_type: trial.trial_type,
      trigger_event: trial.trigger_event,
      status: trial.status,
      remaining_uses: trial.remaining_uses,
      steering_hypothesis: trial.steering
    }
    |> Map.merge(extra)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp authority_domain(context) do
    context_value(context, "authority_domain") || "research"
  end

  defp snapshot_from_state(state) do
    %{
      current_trial: state.current_trial,
      active_promotions:
        state.promotions
        |> Map.values()
        |> Enum.sort_by(& &1.promoted_at, {:desc, DateTime}),
      active_suppressions:
        state.suppressions
        |> Map.values()
        |> Enum.sort_by(& &1.suppressed_at, {:desc, DateTime})
    }
  end

  defp promoted_steering_for_bottleneck(state, bottleneck) do
    normalized_bottleneck = normalize_name(bottleneck)

    state.promotions
    |> Map.values()
    |> Enum.filter(fn promotion -> promotion.bottleneck == normalized_bottleneck end)
    |> Enum.sort_by(& &1.promoted_at, {:desc, DateTime})
    |> List.first()
    |> then(fn
      %{steering: steering} -> steering
      _ -> nil
    end)
  end

  defp trial_signature(trial_or_event_type, context \\ %{})

  defp trial_signature(%{trigger_event: trigger_event, bottleneck: bottleneck}, _context),
    do: "#{trigger_event}|#{bottleneck || "-"}"

  defp trial_signature(event_type, context),
    do: "#{event_type}|#{context_value(context, "bottleneck") || "-"}"

  defp expired?(nil, _now), do: false

  defp expired?(%DateTime{} = expires_at, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) == :lt

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(context, key)
  end

  defp normalize_context(context) when is_map(context) do
    Map.new(context, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_context_value(value)}
      {key, value} -> {key, normalize_context_value(value)}
    end)
  end

  defp normalize_context(_), do: %{}

  defp normalize_context_value(value) when is_map(value), do: normalize_context(value)

  defp normalize_context_value(value) when is_list(value),
    do: Enum.map(value, &normalize_context_value/1)

  defp normalize_context_value(value), do: value

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(value) when is_nil(value), do: nil
  defp normalize_name(value), do: to_string(value)

  defp normalize_topic(topic) when is_binary(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_topic(_), do: ""
end
