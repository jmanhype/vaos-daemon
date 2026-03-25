defmodule Daemon.Vault.Category do
  @moduledoc """
  Typed memory categories for the Vault structured memory system.

  Eight categories with filesystem directory mapping and YAML frontmatter templates.
  """

  @type t ::
          :fact
          | :decision
          | :lesson
          | :preference
          | :commitment
          | :relationship
          | :project
          | :observation

  @categories %{
    fact: %{
      dir: "facts",
      label: "Fact",
      icon: "📌",
      frontmatter: ["confidence", "source", "domain"]
    },
    decision: %{
      dir: "decisions",
      label: "Decision",
      icon: "⚖️",
      frontmatter: ["context", "alternatives", "outcome"]
    },
    lesson: %{
      dir: "lessons",
      label: "Lesson",
      icon: "💡",
      frontmatter: ["trigger", "insight", "applied"]
    },
    preference: %{
      dir: "preferences",
      label: "Preference",
      icon: "⭐",
      frontmatter: ["scope", "strength"]
    },
    commitment: %{
      dir: "commitments",
      label: "Commitment",
      icon: "🤝",
      frontmatter: ["party", "deadline", "status"]
    },
    relationship: %{
      dir: "relationships",
      label: "Relationship",
      icon: "👤",
      frontmatter: ["entity", "role", "context"]
    },
    project: %{
      dir: "projects",
      label: "Project",
      icon: "📁",
      frontmatter: ["status", "stack", "repo"]
    },
    observation: %{
      dir: "observations",
      label: "Observation",
      icon: "👁️",
      frontmatter: ["score", "decay_rate", "tags"]
    }
  }

  @doc "All category atoms."
  @spec all() :: [t()]
  def all, do: Map.keys(@categories)

  @doc "Directory name for a category."
  @spec dir(t()) :: String.t()
  def dir(category) when is_map_key(@categories, category) do
    @categories[category].dir
  end

  @doc "Human-readable label."
  @spec label(t()) :: String.t()
  def label(category) when is_map_key(@categories, category) do
    @categories[category].label
  end

  @doc "YAML frontmatter keys for a category."
  @spec frontmatter_keys(t()) :: [String.t()]
  def frontmatter_keys(category) when is_map_key(@categories, category) do
    @categories[category].frontmatter
  end

  @doc "Generate a YAML frontmatter template string for a category."
  @spec frontmatter_template(t(), map()) :: String.t()
  def frontmatter_template(category, values \\ %{}) when is_map_key(@categories, category) do
    lines =
      [
        {"category", Atom.to_string(category)},
        {"created", DateTime.utc_now() |> DateTime.to_iso8601()}
      ] ++
        Enum.map(@categories[category].frontmatter, fn key ->
          {key, Map.get(values, key, Map.get(values, String.to_atom(key), ""))}
        end)

    inner = Enum.map_join(lines, "\n", fn {k, v} -> "#{k}: #{v}" end)
    "---\n#{inner}\n---"
  end

  @doc "Parse a category from string."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in Map.keys(@categories), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  @doc "Validate a category atom."
  @spec valid?(atom()) :: boolean()
  def valid?(category), do: is_map_key(@categories, category)
end
