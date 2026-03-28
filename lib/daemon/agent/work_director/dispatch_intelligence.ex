defmodule Daemon.Agent.WorkDirector.DispatchIntelligence do
  @moduledoc """
  Pre-computes codebase context for WorkDirector dispatch prompts.

  Uses the daemon's own tools (MCTS indexer, code_symbols, file_read, file_grep)
  via `Tools.execute_direct/2` to build execution-trace-style prompts with:

  - Relevant files discovered by MCTS goal-directed search
  - Module/function signatures from code_symbols
  - Actual code of the most relevant files
  - Integration points (alias/import/use directives)
  - File territory (explicit allow-list of files to create/modify)

  Zero LLM cost — pure Elixir tool calls.
  """

  require Logger

  alias Daemon.Tools.Registry, as: Tools

  @max_relevant_files 5
  @max_reference_files 3
  @max_file_content_bytes 3_000
  @mcts_iterations 50
  @grep_timeout_ms 5_000

  @doc """
  Enrich a work item with codebase context.

  Returns a map with:
  - `:relevant_files` — list of `%{path, relevance, symbols}` maps
  - `:reference_code` — map of `%{path => content}` for the top reference files
  - `:integration_points` — list of `%{module, file, line}` maps
  - `:file_territory` — suggested files to create/modify
  - `:execution_trace` — formatted string ready for prompt injection
  """
  @spec enrich(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def enrich(title, description, repo_path) do
    goal = "#{title} #{description}" |> String.slice(0, 500)

    # Run MCTS + grep in parallel
    mcts_task = Task.async(fn -> find_relevant_files(goal, repo_path) end)
    grep_task = Task.async(fn -> find_by_keywords(title, repo_path) end)

    mcts_files = Task.await(mcts_task, 15_000) |> Enum.take(@max_relevant_files)
    grep_files = Task.await(grep_task, 15_000)

    # Merge and deduplicate, preferring MCTS ranking
    all_files = merge_file_lists(mcts_files, grep_files)
    top_files = Enum.take(all_files, @max_relevant_files)

    # Get symbols for top files
    files_with_symbols =
      Enum.map(top_files, fn file_info ->
        symbols = get_symbols(file_info.path)
        Map.put(file_info, :symbols, symbols)
      end)

    # Read actual content of top reference files
    reference_code =
      files_with_symbols
      |> Enum.take(@max_reference_files)
      |> Enum.map(fn f ->
        content = read_file_content(f.path)
        {f.path, content}
      end)
      |> Map.new()

    # Find integration points (modules referenced in relevant files)
    integration_points = find_integration_points(top_files, repo_path)

    # Suggest file territory based on task analysis
    file_territory = suggest_file_territory(title, description, files_with_symbols, repo_path)

    # Auto-detect codebase conventions (zero LLM cost)
    conventions = detect_conventions(repo_path)
    Logger.info("[DispatchIntelligence] Detected #{length(conventions)} conventions for #{repo_path}")
    if conventions != [], do: Logger.debug("[DispatchIntelligence] Conventions: #{inspect(conventions)}")

    # Build the execution trace string
    trace = build_execution_trace(
      title, files_with_symbols, reference_code, integration_points, file_territory, conventions
    )

    {:ok, %{
      relevant_files: files_with_symbols,
      reference_code: reference_code,
      integration_points: integration_points,
      file_territory: file_territory,
      conventions: conventions,
      execution_trace: trace
    }}
  rescue
    e ->
      Logger.warning("[DispatchIntelligence] Enrichment failed: #{Exception.message(e)}")
      {:error, {:enrichment_failed, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[DispatchIntelligence] Enrichment exit: #{inspect(reason)}")
      {:error, {:enrichment_exit, reason}}
  end

  # -- File Discovery --

  defp find_relevant_files(goal, repo_path) do
    case Tools.execute_direct("mcts_index", %{
      "goal" => goal,
      "root_dir" => repo_path,
      "max_iterations" => @mcts_iterations,
      "max_results" => @max_relevant_files * 2
    }) do
      {:ok, result} when is_binary(result) ->
        parse_mcts_results(result)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp find_by_keywords(title, repo_path) do
    # Extract meaningful keywords from title
    keywords =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, " ")
      |> String.split()
      |> Enum.reject(&(&1 in ~w(add implement create update fix the a an for to in of with and)))
      |> Enum.take(3)

    case keywords do
      [] ->
        []

      terms ->
        pattern = Enum.join(terms, "|")
        task = Task.async(fn ->
          Tools.execute_direct("file_grep", %{
            "pattern" => pattern,
            "path" => repo_path,
            "glob" => "*.ex",
            "output_mode" => "files_with_matches"
          })
        end)

        case Task.yield(task, @grep_timeout_ms) || Task.shutdown(task) do
          {:ok, {:ok, result}} when is_binary(result) ->
            result
            |> String.split("\n", trim: true)
            |> Enum.take(@max_relevant_files)
            |> Enum.map(&%{path: &1, relevance: 0.5, source: :grep})

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  defp parse_mcts_results(result) do
    # MCTS output format: ranked lines with "path (score: X.XX)"
    result
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(.+?)\s+\(score:\s*([\d.]+)\)/, line) do
        [_, path, score_str] ->
          case Float.parse(score_str) do
            {score, _} -> [%{path: String.trim(path), relevance: score, source: :mcts}]
            _ -> []
          end

        _ ->
          # Try plain path format
          trimmed = String.trim(line)
          if String.ends_with?(trimmed, ".ex") or String.ends_with?(trimmed, ".exs") do
            [%{path: trimmed, relevance: 0.3, source: :mcts}]
          else
            []
          end
      end
    end)
  end

  defp merge_file_lists(mcts_files, grep_files) do
    mcts_paths = MapSet.new(mcts_files, & &1.path)

    unique_grep =
      Enum.reject(grep_files, fn f -> MapSet.member?(mcts_paths, f.path) end)

    (mcts_files ++ unique_grep)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  # -- Symbol Extraction --

  defp get_symbols(path) do
    case Tools.execute_direct("code_symbols", %{"path" => path}) do
      {:ok, result} when is_binary(result) ->
        result
        |> String.split("\n", trim: true)
        |> Enum.take(20)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # -- File Reading --

  defp read_file_content(path) do
    case Tools.execute_direct("file_read", %{"path" => path}) do
      {:ok, content} when is_binary(content) ->
        if byte_size(content) > @max_file_content_bytes do
          String.slice(content, 0, @max_file_content_bytes) <> "\n[... truncated]"
        else
          content
        end

      _ ->
        "[could not read file]"
    end
  rescue
    _ -> "[read error]"
  end

  # -- Integration Points --

  defp find_integration_points(files, repo_path) do
    files
    |> Enum.flat_map(fn file_info ->
      case Tools.execute_direct("file_grep", %{
        "pattern" => "^\\s*(alias|import|use)\\s+",
        "path" => file_info.path,
        "output_mode" => "content"
      }) do
        {:ok, result} when is_binary(result) ->
          result
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/(alias|import|use)\s+([\w.]+)/, line) do
              [_, kind, module] ->
                [%{kind: kind, module: module, from_file: file_info.path}]
              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.module)
    |> resolve_module_files(repo_path)
  rescue
    _ -> []
  end

  defp resolve_module_files(points, repo_path) do
    Enum.map(points, fn point ->
      # Convert module name to likely file path
      file_guess =
        point.module
        |> String.replace(".", "/")
        |> Macro.underscore()

      # Check if the file exists
      full_path = Path.join(repo_path, "lib/#{file_guess}.ex")

      if File.exists?(full_path) do
        Map.put(point, :file, full_path)
      else
        point
      end
    end)
  end

  # -- File Territory --

  defp suggest_file_territory(title, _description, relevant_files, repo_path) do
    lower_title = String.downcase(title)

    # Determine if this is a "create new" or "modify existing" task
    creates_new = String.contains?(lower_title, "add") or
                  String.contains?(lower_title, "create") or
                  String.contains?(lower_title, "implement") or
                  String.contains?(lower_title, "introduce")

    modify_candidates =
      relevant_files
      |> Enum.filter(fn f -> f.relevance >= 0.3 end)
      |> Enum.map(fn f ->
        rel_path = Path.relative_to(f.path, repo_path)
        %{action: :modify, path: rel_path, reason: "relevance #{Float.round(f.relevance, 2)}"}
      end)
      |> Enum.take(3)

    create_candidates =
      if creates_new do
        [suggest_new_file_path(title, repo_path)]
      else
        []
      end

    create_candidates ++ modify_candidates
  end

  defp suggest_new_file_path(title, _repo_path) do
    # Generate a likely file path from the title
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.replace(~r/\s+/, "_")
      |> String.slice(0, 50)

    # Heuristic: most daemon features go in lib/daemon/
    path =
      cond do
        String.contains?(slug, "test") -> "test/#{slug}_test.exs"
        String.contains?(slug, "tool") -> "lib/daemon/tools/builtins/#{slug}.ex"
        String.contains?(slug, "channel") -> "lib/daemon/channels/#{slug}.ex"
        String.contains?(slug, "route") -> "lib/daemon/channels/http/api/#{slug}.ex"
        true -> "lib/daemon/#{slug}.ex"
      end

    %{action: :create, path: path, reason: "suggested from title"}
  end

  # -- Execution Trace Builder --

  defp build_execution_trace(_title, relevant_files, reference_code, integration_points, file_territory, conventions) do
    # Section 1: Relevant files with symbols
    file_section =
      relevant_files
      |> Enum.map(fn f ->
        symbols_str =
          case f.symbols do
            [] -> ""
            syms -> "\n    Symbols: #{Enum.join(Enum.take(syms, 5), ", ")}"
          end

        "  - #{f.path} (relevance: #{Float.round(f.relevance, 2)})#{symbols_str}"
      end)
      |> Enum.join("\n")

    # Section 0: Codebase conventions (MUST come first — sets ground rules)
    conventions_section =
      if conventions != [] do
        rules = Enum.map_join(conventions, "\n", &("- #{&1}"))
        ["## Codebase Conventions (MANDATORY — violating these will cause your work to be rejected)\n#{rules}"]
      else
        []
      end

    sections = conventions_section ++ ["## Relevant Files\n#{file_section}"]

    # Section 2: Reference implementations
    ref_section =
      reference_code
      |> Enum.map(fn {path, content} ->
        "### #{Path.basename(path)}\n```elixir\n#{content}\n```"
      end)
      |> Enum.join("\n\n")

    sections =
      if ref_section != "" do
        sections ++ ["## Reference Implementations\n#{ref_section}"]
      else
        sections
      end

    # Section 3: Integration points
    sections =
      if integration_points != [] do
        int_section =
          integration_points
          |> Enum.take(10)
          |> Enum.map(fn p ->
            file_str = if Map.has_key?(p, :file), do: " (#{p.file})", else: ""
            "  - #{p.kind} #{p.module}#{file_str}"
          end)
          |> Enum.join("\n")

        sections ++ ["## Integration Points\n#{int_section}"]
      else
        sections
      end

    # Section 4: File territory
    territory_section =
      file_territory
      |> Enum.map(fn t ->
        action = if t.action == :create, do: "CREATE", else: "MODIFY"
        "  #{action}: #{t.path}"
      end)
      |> Enum.join("\n")

    sections = sections ++ ["## File Territory (you may ONLY touch these files)\n#{territory_section}"]

    Enum.join(sections, "\n\n")
  end

  # -- Codebase Convention Detection --

  @doc """
  Auto-detect codebase conventions from static analysis.
  Returns a list of rule strings to inject into the dispatch prompt.
  Zero LLM cost — pure file system inspection.
  """
  def detect_conventions(repo_path) do
    rules = []

    # 1. Detect module namespace prefix
    rules = rules ++ detect_namespace(repo_path)

    # 2. Detect web framework (Phoenix vs Plug.Router vs none)
    rules = rules ++ detect_web_framework(repo_path)

    # 3. Detect file structure patterns
    rules = rules ++ detect_file_patterns(repo_path)

    # 4. Detect test conventions
    rules = rules ++ detect_test_patterns(repo_path)

    rules
  rescue
    _ -> []
  end

  defp detect_namespace(repo_path) do
    # Sample defmodule declarations, excluding shims/compatibility files
    case System.cmd("bash", ["-c",
      "grep -rh '^defmodule ' #{repo_path}/lib/ --include='*.ex' --exclude='shims.ex' --exclude='*_compat.ex' 2>/dev/null | head -100"],
      stderr_to_stdout: true) do
      {output, 0} when byte_size(output) > 0 ->
        prefixes =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/defmodule\s+([\w]+)\./, line) do
              [_, prefix] -> [prefix]
              _ -> []
            end
          end)
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_, count} -> count end, :desc)

        case prefixes do
          [{top_prefix, _} | _] ->
            anti_prefixes =
              ~w(Phoenix VasSwarm VasSwarmWeb MyApp App Web)
              |> Enum.reject(&(&1 == top_prefix))
              |> Enum.join(", ")

            ["Module namespace: ALL modules MUST start with `#{top_prefix}.` — NEVER use #{anti_prefixes} or any other prefix"]
          _ -> []
        end

      _ -> []
    end
  end

  defp detect_web_framework(repo_path) do
    rules = []

    # Check if Phoenix is in deps
    has_phoenix = File.exists?(Path.join(repo_path, "lib/daemon_web")) or
                  File.exists?(Path.join(repo_path, "lib/vas_swarm_web"))

    # Check if Plug.Router is used
    has_plug_router =
      case System.cmd("bash", ["-c",
        "grep -rl 'use Plug.Router' #{repo_path}/lib/ --include='*.ex' 2>/dev/null | wc -l"],
        stderr_to_stdout: true) do
        {count, 0} -> String.trim(count) |> String.to_integer() > 0
        _ -> false
      end

    rules = if not has_phoenix and has_plug_router do
      rules ++ [
        "This project uses raw Plug.Router for HTTP — NOT Phoenix. Do NOT create Phoenix controllers, views, templates, or LiveView modules",
        "HTTP route modules go in `lib/daemon/channels/http/api/` and use `use Plug.Router`",
        "Do NOT create files in any `*_web/` directory — this directory does not exist"
      ]
    else
      rules
    end

    # Detect the HTTP API entry point
    api_path = Path.join(repo_path, "lib/daemon/channels/http/api.ex")
    if File.exists?(api_path) do
      rules ++ [
        "New HTTP endpoints: create a route module in `lib/daemon/channels/http/api/` then add `forward \"/path\", to: API.YourRoutes` in `lib/daemon/channels/http/api.ex`"
      ]
    else
      rules
    end
  end

  defp detect_file_patterns(repo_path) do
    rules = []

    # Detect the lib/ structure depth
    lib_dirs =
      case System.cmd("bash", ["-c",
        "ls -d #{repo_path}/lib/daemon/*/ 2>/dev/null | head -15"],
        stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&Path.basename(String.trim_trailing(&1, "/")))
        _ -> []
      end

    if lib_dirs != [] do
      dir_list = Enum.join(lib_dirs, ", ")
      rules ++ ["Existing lib/daemon/ subdirectories: #{dir_list} — place new files in the appropriate existing directory"]
    else
      rules
    end
  end

  defp detect_test_patterns(repo_path) do
    test_dir = Path.join(repo_path, "test")

    if File.dir?(test_dir) do
      ["Tests go in `test/` mirroring the `lib/` structure. Test files end with `_test.exs`"]
    else
      []
    end
  end
end
