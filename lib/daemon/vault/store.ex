defmodule Daemon.Vault.Store do
  @moduledoc """
  Filesystem-backed markdown store for vault memories.

  Each memory is a markdown file with YAML frontmatter in category-specific
  directories under the vault root (~/.daemon/vault/).
  """
  require Logger

  alias Daemon.Vault.Category

  @doc "Get the vault root directory."
  @spec vault_root() :: String.t()
  def vault_root do
    config_dir = Application.get_env(:daemon, :config_dir, "~/.daemon")
    Path.expand(Path.join(config_dir, "vault"))
  end

  @doc "Initialize vault directory structure."
  @spec init() :: :ok
  def init do
    root = vault_root()

    # Create category directories
    for cat <- Category.all() do
      File.mkdir_p!(Path.join(root, Category.dir(cat)))
    end

    # Create internal directories
    vault_internal = Path.join(root, ".vault")
    File.mkdir_p!(vault_internal)
    File.mkdir_p!(Path.join(vault_internal, "checkpoints"))
    File.mkdir_p!(Path.join(vault_internal, "dirty"))

    # Create handoffs directory
    File.mkdir_p!(Path.join(root, "handoffs"))

    :ok
  end

  @doc """
  Write a memory to a markdown file.

  Returns the file path written.
  """
  @spec write(Category.t(), String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write(category, title, content, frontmatter_values \\ %{}) do
    dir = Path.join(vault_root(), Category.dir(category))
    File.mkdir_p!(dir)

    slug = slugify(title)
    filename = "#{slug}.md"
    path = Path.join(dir, filename)

    fm = Category.frontmatter_template(category, frontmatter_values)
    body = "#{fm}\n\n# #{title}\n\n#{content}\n"

    case File.write(path, body) do
      :ok -> {:ok, path}
      error -> error
    end
  end

  @doc "Read a memory file and return {frontmatter_map, body}."
  @spec read(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {:ok, meta, body} -> {:ok, meta, body}
          :error -> {:ok, %{}, content}
        end

      error ->
        error
    end
  end

  @doc "List all memory files in a category."
  @spec list(Category.t()) :: [String.t()]
  def list(category) do
    dir = Path.join(vault_root(), Category.dir(category))

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc "List all memory files across all categories."
  @spec list_all() :: [{Category.t(), String.t()}]
  def list_all do
    for cat <- Category.all(), path <- list(cat), do: {cat, path}
  end

  @doc "Search vault files for content matching a query string."
  @spec search(String.t(), keyword()) :: [{Category.t(), String.t(), float()}]
  def search(query, opts \\ []) do
    categories = Keyword.get(opts, :categories, Category.all())
    limit = Keyword.get(opts, :limit, 20)
    query_lower = String.downcase(query)
    query_words = String.split(query_lower)

    results =
      for cat <- categories,
          path <- list(cat),
          {:ok, content} <- [File.read(path)] do
        content_lower = String.downcase(content)
        word_matches = Enum.count(query_words, &String.contains?(content_lower, &1))

        if word_matches > 0 do
          score = word_matches / max(length(query_words), 1)
          {cat, path, score}
        end
      end

    results
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_, _, score} -> score end, :desc)
    |> Enum.take(limit)
  end

  @doc "Delete a memory file."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(path) do
    File.rm(path)
  end

  # --- Private ---

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  defp parse_frontmatter(text) do
    case String.split(text, "---", parts: 3) do
      ["", yaml, body] ->
        meta =
          yaml
          |> String.trim()
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ": ", parts: 2) do
              [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
              _ -> acc
            end
          end)

        {:ok, meta, body}

      _ ->
        :error
    end
  end
end
