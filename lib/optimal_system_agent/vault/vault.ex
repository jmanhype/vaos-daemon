defmodule OptimalSystemAgent.Vault do
  @moduledoc """
  Facade API for the OSA Vault structured memory system.

  Provides a clean interface over the vault subsystem:
  - `remember/3` — store a memory with automatic fact extraction
  - `recall/2` — search vault memories
  - `context/2` — build profiled context for prompt injection
  - `wake/1`, `sleep/2`, `checkpoint/1` — session lifecycle
  - `inject/1` — keyword-matched prompt injection
  """

  alias OptimalSystemAgent.Vault.{
    Store,
    Category,
    FactExtractor,
    FactStore,
    Observer,
    ContextProfile,
    SessionLifecycle,
    Inject
  }

  @doc """
  Store a memory with automatic fact extraction.

  Writes a markdown file to the appropriate category directory and
  extracts/stores any facts found in the content.
  """
  @spec remember(String.t(), Category.t() | String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def remember(content, category \\ :fact, opts \\ %{}) do
    cat = normalize_category(category)
    title = Map.get(opts, :title) || generate_title(content)

    # Write to store
    result = Store.write(cat, title, content, opts)

    # Extract and store facts
    facts = FactExtractor.extract(content)
    Enum.each(facts, &FactStore.store/1)

    # Buffer as observation
    Observer.observe(content, session_id: Map.get(opts, :session_id))

    result
  end

  @doc "Search vault memories."
  @spec recall(String.t(), keyword()) :: [{Category.t(), String.t(), float()}]
  def recall(query, opts \\ []) do
    Store.search(query, opts)
  end

  @doc "Build profiled context for prompt injection."
  @spec context(ContextProfile.profile(), keyword()) :: String.t()
  def context(profile \\ :default, opts \\ []) do
    ContextProfile.build(profile, opts)
  end

  @doc "Session wake — call at session start."
  @spec wake(String.t()) :: {:ok, :clean | :recovered}
  def wake(session_id), do: SessionLifecycle.wake(session_id)

  @doc "Session sleep — call at clean session end."
  @spec sleep(String.t(), map()) :: :ok
  def sleep(session_id, context \\ %{}), do: SessionLifecycle.sleep(session_id, context)

  @doc "Mid-session checkpoint."
  @spec checkpoint(String.t()) :: :ok
  def checkpoint(session_id), do: SessionLifecycle.checkpoint(session_id)

  @doc "Keyword-matched prompt injection."
  @spec inject(String.t()) :: String.t()
  def inject(message), do: Inject.auto_inject(message)

  @doc "Initialize vault directory structure."
  @spec init() :: :ok
  def init, do: Store.init()

  # --- Private ---

  defp normalize_category(cat) when is_atom(cat), do: cat

  defp normalize_category(cat) when is_binary(cat) do
    case Category.parse(cat) do
      {:ok, c} -> c
      :error -> :fact
    end
  end

  defp generate_title(content) do
    content
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 60)
    |> String.trim()
    |> case do
      "" -> "untitled-#{System.unique_integer([:positive])}"
      title -> title
    end
  end
end
