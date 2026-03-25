# Miosa* shim modules
#
# The extracted miosa_* packages do not exist as path deps in this repository.
# Instead, the actual implementations live inside Daemon itself.
# These shim modules alias the real implementations so that:
#   1. Code that calls MiosaXxx.Foo.bar() compiles and dispatches correctly.
#   2. OSA modules that declare @behaviour MiosaXxx.Behaviour compile.
#   3. Stub modules are provided for packages that have no OSA equivalent yet
#      (MiosaKnowledge, pure behaviour/struct types, etc.).
#
# File: lib/miosa/shims.ex

# ---------------------------------------------------------------------------
# MiosaTools
# ---------------------------------------------------------------------------

defmodule MiosaTools.Behaviour do
  @moduledoc """
  Behaviour contract for OSA tools.

  Any module that implements this behaviour becomes a registered tool in
  `Daemon.Tools.Registry`.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map()) :: {:ok, any()} | {:error, String.t()}
  @callback safety() :: :read_only | :write_safe | :write_destructive | :terminal
  @callback available?() :: boolean()

  @optional_callbacks safety: 0, available?: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour MiosaTools.Behaviour
    end
  end
end

# ---------------------------------------------------------------------------
# MiosaLLM
# ---------------------------------------------------------------------------

defmodule MiosaLLM.HealthChecker do
  @moduledoc "Shim — delegates to Daemon.Providers.HealthChecker."

  defdelegate start_link(opts \\ []), to: Daemon.Providers.HealthChecker
  defdelegate child_spec(opts), to: Daemon.Providers.HealthChecker
  defdelegate record_success(provider), to: Daemon.Providers.HealthChecker
  defdelegate record_failure(provider, reason), to: Daemon.Providers.HealthChecker
  defdelegate record_rate_limited(provider, retry_after_seconds \\ nil),
    to: Daemon.Providers.HealthChecker
  defdelegate is_available?(provider), to: Daemon.Providers.HealthChecker
  defdelegate state(), to: Daemon.Providers.HealthChecker
end

# ---------------------------------------------------------------------------
# MiosaProviders
# ---------------------------------------------------------------------------

defmodule MiosaProviders.Registry do
  @moduledoc "Shim — delegates to Daemon.Providers.Registry."

  defdelegate start_link(opts \\ []), to: Daemon.Providers.Registry
  defdelegate child_spec(opts), to: Daemon.Providers.Registry
  defdelegate chat(messages, opts \\ []), to: Daemon.Providers.Registry
  defdelegate chat_stream(messages, callback, opts \\ []),
    to: Daemon.Providers.Registry
  defdelegate chat_with_fallback(messages, chain, opts \\ []),
    to: Daemon.Providers.Registry
  defdelegate list_providers(), to: Daemon.Providers.Registry
  defdelegate provider_info(provider), to: Daemon.Providers.Registry
  defdelegate context_window(model), to: Daemon.Providers.Registry
  defdelegate provider_configured?(provider), to: Daemon.Providers.Registry
  defdelegate register_provider(name, module), to: Daemon.Providers.Registry
end

defmodule MiosaProviders.Ollama do
  @moduledoc "Shim — delegates to Daemon.Providers.Ollama."

  defdelegate auto_detect_model(), to: Daemon.Providers.Ollama
  defdelegate reachable?(), to: Daemon.Providers.Ollama
  defdelegate list_models(url \\ nil), to: Daemon.Providers.Ollama
  defdelegate model_supports_tools?(model_name), to: Daemon.Providers.Ollama
  defdelegate thinking_model?(model_name), to: Daemon.Providers.Ollama
  defdelegate chat(messages, opts \\ []), to: Daemon.Providers.Ollama
  defdelegate chat_stream(messages, callback, opts \\ []),
    to: Daemon.Providers.Ollama
  defdelegate pick_best_model(models), to: Daemon.Providers.Ollama
  defdelegate name(), to: Daemon.Providers.Ollama
  defdelegate default_model(), to: Daemon.Providers.Ollama
  defdelegate available_models(), to: Daemon.Providers.Ollama
  defdelegate split_ndjson(data), to: Daemon.Providers.Ollama
  defdelegate process_ndjson_line(line, callback, acc), to: Daemon.Providers.Ollama
end

# ---------------------------------------------------------------------------
# MiosaSignal
# ---------------------------------------------------------------------------

defmodule MiosaSignal.Event do
  @moduledoc "Shim — re-exports Daemon.Events.Event struct and delegates."

  # Re-export the struct so that %MiosaSignal.Event{} pattern matches compile.
  defstruct [
    :id, :type, :source, :time,
    :subject, :data, :dataschema,
    :parent_id, :session_id, :correlation_id,
    :signal_mode, :signal_genre, :signal_type, :signal_format, :signal_structure, :signal_sn,
    specversion: "1.0.2",
    datacontenttype: "application/json",
    extensions: %{}
  ]

  @type t :: Daemon.Events.Event.t()

  defdelegate new(type, source), to: Daemon.Events.Event
  defdelegate new(type, source, data), to: Daemon.Events.Event
  defdelegate new(type, source, data, opts), to: Daemon.Events.Event
  defdelegate child(parent, type, source), to: Daemon.Events.Event
  defdelegate child(parent, type, source, data), to: Daemon.Events.Event
  defdelegate child(parent, type, source, data, opts), to: Daemon.Events.Event
  defdelegate to_map(event), to: Daemon.Events.Event
  defdelegate to_cloud_event(event), to: Daemon.Events.Event
end

defmodule MiosaSignal.CloudEvent do
  @moduledoc "Shim — re-exports Daemon.Protocol.CloudEvent struct and delegates."

  defstruct [
    :specversion, :type, :source, :subject, :id, :time,
    :datacontenttype, :data
  ]

  @type t :: Daemon.Protocol.CloudEvent.t()

  defdelegate new(attrs), to: Daemon.Protocol.CloudEvent
  defdelegate encode(event), to: Daemon.Protocol.CloudEvent
  defdelegate decode(json), to: Daemon.Protocol.CloudEvent
  defdelegate from_bus_event(event_map), to: Daemon.Protocol.CloudEvent
  defdelegate to_bus_event(event), to: Daemon.Protocol.CloudEvent
end

defmodule MiosaSignal.Classifier do
  @moduledoc "Shim — delegates to Daemon.Events.Classifier."

  @type classification :: Daemon.Events.Classifier.classification()

  defdelegate classify(event), to: Daemon.Events.Classifier
  defdelegate auto_classify(event), to: Daemon.Events.Classifier
  defdelegate sn_ratio(event), to: Daemon.Events.Classifier
  defdelegate infer_mode(event), to: Daemon.Events.Classifier
  defdelegate infer_genre(event), to: Daemon.Events.Classifier
  defdelegate infer_type(event), to: Daemon.Events.Classifier
  defdelegate infer_format(event), to: Daemon.Events.Classifier
  defdelegate infer_structure(event), to: Daemon.Events.Classifier
  defdelegate dimension_score(event), to: Daemon.Events.Classifier
  defdelegate data_score(event), to: Daemon.Events.Classifier
  defdelegate type_score(event), to: Daemon.Events.Classifier
  defdelegate context_score(event), to: Daemon.Events.Classifier
  defdelegate code_like?(str), to: Daemon.Events.Classifier
end

defmodule MiosaSignal.MessageClassifier do
  @moduledoc "Signal Theory message classification result struct + classifier."

  defstruct [
    :mode, :genre, :type, :format, :weight,
    :raw, :channel, :timestamp, :confidence
  ]

  @type t :: %__MODULE__{}

  @doc "Fast ETS-cached classification."
  def classify_fast(message, channel) do
    classify_deterministic(message, channel)
  end

  @doc "Deterministic pattern-matching classification (no LLM)."
  def classify_deterministic(message, _channel) when is_binary(message) do
    msg = String.downcase(message)
    mode = cond do
      Regex.match?(~r/\b(run|execute|send|deploy|delete|trigger|sync|import|export)\b/, msg) -> :execute
      Regex.match?(~r/\b(create|generate|write|scaffold|design|build|develop|make|implement)\b/, msg) -> :build
      Regex.match?(~r/\b(analyze|report|compare|metrics|trend|dashboard|review|kpi)\b/, msg) -> :analyze
      Regex.match?(~r/\b(fix|update|migrate|backup|restore|rollback|patch|upgrade|debug)\b/, msg) -> :maintain
      true -> :assist
    end
    genre = cond do
      Regex.match?(~r/\b(please|can you|could you|do|make|create)\b/, msg) -> :direct
      Regex.match?(~r/\b(i will|i'll|let me|i can)\b/, msg) -> :commit
      Regex.match?(~r/\b(approve|reject|confirm|cancel|choose|decide)\b/, msg) -> :decide
      Regex.match?(~r/[!?]|great|thanks|thank you|sorry|frustrated/, msg) -> :express
      true -> :inform
    end
    weight = calculate_weight(message)
    {:ok, %__MODULE__{
      mode: mode, genre: genre, type: "general",
      format: :text, weight: weight, raw: message,
      channel: nil, timestamp: DateTime.utc_now(), confidence: :low
    }}
  end
  def classify_deterministic(_, _), do: {:error, :invalid_message}

  @doc "Calculate signal weight (0.0 – 1.0) based on message characteristics."
  def calculate_weight(message) when is_binary(message) do
    len = String.length(message)
    base = min(len / 500.0, 1.0)
    Float.round(base, 2)
  end
  def calculate_weight(_), do: 0.5
end

defmodule MiosaSignal.FailureModes do
  @moduledoc "Shim — delegates to Daemon.Events.FailureModes."

  @type failure_mode :: Daemon.Events.FailureModes.failure_mode()

  defdelegate detect(event), to: Daemon.Events.FailureModes
  defdelegate check(event, mode), to: Daemon.Events.FailureModes
end

# ---------------------------------------------------------------------------
# MiosaMemory
# ---------------------------------------------------------------------------

# MiosaMemory.Store — see lib/miosa/memory_store.ex for the full GenServer implementation.

defmodule MiosaMemory.Emitter do
  @moduledoc "Behaviour for memory event emission."

  @callback emit(topic :: atom() | String.t(), payload :: map()) :: :ok | {:error, term()}
end

defmodule MiosaMemory.Cortex do
  @moduledoc "Shim — delegates to Daemon.Agent.Cortex (the actual GenServer)."
  # Note: Daemon.Agent.Cortex itself delegates here, creating a loop.
  # We break the loop by implementing a minimal stub that the supervisor can start.
  # The real Cortex work is done in Daemon.Agent.Cortex.

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def bulletin do
    GenServer.call(__MODULE__, :bulletin)
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  def active_topics do
    GenServer.call(__MODULE__, :active_topics)
  end

  def session_summary(session_id) do
    GenServer.call(__MODULE__, {:session_summary, session_id})
  end

  def synthesis_stats do
    GenServer.call(__MODULE__, :synthesis_stats)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:bulletin, _from, state), do: {:reply, "", state}
  def handle_call(:refresh, _from, state), do: {:reply, :ok, state}
  def handle_call(:active_topics, _from, state), do: {:reply, [], state}
  def handle_call({:session_summary, _sid}, _from, state), do: {:reply, %{}, state}
  def handle_call(:synthesis_stats, _from, state), do: {:reply, %{}, state}
end

defmodule MiosaMemory.Episodic do
  @moduledoc """
  Shim — delegates to Daemon.Agent.Memory.Episodic (the real GenServer).

  This shim exists so callers using the MiosaMemory.Episodic namespace compile
  and route to the actual ETS-backed implementation.
  """

  def start_link(opts \\ []),
    do: Daemon.Agent.Memory.Episodic.start_link(opts)

  def child_spec(opts),
    do: Daemon.Agent.Memory.Episodic.child_spec(opts)

  def record(event_type, data, session_id),
    do: Daemon.Agent.Memory.Episodic.record(event_type, data, session_id)

  def recall(query, opts \\ []),
    do: Daemon.Agent.Memory.Episodic.recall(query, opts)

  def recent(session_id, limit \\ 20),
    do: Daemon.Agent.Memory.Episodic.recent(session_id, limit)

  def stats,
    do: Daemon.Agent.Memory.Episodic.stats()

  def clear_session(session_id),
    do: Daemon.Agent.Memory.Episodic.clear_session(session_id)

  def temporal_decay(timestamp, half_life_hours),
    do: Daemon.Agent.Memory.Episodic.temporal_decay(timestamp, half_life_hours)
end

defmodule MiosaMemory.Injector do
  @moduledoc "Shim — delegates to Daemon.Agent.Memory.Injector."

  @type injection_context :: map()

  defdelegate inject_relevant(entries, context),
    to: Daemon.Agent.Memory.Injector
  defdelegate format_for_prompt(entries), to: Daemon.Agent.Memory.Injector
end

defmodule MiosaMemory.Taxonomy do
  @moduledoc "Shim — delegates to Daemon.Agent.Memory.Taxonomy."

  @type t :: map()
  @type category :: String.t()
  @type scope :: String.t()

  defdelegate new(content, opts \\ []), to: Daemon.Agent.Memory.Taxonomy
  defdelegate categorize(content), to: Daemon.Agent.Memory.Taxonomy
  defdelegate filter_by(entries, filters), to: Daemon.Agent.Memory.Taxonomy
  defdelegate categories(), to: Daemon.Agent.Memory.Taxonomy
  defdelegate scopes(), to: Daemon.Agent.Memory.Taxonomy
  defdelegate touch(entry), to: Daemon.Agent.Memory.Taxonomy
  defdelegate valid_category?(cat), to: Daemon.Agent.Memory.Taxonomy
  defdelegate valid_scope?(scope), to: Daemon.Agent.Memory.Taxonomy
end

defmodule MiosaMemory.Learning do
  @moduledoc """
  Shim — delegates to Daemon.Agent.Learning (the real GenServer).

  This shim exists so callers using the MiosaMemory.Learning namespace compile
  and route to the actual ETS-backed implementation.
  """

  def start_link(opts \\ []),
    do: Daemon.Agent.Learning.start_link(opts)

  def child_spec(opts),
    do: Daemon.Agent.Learning.child_spec(opts)

  def observe(interaction),
    do: Daemon.Agent.Learning.observe(interaction)

  def correction(what_was_wrong, what_is_right),
    do: Daemon.Agent.Learning.correction(what_was_wrong, what_is_right)

  def error(tool_name, error_message, context),
    do: Daemon.Agent.Learning.error(tool_name, error_message, context)

  def metrics,
    do: Daemon.Agent.Learning.metrics()

  def patterns,
    do: Daemon.Agent.Learning.patterns()

  def solutions,
    do: Daemon.Agent.Learning.solutions()

  def consolidate,
    do: Daemon.Agent.Learning.consolidate()
end

defmodule MiosaMemory.Parser do
  @moduledoc "Stub parser — MiosaMemory.Store handles parsing internally."

  @doc "Parse memory file content into entry maps."
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n## ", trim: true)
    |> Enum.map(fn chunk ->
      [header | lines] = String.split(chunk, "\n", parts: 2)
      %{header: String.trim(header), content: Enum.join(lines, "\n") |> String.trim()}
    end)
  end

  @stop_words MapSet.new(~w(
    the and for are but not you all any can had her was one our out day been have
    from this that with what when will more about which them than been would make
    like time just know take people into year your good some could over such after
    come made find back only first great even give most those down should well
    being work through where much other also life between know years hand high
    because large turn each long next look state want head around move both
    think still might school world kind keep never really need does going right
    used every last very just said same tell call before mean also actually thing
    many then those however these while most only must since well still under
    again too own part here there where help using really trying getting doing
    went got let its use way may new now old see try run put set did get how
    has him his she her its who why yes yet able
  ))

  @doc "Extract keywords from text with stop-word filtering."
  def extract_keywords(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(@stop_words, word) end)
    |> Enum.filter(fn word -> String.length(word) >= 3 end)
    |> Enum.reject(fn word -> Regex.match?(~r/^\d+$/, word) end)
    |> Enum.uniq()
  end
end

defmodule MiosaMemory.Index do
  @moduledoc "Stub index — MiosaMemory.Store manages the ETS index internally."

  @doc "Extract keywords from a message for index lookup."
  def extract_keywords(message) when is_binary(message) do
    MiosaMemory.Parser.extract_keywords(message)
  end

  def extract_keywords(_), do: []
end

# ---------------------------------------------------------------------------
# MiosaBudget
# ---------------------------------------------------------------------------

defmodule MiosaBudget.Emitter do
  @moduledoc "Behaviour for budget event emission."

  @callback emit(topic :: atom() | String.t(), payload :: map()) :: :ok | {:error, term()}
end

defmodule MiosaBudget.Budget do
  @moduledoc """
  Budget GenServer — token/cost tracking with daily and monthly limits.

  This is the actual implementation (not a shim). OSA has no pre-existing
  Budget GenServer, so this module provides one that satisfies all call sites.
  """
  use GenServer
  require Logger

  @daily_default_usd   50.0
  @monthly_default_usd 200.0

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def check_budget do
    GenServer.call(__MODULE__, :check_budget)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(__MODULE__, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
  end

  def calculate_cost(_provider, tokens_in, tokens_out) do
    # Conservative flat rate: $0.000003 per token (~$3/M blended)
    (tokens_in + tokens_out) * 0.000003
  end

  def reset_daily do
    GenServer.cast(__MODULE__, :reset_daily)
  end

  def reset_monthly do
    GenServer.cast(__MODULE__, :reset_monthly)
  end

  # GenServer callbacks

  @impl true
  def init(:ok) do
    state = %{
      daily_spent: 0.0,
      monthly_spent: 0.0,
      daily_limit: Application.get_env(:daemon, :daily_budget_usd, @daily_default_usd),
      monthly_limit: Application.get_env(:daemon, :monthly_budget_usd, @monthly_default_usd),
      entries: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight()
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:check_budget, _from, state) do
    state = maybe_reset(state)
    daily_remaining = max(0.0, state.daily_limit - state.daily_spent)
    monthly_remaining = max(0.0, state.monthly_limit - state.monthly_spent)

    result =
      cond do
        state.daily_spent >= state.daily_limit -> {:over_limit, :daily}
        state.monthly_spent >= state.monthly_limit -> {:over_limit, :monthly}
        true -> {:ok, %{daily_remaining: daily_remaining, monthly_remaining: monthly_remaining}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    state = maybe_reset(state)
    status = %{
      daily_limit: state.daily_limit,
      monthly_limit: state.monthly_limit,
      daily_spent: state.daily_spent,
      monthly_spent: state.monthly_spent,
      daily_remaining: max(0.0, state.daily_limit - state.daily_spent),
      monthly_remaining: max(0.0, state.monthly_limit - state.monthly_spent),
      daily_reset_at: state.daily_reset_at,
      monthly_reset_at: state.monthly_reset_at,
      ledger_entries: length(state.entries)
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:record_cost, provider, model, tokens_in, tokens_out, session_id}, state) do
    cost = calculate_cost(provider, tokens_in, tokens_out)
    entry = %{
      provider: provider, model: model,
      tokens_in: tokens_in, tokens_out: tokens_out,
      cost: cost, session_id: session_id,
      recorded_at: DateTime.utc_now()
    }
    state = %{state |
      daily_spent: state.daily_spent + cost,
      monthly_spent: state.monthly_spent + cost,
      entries: Enum.take([entry | state.entries], 10_000)
    }
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_daily, state) do
    {:noreply, %{state | daily_spent: 0.0, daily_reset_at: tomorrow_midnight()}}
  end

  @impl true
  def handle_cast(:reset_monthly, state) do
    {:noreply, %{state | monthly_spent: 0.0, monthly_reset_at: next_month_midnight()}}
  end

  defp maybe_reset(state) do
    now = DateTime.utc_now()
    state
    |> maybe_reset_daily(now)
    |> maybe_reset_monthly(now)
  end

  defp maybe_reset_daily(state, now) do
    if DateTime.compare(now, state.daily_reset_at) == :gt do
      %{state | daily_spent: 0.0, daily_reset_at: tomorrow_midnight()}
    else
      state
    end
  end

  defp maybe_reset_monthly(state, now) do
    if DateTime.compare(now, state.monthly_reset_at) == :gt do
      %{state | monthly_spent: 0.0, monthly_reset_at: next_month_midnight()}
    else
      state
    end
  end

  defp tomorrow_midnight do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end

  defp next_month_midnight do
    today = Date.utc_today()
    {year, month} = if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}
    Date.new!(year, month, 1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end
end

defmodule MiosaBudget.Treasury do
  @moduledoc "Stub Treasury — budget reserve/release accounting."

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def balance, do: GenServer.call(__MODULE__, :balance)
  def deposit(amount, reason), do: GenServer.cast(__MODULE__, {:deposit, amount, reason})
  def withdraw(amount, reason), do: GenServer.cast(__MODULE__, {:withdraw, amount, reason})
  def reserve(amount, reason), do: GenServer.cast(__MODULE__, {:reserve, amount, reason})
  def release(amount, reason), do: GenServer.cast(__MODULE__, {:release, amount, reason})
  def audit_log, do: GenServer.call(__MODULE__, :audit_log)

  @impl true
  def init(:ok), do: {:ok, %{balance: 0.0, reserved: 0.0, log: []}}
  @impl true
  def handle_call(:balance, _from, s), do: {:reply, {:ok, %{balance: s.balance, reserved: s.reserved}}, s}
  def handle_call(:audit_log, _from, s), do: {:reply, {:ok, s.log}, s}
  @impl true
  def handle_cast({:deposit, amt, reason}, s) do
    {:noreply, %{s | balance: s.balance + amt, log: [{:deposit, amt, reason} | s.log]}}
  end
  def handle_cast({:withdraw, amt, reason}, s) do
    {:noreply, %{s | balance: s.balance - amt, log: [{:withdraw, amt, reason} | s.log]}}
  end
  def handle_cast({:reserve, amt, reason}, s) do
    {:noreply, %{s | reserved: s.reserved + amt, log: [{:reserve, amt, reason} | s.log]}}
  end
  def handle_cast({:release, amt, reason}, s) do
    {:noreply, %{s | reserved: s.reserved - amt, log: [{:release, amt, reason} | s.log]}}
  end
end

# ---------------------------------------------------------------------------
# MiosaKnowledge  (delegates to Vaos.Knowledge — wired 2026-03-23)
# ---------------------------------------------------------------------------

defmodule MiosaKnowledge.Registry do
  @moduledoc "Bridge — lookups resolve through Vaos.Knowledge.Registry."
  def lookup(name), do: Vaos.Knowledge.Registry.lookup(Vaos.Knowledge.Registry, name)
end

defmodule MiosaKnowledge.Backend.ETS do
  @moduledoc "Bridge — delegates to Vaos.Knowledge.Backend.ETS."
  defdelegate init(opts), to: Vaos.Knowledge.Backend.ETS
  def open(name, opts \\ []), do: Vaos.Knowledge.Backend.ETS.init(Keyword.put(opts, :name, name))
  def close(_ref), do: :ok
end

defmodule MiosaKnowledge.Backend.Mnesia do
  @moduledoc "Bridge — Mnesia not implemented in Vaos.Knowledge, falls back to ETS."
  defdelegate init(opts), to: Vaos.Knowledge.Backend.ETS
  def open(name, opts \\ []), do: MiosaKnowledge.Backend.ETS.open(name, opts)
  def close(_ref), do: :ok
end

defmodule MiosaKnowledge.Context do
  @moduledoc "Bridge — delegates to Vaos.Knowledge.Context."

  def for_agent(store_ref, opts \\ []) do
    Vaos.Knowledge.Context.for_agent(MiosaKnowledge.extract_name(store_ref), opts)
  end

  defdelegate to_prompt(ctx), to: Vaos.Knowledge.Context
end

defmodule MiosaKnowledge.Reasoner do
  @moduledoc "Bridge — delegates to Vaos.Knowledge.materialize/2."

  def materialize(store_ref, _rules \\ []) do
    name = MiosaKnowledge.extract_name(store_ref)
    case Vaos.Knowledge.materialize(name) do
      {:ok, rounds} -> {:ok, rounds}
      error -> error
    end
  end
end

defmodule MiosaKnowledge.Store do
  @moduledoc "Bridge — starts a Vaos.Knowledge.Store via the dependency."

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :store_id) || Keyword.get(opts, :name, "default")
    # Ignore :backend — Vaos.Knowledge always uses its own ETS backend
    Vaos.Knowledge.open(name, Keyword.drop(opts, [:backend, :store_id]))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end

defmodule MiosaKnowledge do
  @moduledoc "Bridge — top-level knowledge graph API delegating to Vaos.Knowledge."

  @doc false
  def extract_name({:via, Registry, {_registry, name}}), do: name
  def extract_name(name) when is_binary(name), do: name
  def extract_name(_other), do: "default"

  def open(name, opts \\ []), do: Vaos.Knowledge.open(name, opts)

  def assert(store_ref, triple), do: Vaos.Knowledge.assert(extract_name(store_ref), triple)

  def assert_many(store_ref, triples), do: Vaos.Knowledge.assert_many(extract_name(store_ref), triples)

  def retract(store_ref, triple), do: Vaos.Knowledge.retract(extract_name(store_ref), triple)

  def query(store_ref, pattern), do: Vaos.Knowledge.query(extract_name(store_ref), pattern)

  def count(store_ref), do: Vaos.Knowledge.count(extract_name(store_ref))
  def count(store_ref, _pattern), do: Vaos.Knowledge.count(extract_name(store_ref))

  def sparql(store_ref, query_string), do: Vaos.Knowledge.sparql(extract_name(store_ref), query_string)
end

# ---------------------------------------------------------------------------
# MiosaSignal (top-level) — Signal Theory struct + functions
# ---------------------------------------------------------------------------

defmodule MiosaSignal do
  @moduledoc "Top-level Signal Theory module — wraps the 5-tuple signal struct."

  @type signal_mode :: :execute | :build | :analyze | :maintain | :assist
  @type signal_genre :: :direct | :inform | :commit | :decide | :express
  @type signal_type :: :question | :request | :issue | :scheduling | :summary | :report | :general
  @type signal_format :: :text | :code | :json | :markdown | :binary
  @type signal_structure :: :simple | :compound | :complex

  @type t :: %__MODULE__{
    mode: signal_mode(),
    genre: signal_genre(),
    type: signal_type(),
    format: signal_format(),
    weight: float(),
    content: String.t(),
    metadata: map()
  }

  defstruct mode: :assist, genre: :direct, type: :general,
            format: :text, weight: 0.5, content: "", metadata: %{}

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  def valid?(%__MODULE__{mode: m, genre: g, type: t, format: f})
      when m in [:execute, :build, :analyze, :maintain, :assist] and
           g in [:direct, :inform, :commit, :decide, :express] and
           t in [:question, :request, :issue, :scheduling, :summary, :report, :general] and
           f in [:text, :code, :json, :markdown, :binary], do: true
  def valid?(_), do: false

  def to_cloud_event(%__MODULE__{} = signal) do
    %{
      specversion: "1.0",
      type: "com.miosa.signal.#{signal.mode}",
      source: "osa-agent",
      id: :erlang.unique_integer([:positive]) |> to_string(),
      data: Map.from_struct(signal)
    }
  end

  def from_cloud_event(%{"data" => data}) when is_map(data) do
    new(for {k, v} <- data, into: %{}, do: {String.to_existing_atom(k), v})
  rescue
    _ -> new(%{})
  end
  def from_cloud_event(_), do: new(%{})

  def measure_sn_ratio(%__MODULE__{weight: w}), do: w
  def measure_sn_ratio(_), do: 0.5
end

# ---------------------------------------------------------------------------
# MiosaTools.Instruction
# ---------------------------------------------------------------------------

defmodule MiosaTools.Instruction do
  @moduledoc "Normalised tool instruction struct."

  defstruct tool: "", params: %{}, context: %{}

  @type t :: %__MODULE__{tool: String.t(), params: map(), context: map()}

  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(input)

  def normalize(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "" do
      {:error, "tool name cannot be empty"}
    else
      {:ok, %__MODULE__{tool: trimmed}}
    end
  end

  def normalize({tool, params}) when is_binary(tool) and is_map(params) do
    case normalize(tool) do
      {:ok, inst} -> {:ok, %{inst | params: params}}
      err -> err
    end
  end

  def normalize({_tool, params}) when not is_map(params),
    do: {:error, "params must be a map"}

  def normalize({tool, params, context}) when is_binary(tool) and is_map(params) and is_map(context) do
    case normalize(tool) do
      {:ok, inst} -> {:ok, %{inst | params: params, context: context}}
      err -> err
    end
  end

  def normalize({_tool, _params, context}) when not is_map(context),
    do: {:error, "context must be a map"}

  def normalize(%__MODULE__{} = inst), do: {:ok, inst}

  def normalize(_), do: {:error, "unsupported instruction format"}

  @spec normalize!(term()) :: t()
  def normalize!(input) do
    case normalize(input) do
      {:ok, inst} -> inst
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @spec merge_params(t(), map()) :: t()
  def merge_params(%__MODULE__{} = inst, extra) when is_map(extra) do
    %{inst | params: Map.merge(inst.params, extra)}
  end
end

# ---------------------------------------------------------------------------
# MiosaTools.Middleware
# ---------------------------------------------------------------------------

defmodule MiosaTools.Middleware do
  @moduledoc "Middleware behaviour and executor for tool instructions."

  alias MiosaTools.Instruction

  @callback call(Instruction.t(), next :: (Instruction.t() -> any()), opts :: keyword()) :: any()

  @spec execute(Instruction.t(), [module()], (Instruction.t() -> any())) :: any()
  def execute(%Instruction{} = inst, [], executor), do: executor.(inst)

  def execute(%Instruction{} = inst, [mw | rest], executor) do
    mw.call(inst, fn updated -> execute(updated, rest, executor) end, [])
  end

  defmodule Validation do
    @moduledoc "Validates that required params are present before executing."
    @behaviour MiosaTools.Middleware

    @impl true
    def call(instruction, next, opts) do
      required = Keyword.get(opts, :required, [])
      missing = Enum.reject(required, &Map.has_key?(instruction.params, &1))
      if missing == [] do
        next.(instruction)
      else
        {:error, "missing required params: #{Enum.join(missing, ", ")}"}
      end
    end
  end

  defmodule Timing do
    @moduledoc "Records execution time in microseconds."
    @behaviour MiosaTools.Middleware

    @impl true
    def call(instruction, next, _opts) do
      start = System.monotonic_time(:microsecond)
      result = next.(instruction)
      elapsed = System.monotonic_time(:microsecond) - start
      case result do
        {:ok, val} -> {:ok, val, elapsed}
        other -> other
      end
    end
  end

  defmodule Logging do
    @moduledoc "Logs instruction dispatch."
    @behaviour MiosaTools.Middleware
    require Logger

    @impl true
    def call(instruction, next, _opts) do
      Logger.debug("[MiosaTools] executing #{instruction.tool}")
      result = next.(instruction)
      Logger.debug("[MiosaTools] #{instruction.tool} → #{inspect(result)}")
      result
    end
  end
end

# ---------------------------------------------------------------------------
# MiosaTools.Pipeline
# ---------------------------------------------------------------------------

defmodule MiosaTools.Pipeline do
  @moduledoc "Combinators for sequencing and composing tool instructions."

  alias MiosaTools.Instruction

  @spec pipe([term()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def pipe(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    Enum.reduce_while(instructions, {:ok, %{}}, fn raw, {:ok, acc} ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          merged = Map.merge(acc, inst.params)
          case executor.(inst.tool, merged) do
            {:ok, result} -> {:cont, {:ok, result}}
            {:error, _} = err -> {:halt, err}
          end
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec parallel([term()], keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def parallel(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    tasks =
      Enum.map(instructions, fn raw ->
        Task.async(fn ->
          case Instruction.normalize(raw) do
            {:ok, inst} -> executor.(inst.tool, inst.params)
            err -> err
          end
        end)
      end)

    results = Task.await_many(tasks, 30_000)

    errors = Enum.filter(results, &match?({:error, _}, &1))
    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, v} -> v end)}
    else
      {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  @spec fallback([term()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def fallback(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    Enum.reduce_while(instructions, {:error, "no instructions"}, fn raw, _acc ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          case executor.(inst.tool, inst.params) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = err -> {:cont, err}
          end
        {:error, _} = err -> {:cont, err}
      end
    end)
  end

  @spec retry(term(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def retry(instruction, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)
    attempts = Keyword.get(opts, :attempts, 3)

    case Instruction.normalize(instruction) do
      {:error, _} = err -> err
      {:ok, inst} ->
        Enum.reduce_while(1..attempts, {:error, "not attempted"}, fn _i, _acc ->
          case executor.(inst.tool, inst.params) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = err -> {:cont, err}
          end
        end)
    end
  end
end

defmodule MiosaProviders.OpenAICompat do
  @moduledoc "Shim — delegates to Daemon.Providers.OpenAICompat."

  defdelegate parse_tool_calls(msg), to: Daemon.Providers.OpenAICompat
  defdelegate parse_tool_calls(msg, model), to: Daemon.Providers.OpenAICompat
  defdelegate parse_tool_calls_from_content(content), to: Daemon.Providers.OpenAICompat
  defdelegate format_messages(messages), to: Daemon.Providers.OpenAICompat
  defdelegate normalize_tool_name(name), to: Daemon.Providers.OpenAICompat
  defdelegate chat(messages, opts \\ []), to: Daemon.Providers.OpenAICompat
  defdelegate chat_stream(messages, callback, opts \\ []), to: Daemon.Providers.OpenAICompat
  defdelegate format_tools(tools), to: Daemon.Providers.OpenAICompat
end

defmodule MiosaProviders.Anthropic do
  @moduledoc "Shim — delegates to Daemon.Providers.Anthropic."

  defdelegate chat(messages, opts \\ []), to: Daemon.Providers.Anthropic
  defdelegate chat_stream(messages, callback, opts \\ []), to: Daemon.Providers.Anthropic
  defdelegate format_messages(messages), to: Daemon.Providers.Anthropic
  def format_messages_with_thinking(messages),
    do: Daemon.Providers.Anthropic.format_messages(messages)
  defdelegate extract_thinking(response), to: Daemon.Providers.Anthropic
  defdelegate extract_usage(response), to: Daemon.Providers.Anthropic
  defdelegate maybe_add_thinking(body, thinking), to: Daemon.Providers.Anthropic
  defdelegate build_headers(api_key, thinking), to: Daemon.Providers.Anthropic
  defdelegate available_models(), to: Daemon.Providers.Anthropic
  defdelegate default_model(), to: Daemon.Providers.Anthropic
end

defmodule MiosaProviders.Behaviour do
  @moduledoc "Shim — re-exports Daemon.Providers.Behaviour."
  defdelegate __using__(opts), to: Daemon.Providers.Behaviour
end
