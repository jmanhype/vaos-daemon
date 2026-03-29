defmodule Daemon.Agent.WorkDirector.Source do
  @moduledoc """
  Source behaviour and adapters for WorkDirector backlog population.

  Five sources feed the backlog:
  - VisionSource — strategic goals from VISION.md
  - IssuesSource — open GitHub issues
  - InvestigationSource — event-driven findings buffer
  - FitnessSource — fitness function violations
  - ManualSource — human-submitted tasks
  """

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @callback source_id() :: atom()
  @callback fetch() :: {:ok, [WorkItem.t()]} | {:error, term()}

  @doc "Fetch from all sources, collecting results and logging errors."
  @spec fetch_all([module()]) :: [WorkItem.t()]
  def fetch_all(sources) do
    Enum.flat_map(sources, fn mod ->
      try do
        case mod.fetch() do
          {:ok, items} -> items
          {:error, _reason} -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end)
  end
end

defmodule Daemon.Agent.WorkDirector.Source.Vision do
  @moduledoc "Parses VISION.md for unchecked goals."
  @behaviour Daemon.Agent.WorkDirector.Source

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @vision_path Path.expand("~/.daemon/VISION.md")

  @section_priorities %{
    "product goals" => 0.9,
    "architecture goals" => 0.7,
    "tech debt" => 0.5
  }

  @impl true
  def source_id, do: :vision

  @impl true
  def fetch do
    case File.read(@vision_path) do
      {:ok, content} ->
        items = parse_vision(content)
        {:ok, items}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:vision_read, reason}}
    end
  end

  defp parse_vision(content) do
    lines = String.split(content, "\n")

    {items, _section} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, current_section} ->
        cond do
          # Section header
          String.match?(line, ~r/^\#{1,3}\s+/) ->
            section = line |> String.replace(~r/^#+\s+/, "") |> String.downcase() |> String.trim()
            {acc, section}

          # Unchecked checkbox
          String.match?(line, ~r/^\s*-\s*\[\s\]/) ->
            title = String.replace(line, ~r/^\s*-\s*\[\s\]\s*/, "") |> String.trim()

            if title != "" do
              priority = section_priority(current_section)

              item =
                WorkItem.new(%{
                  source: :vision,
                  title: title,
                  description: "From VISION.md section: #{current_section || "unknown"}",
                  base_priority: priority,
                  metadata: %{"section" => current_section}
                })

              {[item | acc], current_section}
            else
              {acc, current_section}
            end

          # Continuation line (indented text after a checkbox) — append to last item's description
          String.match?(line, ~r/^\s{2,}/) and acc != [] ->
            continuation = String.trim(line)

            if continuation != "" do
              [last | rest] = acc
              updated = %{last | description: last.description <> "\n" <> continuation}
              {[updated | rest], current_section}
            else
              {acc, current_section}
            end

          true ->
            {acc, current_section}
        end
      end)

    Enum.reverse(items)
  end

  defp section_priority(nil), do: 0.3

  defp section_priority(section) do
    Enum.find_value(@section_priorities, 0.3, fn {key, priority} ->
      if String.contains?(section, key), do: priority
    end)
  end

  @doc "Parse architectural invariants from VISION.md."
  def load_invariants do
    case File.read(@vision_path) do
      {:ok, content} -> parse_invariants(content)
      _ -> []
    end
  end

  defp parse_invariants(content) do
    lines = String.split(content, "\n")

    {items, _in_section} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_inv} ->
        cond do
          Regex.match?(~r/^\#{1,3}\s+.*[Ii]nvariants/i, line) -> {acc, true}
          in_inv and Regex.match?(~r/^\#{1,3}\s+/, line) -> {acc, false}
          in_inv and Regex.match?(~r/^\s*-\s+/, line) ->
            inv = String.replace(line, ~r/^\s*-\s+/, "") |> String.trim()
            if inv != "", do: {[inv | acc], true}, else: {acc, true}
          true -> {acc, in_inv}
        end
      end)

    Enum.reverse(items)
  end
end

defmodule Daemon.Agent.WorkDirector.Source.Issues do
  @moduledoc "Fetches open GitHub issues from vaos-daemon repo."
  @behaviour Daemon.Agent.WorkDirector.Source

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @daemon_repo "jmanhype/vaos-daemon"

  @label_priorities %{
    "bug" => 0.8,
    "priority:high" => 0.8,
    "priority:critical" => 0.9,
    "enhancement" => 0.6,
    "priority:medium" => 0.6,
    "priority:low" => 0.4
  }

  @impl true
  def source_id, do: :issues

  @impl true
  def fetch do
    args = [
      "issue", "list",
      "--repo", @daemon_repo,
      "--json", "number,title,body,labels",
      "--limit", "20",
      "--state", "open"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, issues} ->
            items = Enum.map(issues, &issue_to_item/1)
            {:ok, items}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {error, _code} ->
        {:error, {:gh_cli, String.trim(error)}}
    end
  end

  defp issue_to_item(issue) do
    labels = issue["labels"] || []
    label_names = Enum.map(labels, fn l -> l["name"] || "" end)
    priority = max_label_priority(label_names)
    number = issue["number"]

    WorkItem.new(%{
      source: :issues,
      title: issue["title"] || "Issue ##{number}",
      description: issue["body"] || "",
      base_priority: priority,
      metadata: %{"number" => number, "labels" => label_names}
    })
  end

  defp max_label_priority(label_names) do
    priorities =
      Enum.map(label_names, fn name ->
        Map.get(@label_priorities, String.downcase(name), 0.5)
      end)

    case priorities do
      [] -> 0.5
      p -> Enum.max(p)
    end
  end
end

defmodule Daemon.Agent.WorkDirector.Source.Investigation do
  @moduledoc """
  Event-driven buffer for investigation findings.

  WorkDirector registers a handler on :investigation_complete events at bootstrap.
  This module manages the Agent-based buffer that collects findings between fetch cycles.
  """
  @behaviour Daemon.Agent.WorkDirector.Source

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @quality_threshold 0.4

  @impl true
  def source_id, do: :investigation

  @doc "Start the buffer Agent. Returns {:ok, pid}."
  @spec start_buffer() :: {:ok, pid()}
  def start_buffer do
    Agent.start_link(fn -> [] end)
  end

  @doc "Push a finding into the buffer (called from event handler)."
  @spec push(pid(), map()) :: :ok
  def push(buffer, finding) when is_map(finding) do
    quality = Map.get(finding, :quality, Map.get(finding, "quality", 0.0))

    if quality >= @quality_threshold do
      topic = Map.get(finding, :topic, Map.get(finding, "topic", "investigation finding"))
      summary = Map.get(finding, :summary, Map.get(finding, "summary", ""))

      item =
        WorkItem.new(%{
          source: :investigation,
          title: "Investigation: #{topic}",
          description: summary,
          base_priority: quality * 0.7,
          metadata: %{"quality" => quality, "topic" => topic}
        })

      Agent.update(buffer, fn items -> [item | items] end)
    else
      :ok
    end
  end

  @doc "Drain the buffer, returning all accumulated items."
  @spec drain(pid()) :: [WorkItem.t()]
  def drain(buffer) do
    Agent.get_and_update(buffer, fn items -> {items, []} end)
  end

  @impl true
  def fetch do
    # fetch/0 is not used directly — WorkDirector calls drain/1 on the buffer pid
    {:ok, []}
  end

  @doc "Fetch by draining a specific buffer pid."
  @spec fetch(pid()) :: {:ok, [WorkItem.t()]}
  def fetch(buffer) do
    {:ok, drain(buffer)}
  end
end

defmodule Daemon.Agent.WorkDirector.Source.Fitness do
  @moduledoc "Maps fitness function violations to work items."
  @behaviour Daemon.Agent.WorkDirector.Source

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @impl true
  def source_id, do: :fitness

  @impl true
  def fetch do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    results =
      try do
        Daemon.Fitness.evaluate_all(repo_path)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Apply frozen filter per-result (ratchet: only surface NEW violations)
    filtered =
      Enum.map(results, fn {name, result} ->
        filtered_result =
          try do
            Daemon.Fitness.apply_frozen_filter(name, result)
          rescue
            _ -> result
          catch
            :exit, _ -> result
          end

        {name, filtered_result}
      end)

    items =
      filtered
      |> Enum.filter(fn {_name, {status, _score, _detail}} -> status == :not_kept end)
      |> Enum.map(fn {name, {_status, _score, detail}} ->
        WorkItem.new(%{
          source: :fitness,
          title: "Fitness violation: #{name}",
          description: detail,
          base_priority: 0.8,
          metadata: %{"fitness_name" => name}
        })
      end)

    {:ok, items}
  end
end

defmodule Daemon.Agent.WorkDirector.Source.Manual do
  @moduledoc """
  Agent-based buffer for manually submitted work items.

  Exposed via WorkDirector.submit/3.
  """
  @behaviour Daemon.Agent.WorkDirector.Source

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem

  @impl true
  def source_id, do: :manual

  @doc "Start the manual submission buffer."
  @spec start_buffer() :: {:ok, pid()}
  def start_buffer do
    Agent.start_link(fn -> [] end)
  end

  @doc "Submit a manual work item."
  @spec submit(pid(), String.t(), String.t(), float()) :: :ok
  def submit(buffer, title, description, priority \\ 0.5) do
    item =
      WorkItem.new(%{
        source: :manual,
        title: title,
        description: description,
        base_priority: priority
      })

    Agent.update(buffer, fn items -> [item | items] end)
  end

  @doc "Drain all manual submissions."
  @spec drain(pid()) :: [WorkItem.t()]
  def drain(buffer) do
    Agent.get_and_update(buffer, fn items -> {items, []} end)
  end

  @impl true
  def fetch do
    {:ok, []}
  end

  @spec fetch(pid()) :: {:ok, [WorkItem.t()]}
  def fetch(buffer) do
    {:ok, drain(buffer)}
  end
end
