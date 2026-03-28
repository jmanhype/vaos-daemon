defmodule Daemon.Agent.WorkDirector.Backlog do
  @moduledoc """
  WorkItem struct and backlog management for WorkDirector.

  The backlog is a `%{content_hash => WorkItem}` map. Items are deduped by
  content_hash (SHA256 of title + description). Thompson Sampling scores
  drive pick_next selection. Persistence via JSON to ~/.daemon/work_director/.
  """

  alias Daemon.Investigation.PromptSelector

  @persistence_dir Path.expand("~/.daemon/work_director")
  @persistence_file Path.join(@persistence_dir, "backlog.json")
  @cooldown_ms :timer.hours(4)
  @max_attempts 2
  @stale_ms :timer.hours(24)

  defmodule WorkItem do
    @moduledoc "A unit of work in the WorkDirector backlog."

    @type source :: :vision | :issues | :investigation | :fitness | :manual

    @type status :: :pending | :dispatched | :completed | :failed

    @type t :: %__MODULE__{
            id: String.t() | nil,
            content_hash: String.t(),
            source: source(),
            title: String.t(),
            description: String.t(),
            base_priority: float(),
            metadata: map(),
            created_at: DateTime.t() | nil,
            last_attempted_at: DateTime.t() | nil,
            attempt_count: non_neg_integer(),
            status: status(),
            pr_branch: String.t() | nil,
            result: term()
          }

    defstruct [
      :id,
      :content_hash,
      :source,
      :title,
      :description,
      base_priority: 0.5,
      metadata: %{},
      created_at: nil,
      last_attempted_at: nil,
      attempt_count: 0,
      status: :pending,
      pr_branch: nil,
      result: nil
    ]

    @doc "Create a WorkItem with auto-generated id and content_hash."
    @spec new(map()) :: t()
    def new(attrs) when is_map(attrs) do
      title = Map.get(attrs, :title, "")
      description = Map.get(attrs, :description, "")
      hash = content_hash(title, description)

      %__MODULE__{
        id: hash,
        content_hash: hash,
        source: Map.get(attrs, :source, :manual),
        title: title,
        description: description,
        base_priority: Map.get(attrs, :base_priority, 0.5),
        metadata: Map.get(attrs, :metadata, %{}),
        created_at: DateTime.utc_now()
      }
    end

    @doc "Compute SHA256 content hash for dedup."
    @spec content_hash(String.t(), String.t()) :: String.t()
    def content_hash(title, description) do
      :crypto.hash(:sha256, title <> "\n" <> description)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
    end
  end

  # -- Backlog operations --

  @doc "Merge new items into backlog. Preserves in-flight items, refreshes pending metadata."
  @spec merge(map(), [WorkItem.t()]) :: map()
  def merge(backlog, items) when is_map(backlog) and is_list(items) do
    Enum.reduce(items, backlog, fn item, acc ->
      case Map.get(acc, item.content_hash) do
        nil ->
          Map.put(acc, item.content_hash, item)

        %WorkItem{status: status} when status in [:dispatched] ->
          # Don't overwrite in-flight items
          acc

        %WorkItem{status: :pending} = existing ->
          # Refresh metadata but keep existing timestamps
          updated = %{existing | metadata: item.metadata, base_priority: item.base_priority}
          Map.put(acc, item.content_hash, updated)

        _completed_or_failed ->
          acc
      end
    end)
  end

  @doc """
  Pick the next best item to dispatch using Thompson Sampling.

  Filters eligible items (pending, < max attempts, not on cooldown),
  scores each as `base_priority * sample_beta(arm.alpha, arm.beta)`,
  returns the highest scored item.
  """
  @spec pick_next(map(), map()) :: {:ok, WorkItem.t()} | :empty
  def pick_next(backlog, arms) when is_map(backlog) and is_map(arms) do
    now = DateTime.utc_now()

    eligible =
      backlog
      |> Map.values()
      |> Enum.filter(&eligible?(&1, now))

    case eligible do
      [] ->
        :empty

      items ->
        scored =
          Enum.map(items, fn item ->
            arm = Map.get(arms, item.source, %{alpha: 1.0, beta: 1.0})
            thompson_score = PromptSelector.sample_beta(arm.alpha, arm.beta)
            score = item.base_priority * thompson_score
            {item, score}
          end)

        {best, _score} = Enum.max_by(scored, fn {_item, score} -> score end)
        {:ok, best}
    end
  end

  defp eligible?(%WorkItem{status: :pending, attempt_count: count} = item, now) do
    count < @max_attempts and not on_cooldown?(item, now)
  end

  defp eligible?(_item, _now), do: false

  defp on_cooldown?(%WorkItem{last_attempted_at: nil}, _now), do: false

  defp on_cooldown?(%WorkItem{last_attempted_at: last}, now) do
    DateTime.diff(now, last, :millisecond) < @cooldown_ms
  end

  @doc "Mark an item as dispatched with a branch name."
  @spec mark_dispatched(map(), String.t(), String.t()) :: map()
  def mark_dispatched(backlog, content_hash, branch) do
    update_item(backlog, content_hash, fn item ->
      %{item |
        status: :dispatched,
        pr_branch: branch,
        last_attempted_at: DateTime.utc_now(),
        attempt_count: item.attempt_count + 1
      }
    end)
  end

  @doc "Mark an item as completed with a result."
  @spec mark_completed(map(), String.t(), term()) :: map()
  def mark_completed(backlog, content_hash, result) do
    update_item(backlog, content_hash, fn item ->
      %{item | status: :completed, result: result}
    end)
  end

  @doc "Mark an item as failed."
  @spec mark_failed(map(), String.t()) :: map()
  def mark_failed(backlog, content_hash) do
    update_item(backlog, content_hash, fn item ->
      %{item | status: :failed}
    end)
  end

  defp update_item(backlog, content_hash, fun) do
    case Map.get(backlog, content_hash) do
      nil -> backlog
      item -> Map.put(backlog, content_hash, fun.(item))
    end
  end

  @doc "Remove completed/failed items older than 24 hours."
  @spec prune_stale(map()) :: map()
  def prune_stale(backlog) do
    now = DateTime.utc_now()

    Map.filter(backlog, fn {_hash, item} ->
      case item.status do
        status when status in [:completed, :failed] ->
          DateTime.diff(now, item.created_at, :millisecond) < @stale_ms

        _ ->
          true
      end
    end)
  end

  # -- Persistence --

  @doc "Persist backlog to disk as JSON."
  @spec persist(map()) :: :ok | {:error, term()}
  def persist(backlog) do
    File.mkdir_p!(@persistence_dir)

    items =
      backlog
      |> Map.values()
      |> Enum.map(&serialize_item/1)

    case Jason.encode(%{version: 1, items: items}, pretty: true) do
      {:ok, json} -> File.write(@persistence_file, json)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load backlog from disk."
  @spec load() :: map()
  def load do
    case File.read(@persistence_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"version" => 1, "items" => items}} ->
            items
            |> Enum.map(&deserialize_item/1)
            |> Enum.reject(&is_nil/1)
            |> Map.new(fn item -> {item.content_hash, item} end)

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp serialize_item(%WorkItem{} = item) do
    %{
      "id" => item.id,
      "content_hash" => item.content_hash,
      "source" => to_string(item.source),
      "title" => item.title,
      "description" => item.description,
      "base_priority" => item.base_priority,
      "metadata" => item.metadata,
      "created_at" => item.created_at && DateTime.to_iso8601(item.created_at),
      "last_attempted_at" => item.last_attempted_at && DateTime.to_iso8601(item.last_attempted_at),
      "attempt_count" => item.attempt_count,
      "status" => to_string(item.status),
      "pr_branch" => item.pr_branch
    }
  end

  defp deserialize_item(data) when is_map(data) do
    try do
      %WorkItem{
        id: data["id"],
        content_hash: data["content_hash"],
        source: String.to_existing_atom(data["source"]),
        title: data["title"] || "",
        description: data["description"] || "",
        base_priority: data["base_priority"] || 0.5,
        metadata: data["metadata"] || %{},
        created_at: parse_datetime(data["created_at"]),
        last_attempted_at: parse_datetime(data["last_attempted_at"]),
        attempt_count: data["attempt_count"] || 0,
        status: String.to_existing_atom(data["status"] || "pending"),
        pr_branch: data["pr_branch"]
      }
    rescue
      _ -> nil
    end
  end

  defp deserialize_item(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
