defmodule Daemon.Channels.HTTP.API.SkillsMarketplaceRoutes do
  @moduledoc "Skills marketplace API — browse, search, enable/disable skills."
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Tools.Registry

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  defp skills_dir, do: Path.expand(Application.get_env(:daemon, :skills_dir, "~/.daemon/skills"))

  # GET / — list all skills with enabled/disabled status
  get "/" do
    skills = Registry.list_skills()
    priv_defs = Registry.load_skill_definitions()

    priv_by_name =
      Enum.reduce(priv_defs, %{}, fn skill, acc ->
        Map.put(acc, skill.name, skill)
      end)

    entries =
      Enum.map(skills, fn skill ->
        priv = Map.get(priv_by_name, skill.name)

        %{
          id: skill.name,
          name: skill.name,
          description: skill.description || "",
          category: categorize(skill, priv),
          source: source(skill),
          enabled: not disabled?(skill.name),
          triggers: skill.triggers || [],
          path: skill.path || "",
          priority: (priv && priv.priority) || 5
        }
      end)

    json(conn, 200, %{skills: entries, count: length(entries)})
  end

  # GET /categories — list categories with counts
  get "/categories" do
    skills = Registry.list_skills()
    priv_defs = Registry.load_skill_definitions()
    priv_by_name = Map.new(priv_defs, fn s -> {s.name, s} end)

    counts =
      Enum.reduce(skills, %{}, fn skill, acc ->
        cat = categorize(skill, Map.get(priv_by_name, skill.name))
        Map.update(acc, cat, 1, &(&1 + 1))
      end)

    categories =
      Enum.map(counts, fn {name, count} -> %{name: name, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)

    json(conn, 200, %{categories: categories})
  end

  # GET /:id — skill detail
  get "/:id" do
    case Registry.get_skill(id) do
      nil ->
        json_error(conn, 404, "not_found", "Skill not found")

      skill ->
        priv_defs = Registry.load_skill_definitions()
        priv = Enum.find(priv_defs, fn s -> s.name == id end)

        entry = %{
          id: skill.name,
          name: skill.name,
          description: skill.description || "",
          category: categorize(skill, priv),
          source: source(skill),
          enabled: not disabled?(skill.name),
          triggers: skill.triggers || [],
          path: skill.path || "",
          priority: (priv && priv.priority) || 5,
          instructions: (priv && priv.instructions) || "",
          metadata: (priv && priv.metadata) || %{}
        }

        json(conn, 200, entry)
    end
  end

  # PUT /:id/toggle — enable/disable a skill
  put "/:id/toggle" do
    case Registry.get_skill(id) do
      nil ->
        json_error(conn, 404, "not_found", "Skill not found")

      _skill ->
        dir = Path.join(skills_dir(), id)
        marker = Path.join(dir, ".disabled")

        if File.exists?(marker) do
          File.rm(marker)
          json(conn, 200, %{id: id, enabled: true})
        else
          File.mkdir_p!(dir)
          File.write!(marker, "")
          json(conn, 200, %{id: id, enabled: false})
        end
    end
  end

  # POST /search — search skills by query
  post "/search" do
    query = conn.body_params["query"] || ""

    if String.trim(query) == "" do
      json(conn, 200, %{results: [], count: 0})
    else
      results =
        Registry.search(query)
        |> Enum.map(fn {name, description, score} ->
          %{id: name, name: name, description: description, score: score}
        end)

      json(conn, 200, %{results: results, count: length(results)})
    end
  end

  # POST /bulk-enable — enable multiple skills
  post "/bulk-enable" do
    ids = conn.body_params["ids"] || []

    Enum.each(ids, fn id ->
      marker = Path.join([skills_dir(), id, ".disabled"])
      if File.exists?(marker), do: File.rm(marker)
    end)

    json(conn, 200, %{enabled: ids, count: length(ids)})
  end

  # POST /bulk-disable — disable multiple skills
  post "/bulk-disable" do
    ids = conn.body_params["ids"] || []

    Enum.each(ids, fn id ->
      dir = Path.join(skills_dir(), id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".disabled"), "")
    end)

    json(conn, 200, %{disabled: ids, count: length(ids)})
  end

  match _ do
    json_error(conn, 404, "not_found", "Skills marketplace endpoint not found")
  end

  # Derive category from priv skill definition or skill metadata
  defp categorize(_skill, %{category: cat}) when cat in ~w(core automation reasoning), do: cat
  defp categorize(skill, _priv) do
    path = to_string(skill[:path] || "")

    cond do
      String.contains?(path, "priv/agents") -> "agent"
      String.contains?(path, "/core/") -> "core"
      String.contains?(path, "/automation/") -> "workflow"
      String.contains?(path, "/reasoning/") -> "reasoning"
      String.contains?(path, "/security") -> "security"
      true -> "utility"
    end
  end

  defp source(skill) do
    path = to_string(skill[:path] || "")
    cond do
      String.contains?(path, "priv/") -> "builtin"
      String.contains?(path, ".daemon/skills/evolved/") -> "evolved"
      true -> "user"
    end
  end

  defp disabled?(name) do
    Path.join([skills_dir(), name, ".disabled"]) |> File.exists?()
  end
end
