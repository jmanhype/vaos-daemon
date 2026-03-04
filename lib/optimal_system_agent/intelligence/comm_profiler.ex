defmodule OptimalSystemAgent.Intelligence.CommProfiler do
  @moduledoc """
  Learns communication patterns per contact over time.
  Builds an incremental profile: preferred length, formality level,
  technical depth, and a rolling score history.

  Profiles are stored in ETS (`:osa_comm_profiles`) so they survive
  GenServer crashes and are accessible without going through the process
  for reads.

  Signal Theory — adaptive communication profiling.
  """
  use GenServer
  require Logger

  @table :osa_comm_profiles

  # ---------------------------------------------------------------------------
  # Default profile shape
  # ---------------------------------------------------------------------------

  defp default_profile do
    %{
      preferred_length: :medium,  # :short | :medium | :long
      formality: :neutral,        # :casual | :neutral | :formal
      technical_depth: :moderate, # :simple | :moderate | :expert
      avg_score: 0.7,
      avg_length: 0,
      message_count: 0,
      score_history: []           # last 10 scores (newest first)
    }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Get the communication profile for a user. Returns {:ok, profile}."
  def get_profile(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, profile}] -> {:ok, profile}
      [] -> {:ok, default_profile()}
    end
  end

  @doc "Update a profile after observing a new interaction."
  def update_profile(user_id, attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:update_profile, user_id, attrs})
  end

  @doc "Record a raw message from a user to update their profile."
  def record(user_id, message) do
    GenServer.cast(__MODULE__, {:record, user_id, message})
  end

  @doc """
  Returns the score trend over the last 10 messages for `user_id`.
  Result is a list of floats, newest first. Returns {:ok, []} when no history.
  """
  def communication_trend(user_id) do
    case get_profile(user_id) do
      {:ok, %{score_history: history}} -> {:ok, history}
      _ -> {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.debug("[CommProfiler] ETS table #{@table} created")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, user_id, message}, state) do
    {:ok, profile} = get_profile(user_id)
    updated = do_record(profile, message)
    :ets.insert(@table, {user_id, updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_profile, user_id, attrs}, state) do
    {:ok, profile} = get_profile(user_id)
    updated = merge_attrs(profile, attrs)
    :ets.insert(@table, {user_id, updated})
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal: record a raw message
  # ---------------------------------------------------------------------------

  defp do_record(profile, message) do
    count = profile.message_count + 1
    len = String.length(message)
    avg_len = (profile.avg_length * profile.message_count + len) / count

    formality_score = estimate_formality_score(message)
    technical_score = estimate_technical_score(message)

    preferred_length = classify_length(avg_len)
    formality_atom = classify_formality(formality_score, profile, count)
    technical_depth = classify_technical(technical_score, profile, count)

    %{profile |
      message_count: count,
      avg_length: round(avg_len),
      preferred_length: preferred_length,
      formality: formality_atom,
      technical_depth: technical_depth
    }
  end

  # ---------------------------------------------------------------------------
  # Internal: merge explicit attrs (called from update_profile/2)
  # ---------------------------------------------------------------------------

  defp merge_attrs(profile, attrs) do
    # Handle score history update
    profile =
      case Map.fetch(attrs, :score) do
        {:ok, score} when is_float(score) or is_integer(score) ->
          history = [Float.round(score * 1.0, 3) | Enum.take(profile.score_history, 9)]
          avg = Enum.sum(history) / length(history)
          %{profile | score_history: history, avg_score: Float.round(avg, 3)}

        _ ->
          profile
      end

    # Merge other known attrs directly
    Enum.reduce(attrs, profile, fn
      {:score, _}, acc -> acc  # already handled above
      {key, value}, acc when is_map_key(acc, key) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  # ---------------------------------------------------------------------------
  # Heuristics
  # ---------------------------------------------------------------------------

  defp estimate_formality_score(message) do
    lower = String.downcase(message)
    formal_markers = ~w(please kindly regarding therefore furthermore additionally
                        pursuant henceforth accordingly herewith sincerely)
    informal_markers = ~w(lol haha yeah nah gonna wanna kinda sorta yo sup bruh
                          hey tbh idk omg lmao wtf u r ur gonna)

    formal_count = Enum.count(formal_markers, &String.contains?(lower, &1))
    informal_count = Enum.count(informal_markers, &String.contains?(lower, &1))

    score = 0.5 + formal_count * 0.1 - informal_count * 0.1
    max(0.0, min(1.0, score))
  end

  defp estimate_technical_score(message) do
    lower = String.downcase(message)
    technical_terms = ~w(api endpoint regex function module struct protocol
                         async concurrent thread process memory buffer socket
                         deploy container kubernetes docker database query index)

    count = Enum.count(technical_terms, &String.contains?(lower, &1))
    words = max(1, length(String.split(lower, ~r/\W+/, trim: true)))
    density = count / words

    cond do
      density > 0.05 -> 0.9
      density > 0.02 -> 0.6
      true -> 0.3
    end
  end

  defp classify_length(avg_len) do
    cond do
      avg_len < 80 -> :short
      avg_len < 300 -> :medium
      true -> :long
    end
  end

  defp classify_formality(new_score, profile, count) do
    # Map existing atom to numeric for running average
    prev_numeric = formality_atom_to_float(profile.formality)
    running = (prev_numeric * (count - 1) + new_score) / count

    cond do
      running < 0.4 -> :casual
      running > 0.65 -> :formal
      true -> :neutral
    end
  end

  defp classify_technical(new_score, profile, count) do
    prev_numeric = technical_atom_to_float(profile.technical_depth)
    running = (prev_numeric * (count - 1) + new_score) / count

    cond do
      running < 0.35 -> :simple
      running > 0.65 -> :expert
      true -> :moderate
    end
  end

  defp formality_atom_to_float(:casual), do: 0.2
  defp formality_atom_to_float(:neutral), do: 0.5
  defp formality_atom_to_float(:formal), do: 0.8
  defp formality_atom_to_float(_), do: 0.5

  defp technical_atom_to_float(:simple), do: 0.2
  defp technical_atom_to_float(:moderate), do: 0.5
  defp technical_atom_to_float(:expert), do: 0.9
  defp technical_atom_to_float(_), do: 0.5
end
