defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols do
  @moduledoc """
  Extract function, module, and class definitions from code files.

  Scans files line-by-line with language-specific regex patterns — much faster
  than file_read when you only need to know what's defined where.
  Returns a compact symbol table: file → [(line, kind, name)].

  Supported: Elixir, Go, TypeScript/JavaScript, Python, Rust.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_paths ["~", "/tmp"]
  @max_output_bytes 8_000
  @max_files 100

  @skip_dirs ~w(_build deps node_modules .git __pycache__ dist build target .elixir_ls ebin priv/static)

  @impl true
  def name, do: "code_symbols"

  @impl true
  def description,
    do:
      "Knowledge graph for codebase indexing — extracts all function/module/class/struct definitions " <>
        "across a project without reading full file contents. " <>
        "Use this FIRST when exploring an unfamiliar codebase: get a complete symbol map " <>
        "(file:line [kind] name), understand module boundaries, find where things are defined, " <>
        "and identify entry points before diving into individual files. " <>
        "Supports: Elixir (.ex/.exs), Go (.go), TypeScript/JavaScript (.ts/.tsx/.js/.jsx), Python (.py), Rust (.rs)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "File or directory to scan. Defaults to ~/.osa/workspace."
        },
        "glob" => %{
          "type" => "string",
          "description" =>
            "File filter glob for directory scans (e.g. '*.ex', '*.go', '**/*.ts'). " <>
              "Omit to auto-detect from project type."
        },
        "include_private" => %{
          "type" => "boolean",
          "description" =>
            "Include private symbols (defp, unexported Go funcs, _ prefix Python). Default: false."
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(params) do
    raw_path = params["path"] || "~/.osa/workspace"
    expanded = Path.expand(raw_path)
    include_private = params["include_private"] == true
    glob = params["glob"]

    if not path_allowed?(expanded) do
      {:error, "Access denied: #{expanded} is outside allowed paths"}
    else
      files = collect_files(expanded, glob)

      case files do
        [] ->
          {:ok, "No code files found at #{expanded}."}

        _ ->
          symbols =
            files
            |> Enum.flat_map(&extract_symbols(&1, include_private))

          case symbols do
            [] -> {:ok, "No symbols found in #{length(files)} file(s)."}
            syms -> {:ok, format_output(syms, length(files))}
          end
      end
    end
  end

  # --- File collection ---

  defp collect_files(path, glob) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        pattern = glob || default_glob(path)

        Path.wildcard(Path.join(path, pattern))
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&skip_path?/1)
        |> Enum.sort()
        |> Enum.take(@max_files)

      true ->
        []
    end
  end

  defp default_glob(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "**/*.{ex,exs}"
      File.exists?(Path.join(dir, "go.mod")) -> "**/*.go"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "**/*.rs"
      File.exists?(Path.join(dir, "pyproject.toml")) or File.exists?(Path.join(dir, "requirements.txt")) -> "**/*.py"
      true -> "**/*.{ex,exs,go,ts,tsx,js,jsx,py,rs}"
    end
  end

  defp skip_path?(path) do
    Enum.any?(@skip_dirs, fn d -> String.contains?(path, "/#{d}/") or String.contains?(path, "\\#{d}\\") end)
  end

  # --- Symbol extraction ---

  defp extract_symbols(path, include_private) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        ext = Path.extname(path)
        symbols = extract_by_ext(ext, lines, include_private)
        Enum.map(symbols, &Map.put(&1, :file, path))

      _ ->
        []
    end
  end

  # Elixir
  defp extract_by_ext(ext, lines, include_private) when ext in [".ex", ".exs"] do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, num} ->
      stripped = String.trim_leading(line)

      cond do
        match = Regex.run(~r/^defmodule\s+(\S+)/, stripped) ->
          [%{line: num, kind: "module", name: Enum.at(match, 1)}]

        match = Regex.run(~r/^def\s+(\w+[?!]?)/, stripped) ->
          [%{line: num, kind: "def", name: Enum.at(match, 1)}]

        include_private and (match = Regex.run(~r/^defp\s+(\w+[?!]?)/, stripped)) ->
          [%{line: num, kind: "defp", name: Enum.at(match, 1)}]

        match = Regex.run(~r/^defmacro\s+(\w+[?!]?)/, stripped) ->
          [%{line: num, kind: "defmacro", name: Enum.at(match, 1)}]

        match = Regex.run(~r/^@behaviour\s+(\S+)/, stripped) ->
          [%{line: num, kind: "behaviour", name: Enum.at(match, 1)}]

        true ->
          []
      end
    end)
  end

  # Go
  defp extract_by_ext(".go", lines, include_private) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, num} ->
      stripped = String.trim_leading(line)

      cond do
        match = Regex.run(~r/^func\s+(?:\([^)]+\)\s+)?(\w+)/, stripped) ->
          name = Enum.at(match, 1)
          exported = String.match?(name, ~r/^[A-Z]/)
          if include_private or exported,
            do: [%{line: num, kind: if(exported, do: "func", else: "func (priv)"), name: name}],
            else: []

        match = Regex.run(~r/^type\s+(\w+)\s+(struct|interface)/, stripped) ->
          name = Enum.at(match, 1)
          kind = Enum.at(match, 2)
          exported = String.match?(name, ~r/^[A-Z]/)
          if include_private or exported,
            do: [%{line: num, kind: kind, name: name}],
            else: []

        true ->
          []
      end
    end)
  end

  # TypeScript / JavaScript
  defp extract_by_ext(ext, lines, include_private) when ext in [".ts", ".tsx", ".js", ".jsx"] do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, num} ->
      stripped = String.trim_leading(line)

      cond do
        match = Regex.run(~r/^export\s+(?:default\s+)?(?:async\s+)?(?:function|class)\s+(\w+)/, stripped) ->
          [%{line: num, kind: "export", name: Enum.at(match, 1)}]

        match = Regex.run(~r/^export\s+(?:const|let|var)\s+(\w+)/, stripped) ->
          [%{line: num, kind: "export const", name: Enum.at(match, 1)}]

        include_private and (match = Regex.run(~r/^(?:async\s+)?function\s+(\w+)/, stripped)) ->
          [%{line: num, kind: "function", name: Enum.at(match, 1)}]

        include_private and (match = Regex.run(~r/^class\s+(\w+)/, stripped)) ->
          [%{line: num, kind: "class", name: Enum.at(match, 1)}]

        true ->
          []
      end
    end)
  end

  # Python
  defp extract_by_ext(".py", lines, include_private) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, num} ->
      stripped = String.trim_leading(line)

      cond do
        match = Regex.run(~r/^class\s+(\w+)/, stripped) ->
          [%{line: num, kind: "class", name: Enum.at(match, 1)}]

        match = Regex.run(~r/^(?:async\s+)?def\s+(\w+)/, stripped) ->
          name = Enum.at(match, 1)
          if include_private or not String.starts_with?(name, "_"),
            do: [%{line: num, kind: "def", name: name}],
            else: []

        match = Regex.run(~r/^    (?:async\s+)?def\s+(\w+)/, line) ->
          name = Enum.at(match, 1)
          if include_private or not String.starts_with?(name, "_"),
            do: [%{line: num, kind: "method", name: name}],
            else: []

        true ->
          []
      end
    end)
  end

  # Rust
  defp extract_by_ext(".rs", lines, include_private) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, num} ->
      stripped = String.trim_leading(line)

      cond do
        match = Regex.run(~r/^(pub\s+)?(?:async\s+)?fn\s+(\w+)/, stripped) ->
          is_pub = Enum.at(match, 1) |> to_string() |> String.trim() == "pub"
          name = Enum.at(match, 2)
          if include_private or is_pub,
            do: [%{line: num, kind: if(is_pub, do: "pub fn", else: "fn"), name: name}],
            else: []

        match = Regex.run(~r/^(pub\s+)?struct\s+(\w+)/, stripped) ->
          [%{line: num, kind: "struct", name: Enum.at(match, 2)}]

        match = Regex.run(~r/^(pub\s+)?trait\s+(\w+)/, stripped) ->
          [%{line: num, kind: "trait", name: Enum.at(match, 2)}]

        match = Regex.run(~r/^(pub\s+)?enum\s+(\w+)/, stripped) ->
          [%{line: num, kind: "enum", name: Enum.at(match, 2)}]

        true ->
          []
      end
    end)
  end

  defp extract_by_ext(_, _, _), do: []

  # --- Output formatting ---

  defp format_output(symbols, file_count) do
    grouped = Enum.group_by(symbols, & &1.file)
    total = length(symbols)

    header = "#{total} symbols across #{file_count} file(s):\n"

    body =
      grouped
      |> Enum.sort_by(fn {file, _} -> file end)
      |> Enum.map(fn {file, syms} ->
        file_label = "#{file}"

        sym_lines =
          syms
          |> Enum.map(fn s -> "  #{s.line}: [#{s.kind}] #{s.name}" end)
          |> Enum.join("\n")

        "#{file_label}\n#{sym_lines}"
      end)
      |> Enum.join("\n\n")

    output = header <> body

    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n...[truncated]"
    else
      output
    end
  end

  # --- Path validation ---

  defp path_allowed?(expanded_path) do
    allowed =
      Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
      |> Enum.map(fn p ->
        e = Path.expand(p)
        if String.ends_with?(e, "/"), do: e, else: e <> "/"
      end)

    check =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    Enum.any?(allowed, fn a -> String.starts_with?(check, a) end)
  end
end
