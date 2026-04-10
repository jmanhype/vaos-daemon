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
    :id,
    :type,
    :source,
    :time,
    :subject,
    :data,
    :dataschema,
    :parent_id,
    :session_id,
    :correlation_id,
    :signal_mode,
    :signal_genre,
    :signal_type,
    :signal_format,
    :signal_structure,
    :signal_sn,
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
  @moduledoc """
  CloudEvent implementation (breaks circular delegation with Daemon.Protocol.CloudEvent).
  """

  defstruct [
    :specversion,
    :type,
    :source,
    :subject,
    :id,
    :time,
    :datacontenttype,
    :data
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      specversion: get_attr(attrs, :specversion, "1.0"),
      type: fetch_required!(attrs, :type),
      source: fetch_required!(attrs, :source),
      subject: get_attr(attrs, :subject),
      id: get_attr(attrs, :id, generate_id()),
      time: get_attr(attrs, :time, DateTime.utc_now() |> DateTime.to_iso8601()),
      datacontenttype: get_attr(attrs, :datacontenttype, "application/json"),
      data: get_attr(attrs, :data)
    }
  end

  def new(_), do: raise(ArgumentError, "cloud event attrs must be a map")

  def encode(%__MODULE__{} = event) do
    cond do
      is_nil(event.type) ->
        {:error, "type is required"}

      is_nil(event.source) ->
        {:error, "source is required"}

      true ->
        payload =
          event
          |> Map.from_struct()
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        {:ok, Jason.encode!(payload)}
    end
  end

  def encode(_), do: {:error, "invalid cloud event"}

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        cond do
          is_nil(get_attr(map, :type)) -> {:error, "type is required"}
          is_nil(get_attr(map, :source)) -> {:error, "source is required"}
          true -> {:ok, new(map)}
        end

      error ->
        error
    end
  rescue
    _ -> {:error, "invalid json"}
  end

  def decode(_), do: {:error, "invalid input"}

  def from_bus_event(%{} = event) do
    event_name =
      get_attr(event, :event) ||
        get_attr(event, :type) ||
        "event"

    session_id = get_attr(event, :session_id, "unknown")
    subject = get_attr(event, :subject)

    data =
      event
      |> Map.drop([:event, "event", :session_id, "session_id", :subject, "subject"])

    new(%{
      type: normalize_type(event_name),
      source: "urn:osa:agent:#{session_id || "unknown"}",
      subject: subject,
      data: data
    })
  end

  def from_bus_event(_), do: new(%{type: "com.osa.event", source: "urn:osa:agent:unknown"})

  def to_bus_event(%__MODULE__{} = event) do
    event_name =
      event.type
      |> to_string()
      |> String.replace_prefix("com.osa.", "")
      |> String.to_atom()

    base =
      %{event: event_name, source: event.source}
      |> maybe_put(:subject, event.subject)

    case event.data do
      %{} = data -> Map.merge(base, data)
      nil -> base
      data -> Map.put(base, :data, data)
    end
  end

  def to_bus_event(_), do: %{}

  defp fetch_required!(attrs, key) do
    case get_attr(attrs, key) do
      nil -> raise(KeyError, key: key, term: attrs)
      value -> value
    end
  end

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_type(type) when is_atom(type), do: "com.osa.#{type}"

  defp normalize_type(type) when is_binary(type) do
    if String.starts_with?(type, "com.osa.") do
      type
    else
      "com.osa.#{type}"
    end
  end

  defp generate_id do
    timestamp = System.system_time(:microsecond)
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "evt_#{timestamp}_#{suffix}"
  end
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
  @moduledoc """
  Signal Theory message classification result struct + classifier.

  `classify_fast/2` is backed by an ETS cache (`:daemon_signal_cache`)
  that stores results keyed by the SHA-256 hash of the message.
  Entries expire after 10 minutes.
  """

  defstruct [
    :mode,
    :genre,
    :type,
    :format,
    :weight,
    :raw,
    :channel,
    :timestamp,
    :confidence
  ]

  @type t :: %__MODULE__{}

  @cache_table :daemon_signal_cache
  @ttl_ms :timer.minutes(10)

  # -- ETS helpers (lazy init, no GenServer needed) ---------------------------

  defp ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true
          ])
        rescue
          ArgumentError -> @cache_table
        end

      _ref ->
        @cache_table
    end
  end

  defp cache_key(message), do: :crypto.hash(:sha256, message)

  # -- Public API -------------------------------------------------------------

  @doc "Fast ETS-cached classification (10-min TTL, keyed by SHA-256)."
  def classify_fast(message, channel) when is_binary(message) do
    ensure_cache()
    key = cache_key(message)

    case :ets.lookup(@cache_table, key) do
      [{^key, result, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < @ttl_ms do
          result
        else
          classify_and_cache(key, message, channel)
        end

      [] ->
        classify_and_cache(key, message, channel)
    end
  end

  def classify_fast(message, channel), do: classify_deterministic(message, channel)

  defp classify_and_cache(key, message, channel) do
    result = classify_deterministic(message, channel)
    :ets.insert(@cache_table, {key, result, System.monotonic_time(:millisecond)})
    result
  end

  @doc "Deterministic pattern-matching classification (no LLM)."
  def classify_deterministic(message, _channel) when is_binary(message) do
    msg = String.downcase(message)

    mode =
      cond do
        Regex.match?(~r/\b(run|execute|send|deploy|delete|trigger|sync|import|export)\b/, msg) ->
          :execute

        Regex.match?(
          ~r/\b(create|generate|write|scaffold|design|build|develop|make|implement)\b/,
          msg
        ) ->
          :build

        Regex.match?(~r/\b(analyze|report|compare|metrics|trend|dashboard|review|kpi)\b/, msg) ->
          :analyze

        Regex.match?(
          ~r/\b(fix|update|migrate|backup|restore|rollback|patch|upgrade|debug)\b/,
          msg
        ) ->
          :maintain

        true ->
          :assist
      end

    genre =
      cond do
        Regex.match?(~r/\b(please|can you|could you|do|make|create)\b/, msg) -> :direct
        Regex.match?(~r/\b(i will|i'll|let me|i can)\b/, msg) -> :commit
        Regex.match?(~r/\b(approve|reject|confirm|cancel|choose|decide)\b/, msg) -> :decide
        Regex.match?(~r/[!?]|great|thanks|thank you|sorry|frustrated/, msg) -> :express
        true -> :inform
      end

    weight = calculate_weight(message)

    {:ok,
     %__MODULE__{
       mode: mode,
       genre: genre,
       type: "general",
       format: :text,
       weight: weight,
       raw: message,
       channel: nil,
       timestamp: DateTime.utc_now(),
       confidence: :low
     }}
  end

  def classify_deterministic(_, _), do: {:error, :invalid_message}

  @doc "Calculate signal weight (0.0 - 1.0) based on message characteristics."
  def calculate_weight(message) when is_binary(message) do
    len = String.length(message)
    base = min(len / 500.0, 1.0)
    Float.round(base, 2)
  end

  def calculate_weight(_), do: 0.5
end

defmodule MiosaSignal.FailureModes do
  @moduledoc """
  Failure mode detection (breaks circular delegation with Daemon.Events.FailureModes).
  """

  @type failure_mode :: :doom_loop | :hallucination | :stall | :none

  @spec detect(map()) :: [{failure_mode(), String.t()}]
  def detect(%{} = event) do
    violations = []

    violations =
      if Map.get(event, :iteration, 0) > 10,
        do: [{:doom_loop, "iteration count exceeded 10"} | violations],
        else: violations

    violations =
      if Map.get(event, :consecutive_failures, 0) > 3,
        do: [{:stall, "consecutive failures exceeded 3"} | violations],
        else: violations

    violations
  end

  def detect(_), do: []

  def check(%{} = event, mode) when is_atom(mode) do
    event |> detect() |> Enum.any?(fn {m, _} -> m == mode end)
  end

  def check(_, _), do: false
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
  @moduledoc """
  Shim — provides a basic memory injection implementation.

  NOTE: The original circular delegation (Daemon.Agent.Memory.Injector →
  MiosaMemory.Injector → back) caused an infinite tail-call loop.
  This implementation breaks that cycle with a direct filter + format.
  """

  @type injection_context :: map()

  @always_inject [
    {:project_info, :workspace, 1.0},
    {:user_preference, :global, 0.95}
  ]

  @language_keywords %{
    ".ex" => ~w(elixir phoenix genserver ecto plug liveview mix supervisor),
    ".go" => ~w(go golang goroutine channel interface struct package),
    ".js" => ~w(javascript js react node npm async await),
    ".ts" => ~w(typescript ts interface type generic),
    ".py" => ~w(python django flask pytest pandas)
  }

  @doc "Filter taxonomy entries relevant to the given context."
  def inject_relevant(entries, context) when is_list(entries) do
    max_entries = Map.get(context, :max_entries, 10)
    max_tokens = Map.get(context, :max_tokens, :infinity)

    entries
    |> Enum.map(&score_entry(&1, context))
    |> Enum.reject(&(&1.relevance_score <= 0.0))
    |> Enum.sort_by(& &1.relevance_score, :desc)
    |> take_with_budget(max_entries, max_tokens)
  end

  def inject_relevant(_, _), do: []

  @doc "Format injected entries for inclusion in a prompt."
  def format_for_prompt([]), do: ""

  def format_for_prompt(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry ->
      content = Map.get(entry, :content, inspect(entry))
      category = Map.get(entry, :category, :general)
      scope = Map.get(entry, :scope, :workspace)
      "- [#{category}] [#{scope}] #{content}"
    end)
    |> Enum.join("\n")
  end

  def format_for_prompt(_), do: ""

  defp score_entry(entry, context) do
    score =
      entry
      |> always_inject_score()
      |> Kernel.+(scope_score(entry, context))
      |> Kernel.+(file_score(Map.get(entry, :content, ""), Map.get(context, :files, [])))
      |> Kernel.+(keyword_score(Map.get(entry, :content, ""), Map.get(context, :task_type)))
      |> Kernel.+(keyword_overlap_score(Map.get(entry, :content, ""), Map.get(context, :task)))
      |> Kernel.+(keyword_overlap_score(Map.get(entry, :content, ""), Map.get(context, :error)))
      |> min(1.0)

    Map.put(entry, :relevance_score, score)
  end

  defp always_inject_score(entry) do
    category = Map.get(entry, :category)
    scope = Map.get(entry, :scope)

    Enum.find_value(@always_inject, 0.0, fn
      {^category, ^scope, score} -> score
      _ -> false
    end)
  end

  defp scope_score(entry, context) do
    case {Map.get(entry, :scope), Map.get(entry, :metadata, %{}), Map.get(context, :session_id)} do
      {:global, _, _} -> 0.15
      {:workspace, _, _} -> 0.1
      {:session, %{session_id: session_id}, session_id} when is_binary(session_id) -> 0.55
      {:session, _, nil} -> 0.02
      {:session, _, _} -> 0.0
      _ -> 0.0
    end
  end

  defp file_score(_content, []), do: 0.0

  defp file_score(content, files) when is_list(files) do
    content_downcase = String.downcase(content)

    Enum.reduce(files, 0.0, fn file, acc ->
      basename = file |> Path.basename() |> String.downcase()
      ext = Path.extname(file)

      basename_score =
        if basename != "" and String.contains?(content_downcase, basename) do
          0.45
        else
          0.0
        end

      language_score =
        @language_keywords
        |> Map.get(ext, [])
        |> Enum.any?(fn keyword -> String.contains?(content_downcase, keyword) end)
        |> if(do: 0.35, else: 0.0)

      max(acc, basename_score + language_score)
    end)
  end

  defp keyword_score(_content, nil), do: 0.0

  defp keyword_score(content, keyword) when is_binary(keyword) do
    if String.contains?(String.downcase(content), String.downcase(keyword)) do
      0.35
    else
      0.0
    end
  end

  defp keyword_overlap_score(_content, nil), do: 0.0

  defp keyword_overlap_score(content, text) when is_binary(text) do
    overlap =
      content
      |> keywords()
      |> MapSet.intersection(keywords(text))
      |> MapSet.size()

    min(overlap * 0.15, 0.45)
  end

  defp keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_\.]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp take_with_budget(entries, max_entries, max_tokens) do
    {selected, _tokens} =
      Enum.reduce_while(entries, {[], 0}, fn entry, {acc, used_tokens} ->
        next_count = length(acc) + 1
        next_tokens = used_tokens + estimate_tokens(entry)

        cond do
          next_count > max_entries ->
            {:halt, {acc, used_tokens}}

          max_tokens != :infinity and next_tokens > max_tokens and acc != [] ->
            {:halt, {acc, used_tokens}}

          true ->
            {:cont, {[entry | acc], next_tokens}}
        end
      end)

    Enum.reverse(selected)
  end

  defp estimate_tokens(entry) do
    entry
    |> Map.get(:content, "")
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end
end

defmodule MiosaMemory.Taxonomy do
  @moduledoc """
  Memory taxonomy implementation (breaks circular delegation with Daemon.Agent.Memory.Taxonomy).
  """

  @type t :: map()
  @type category ::
          :pattern
          | :solution
          | :fact
          | :preference
          | :project_info
          | :user_preference
          | :context
          | :lesson
          | :general
  @type scope :: :workspace | :session | :global

  @categories [
    :pattern,
    :solution,
    :fact,
    :preference,
    :project_info,
    :user_preference,
    :context,
    :lesson,
    :general
  ]
  @scopes [:workspace, :session, :global]

  def new(content, opts \\ []) do
    %{
      content: to_string(content),
      category: Keyword.get(opts, :category, :general),
      scope: Keyword.get(opts, :scope, :workspace),
      metadata: Keyword.get(opts, :metadata, %{}),
      relevance_score: Keyword.get(opts, :relevance_score, 0.0),
      created_at: DateTime.utc_now(),
      accessed_at: DateTime.utc_now()
    }
  end

  def categorize(content) when is_binary(content) do
    cond do
      String.contains?(content, "->") -> :solution
      String.contains?(content, ":") and String.contains?(content, "count") -> :pattern
      true -> :general
    end
  end

  def categorize(_), do: :general

  def filter_by(entries, filters) when is_list(entries) and is_list(filters) do
    Enum.filter(entries, fn entry ->
      Enum.all?(filters, fn
        {:category, cat} -> Map.get(entry, :category) == cat
        {:scope, scope} -> Map.get(entry, :scope) == scope
        _ -> true
      end)
    end)
  end

  def filter_by(entries, _), do: entries

  def categories, do: @categories
  def scopes, do: @scopes

  def touch(entry) when is_map(entry), do: %{entry | accessed_at: DateTime.utc_now()}
  def touch(entry), do: entry

  def valid_category?(cat), do: cat in @categories
  def valid_scope?(scope), do: scope in @scopes
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

  @daily_default_usd 50.0
  @monthly_default_usd 200.0
  @per_call_default_usd 5.0

  @pricing %{
    anthropic: %{input_per_million: 3.0, output_per_million: 15.0},
    openai: %{input_per_million: 5.0, output_per_million: 15.0},
    ollama: %{input_per_million: 0.0, output_per_million: 0.0},
    default: %{input_per_million: 1.0, output_per_million: 3.0}
  }

  # Public API

  def start_link(opts \\ []) do
    {name_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(name_opts, :name, __MODULE__))
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

  def calculate_cost(provider, tokens_in, tokens_out) do
    pricing = Map.get(@pricing, provider, @pricing.default)

    (tokens_in * pricing.input_per_million + tokens_out * pricing.output_per_million) / 1_000_000
  end

  def reset_daily do
    GenServer.cast(__MODULE__, :reset_daily)
  end

  def reset_monthly do
    GenServer.cast(__MODULE__, :reset_monthly)
  end

  # GenServer callbacks

  @impl true
  def init(opts) when is_list(opts) do
    state = %{
      daily_spent: 0.0,
      monthly_spent: 0.0,
      daily_limit:
        Keyword.get(
          opts,
          :daily_limit,
          Application.get_env(:daemon, :daily_budget_usd, @daily_default_usd)
        ),
      monthly_limit:
        Keyword.get(
          opts,
          :monthly_limit,
          Application.get_env(:daemon, :monthly_budget_usd, @monthly_default_usd)
        ),
      per_call_limit:
        Keyword.get(
          opts,
          :per_call_limit,
          Application.get_env(:daemon, :per_call_budget_usd, @per_call_default_usd)
        ),
      entries: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight()
    }

    {:ok, state}
  end

  def init(:ok), do: init([])

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
      per_call_limit: state.per_call_limit,
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
      provider: provider,
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cost: cost,
      session_id: session_id,
      recorded_at: DateTime.utc_now()
    }

    state = %{
      state
      | daily_spent: state.daily_spent + cost,
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

    {year, month} =
      if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}

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
  def handle_call(:balance, _from, s),
    do: {:reply, {:ok, %{balance: s.balance, reserved: s.reserved}}, s}

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
  def lookup(name), do: Registry.lookup(Vaos.Knowledge.Registry, name)
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

  def assert_many(store_ref, triples),
    do: Vaos.Knowledge.assert_many(extract_name(store_ref), triples)

  def retract(store_ref, triple), do: Vaos.Knowledge.retract(extract_name(store_ref), triple)

  def query(store_ref, pattern), do: Vaos.Knowledge.query(extract_name(store_ref), pattern)

  def query(store_ref, pattern, opts),
    do: Vaos.Knowledge.query(extract_name(store_ref), pattern, opts)

  def count(store_ref), do: Vaos.Knowledge.count(extract_name(store_ref))
  def count(store_ref, _pattern), do: Vaos.Knowledge.count(extract_name(store_ref))

  def sparql(store_ref, query_string),
    do: Vaos.Knowledge.sparql(extract_name(store_ref), query_string)
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

  defstruct mode: :assist,
            genre: :direct,
            type: :general,
            format: :text,
            weight: 0.5,
            content: "",
            metadata: %{}

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  def valid?(%__MODULE__{mode: m, genre: g, type: t, format: f})
      when m in [:execute, :build, :analyze, :maintain, :assist] and
             g in [:direct, :inform, :commit, :decide, :express] and
             t in [:question, :request, :issue, :scheduling, :summary, :report, :general] and
             f in [:text, :code, :json, :markdown, :binary],
      do: true

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

  def normalize({tool, params, context})
      when is_binary(tool) and is_map(params) and is_map(context) do
    case normalize(tool) do
      {:ok, inst} -> {:ok, %{inst | params: params, context: context}}
      err -> err
    end
  end

  def normalize({_tool, _params, context}) when not is_map(context),
    do: {:error, "context must be a map"}

  def normalize(%__MODULE__{} = inst) do
    cond do
      not is_binary(inst.tool) or String.trim(inst.tool) == "" ->
        {:error, "tool name cannot be empty"}

      not is_map(inst.params) ->
        {:error, "params must be a map"}

      not is_map(inst.context) ->
        {:error, "context must be a map"}

      true ->
        {:ok, inst}
    end
  end

  def normalize(other), do: {:error, "Cannot normalize #{inspect(other)}"}

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

  @spec execute(Instruction.t(), [module() | {module(), keyword()}], (Instruction.t() -> any())) ::
          any()
  def execute(%Instruction{} = inst, [], executor), do: executor.(inst)

  def execute(%Instruction{} = inst, [mw | rest], executor) do
    {module, opts} =
      case mw do
        {module, opts} when is_list(opts) -> {module, opts}
        module -> {module, []}
      end

    module.call(inst, fn updated -> execute(updated, rest, executor) end, opts)
  end

  defmodule Validation do
    @moduledoc "Validates that required params are present before executing."
    @behaviour MiosaTools.Middleware

    @impl true
    def call(instruction, next, opts) do
      cond do
        String.trim(instruction.tool) == "" ->
          {:error, "tool name is required"}

        true ->
          required = Keyword.get(opts, :required, [])
          missing = Enum.reject(required, &Map.has_key?(instruction.params, &1))

          if missing == [] do
            next.(instruction)
          else
            {:error, "missing required params: #{Enum.join(missing, ", ")}"}
          end
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
      _elapsed = System.monotonic_time(:microsecond) - start
      result
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
      Logger.debug("[MiosaTools] #{instruction.tool} -> #{inspect(result)}")
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

  @spec pipe([term()], keyword()) :: {:ok, map()} | {:error, any()}
  def pipe(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)
    transform = Keyword.get(opts, :transform, fn result, params -> Map.merge(params, result) end)

    Enum.reduce_while(instructions, {:ok, %{}}, fn raw, {:ok, acc} ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          params = Map.merge(acc, inst.params)

          case executor.(inst.tool, params) do
            {:ok, result} -> {:cont, {:ok, transform.(result, params)}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @spec parallel([term()], keyword()) :: {:ok, map()} | {:error, map()}
  def parallel(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    instructions
    |> Task.async_stream(&run_parallel_instruction(&1, executor), timeout: 30_000, ordered: true)
    |> Enum.reduce({%{}, %{}}, fn
      {:ok, {:ok, tool, result}}, {results, errors} ->
        {Map.put(results, tool, result), errors}

      {:ok, {:error, tool, error}}, {results, errors} ->
        {results, Map.put(errors, tool, error)}

      {:exit, error}, {results, errors} ->
        {results, Map.put(errors, "task_exit", error)}
    end)
    |> case do
      {results, errors} when map_size(errors) == 0 -> {:ok, results}
      {_results, errors} -> {:error, errors}
    end
  end

  @spec fallback([term()], keyword()) :: {:ok, map()} | {:error, any()}
  def fallback(instructions, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)

    Enum.reduce_while(instructions, {:error, "no instructions"}, fn raw, _acc ->
      case Instruction.normalize(raw) do
        {:ok, inst} ->
          case executor.(inst.tool, inst.params) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = err -> {:cont, err}
          end

        {:error, _} = err ->
          {:cont, err}
      end
    end)
  end

  @spec retry(term(), keyword()) :: {:ok, map()} | {:error, any()}
  def retry(instruction, opts \\ []) do
    executor = Keyword.get(opts, :executor, fn _tool, params -> {:ok, params} end)
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_backoff = Keyword.get(opts, :base_backoff, 10)
    max_backoff = Keyword.get(opts, :max_backoff, base_backoff)
    should_retry = Keyword.get(opts, :should_retry, fn _error -> true end)

    with {:ok, inst} <- Instruction.normalize(instruction) do
      do_retry(inst, executor, should_retry, 1, max_attempts, base_backoff, max_backoff)
    end
  end

  defp run_parallel_instruction(raw, executor) do
    case Instruction.normalize(raw) do
      {:ok, inst} ->
        case executor.(inst.tool, inst.params) do
          {:ok, result} -> {:ok, inst.tool, result}
          {:error, error} -> {:error, inst.tool, error}
        end

      {:error, error} ->
        {:error, inspect(raw), error}
    end
  end

  defp do_retry(inst, executor, should_retry, attempt, max_attempts, base_backoff, max_backoff) do
    case executor.(inst.tool, inst.params) do
      {:ok, _} = ok ->
        ok

      {:error, error} = failure ->
        cond do
          attempt >= max_attempts ->
            failure

          not should_retry.(error) ->
            failure

          true ->
            backoff = min(trunc(base_backoff * :math.pow(2, attempt - 1)), max_backoff)
            Process.sleep(backoff)

            do_retry(
              inst,
              executor,
              should_retry,
              attempt + 1,
              max_attempts,
              base_backoff,
              max_backoff
            )
        end
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
  defdelegate normalize_base_url(base_url), to: Daemon.Providers.Anthropic
  defdelegate response_error(body), to: Daemon.Providers.Anthropic
  defdelegate available_models(), to: Daemon.Providers.Anthropic
  defdelegate default_model(), to: Daemon.Providers.Anthropic
end

defmodule MiosaProviders.Behaviour do
  @moduledoc "Shim — re-exports Daemon.Providers.Behaviour."
  defdelegate __using__(opts), to: Daemon.Providers.Behaviour
end
