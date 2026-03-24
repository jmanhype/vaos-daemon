defmodule OptimalSystemAgent.Vault.FactStore do
  @moduledoc """
  Persistent fact store with temporal versioning.

  Facts are stored in ETS for fast reads and persisted to a JSONL file.
  When a fact is superseded, it gets a `valid_until` timestamp but is
  never deleted — maintaining full history.

  Architecture: ETS for reads (concurrent), GenServer for writes (serialized),
  JSONL for persistence — same pattern as Hooks/Tools.
  """
  use GenServer
  require Logger

  @ets_table :osa_vault_facts
  @jsonl_filename "facts.jsonl"

  defstruct [:jsonl_path]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store a new fact. Supersedes any existing fact with the same type+value."
  @spec store(map()) :: :ok
  def store(fact) when is_map(fact) do
    GenServer.cast(__MODULE__, {:store, fact})
  end

  @doc "Get all active (non-superseded) facts."
  @spec active_facts() :: [map()]
  def active_facts do
    try do
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_key, fact} -> fact end)
      |> Enum.filter(&is_nil(&1[:valid_until]))
      |> Enum.sort_by(& &1[:stored_at], :desc)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Get all facts (including superseded) for a given type."
  @spec facts_by_type(String.t()) :: [map()]
  def facts_by_type(type) do
    try do
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_key, fact} -> fact end)
      |> Enum.filter(&(&1[:type] == type))
      |> Enum.sort_by(& &1[:stored_at], :desc)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Search facts by value substring."
  @spec search(String.t()) :: [map()]
  def search(query) do
    query_lower = String.downcase(query)

    active_facts()
    |> Enum.filter(fn fact ->
      String.contains?(String.downcase(fact[:value] || ""), query_lower)
    end)
  end

  @doc "Count of active facts."
  @spec count() :: non_neg_integer()
  def count do
    length(active_facts())
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    table = :ets.new(@ets_table, [:set, :named_table, :public, read_concurrency: true])

    vault_dir = Keyword.get(opts, :vault_dir) || vault_internal_dir()
    File.mkdir_p!(vault_dir)
    jsonl_path = Path.join(vault_dir, @jsonl_filename)

    # Load existing facts from JSONL
    load_from_jsonl(jsonl_path, table)

    {:ok, %__MODULE__{jsonl_path: jsonl_path}}
  end

  @impl true
  def handle_cast({:store, fact}, state) do
    fact_id = generate_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    enriched =
      Map.merge(fact, %{
        id: fact_id,
        stored_at: now,
        valid_until: nil
      })

    # Supersede existing facts with same type+value
    supersede_matching(enriched)

    # Store in ETS
    :ets.insert(@ets_table, {fact_id, enriched})

    # Append to JSONL
    append_jsonl(state.jsonl_path, enriched)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # --- Private ---

  defp vault_internal_dir do
    config_dir = Application.get_env(:optimal_system_agent, :config_dir, "~/.osa")
    Path.expand(Path.join([config_dir, "vault", ".vault"]))
  end

  defp load_from_jsonl(path, table) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case Jason.decode(line) do
            {:ok, fact} ->
              id = fact["id"] || generate_id()
              # Convert string keys to atom keys for internal consistency
              atom_fact = for {k, v} <- fact, into: %{} do
        atom_key = try do
          String.to_existing_atom(k)
        rescue
          ArgumentError -> String.to_atom(k)
        end
        {atom_key, v}
      end
              :ets.insert(table, {id, atom_fact})

            {:error, _} ->
              Logger.debug("[vault/fact_store] Skipping malformed JSONL line")
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[vault/fact_store] Failed to load JSONL: #{inspect(reason)}")
    end
  end

  defp append_jsonl(path, fact) do
    line = Jason.encode!(fact) <> "\n"
    File.write(path, line, [:append])
  end

  defp supersede_matching(%{type: type, value: value}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :ets.tab2list(@ets_table)
    |> Enum.each(fn {id, fact} ->
      if fact[:type] == type and fact[:value] == value and is_nil(fact[:valid_until]) do
        updated = Map.put(fact, :valid_until, now)
        :ets.insert(@ets_table, {id, updated})
      end
    end)
  end

  defp supersede_matching(_fact), do: :ok

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
