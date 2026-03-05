defmodule OptimalSystemAgent.Agent.Explorer do
  @moduledoc """
  Auto-exploration before the ReAct loop.

  Detects when a user message involves code modification and automatically
  explores the codebase before the LLM sees the message. This gives the LLM
  structural context (project type, file layout, relevant files) so it can
  make informed decisions instead of jumping straight to file_write/file_edit.

  Two public functions:
    - `should_explore?/2` — zero-cost heuristic (no LLM call)
    - `run_exploration/2` — direct tool execution (no GenServer round-trip)

  Wired into Loop.handle_call via `maybe_explore/2`.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Registry, as: Tools

  # File extensions that indicate code context
  @code_extensions ~w(.ex .exs .ts .tsx .js .jsx .go .py .rs .rb .java .c .cpp .h .hpp
                      .cs .swift .kt .scala .clj .erl .hrl .vue .svelte .css .scss
                      .html .sql .sh .bash .zsh .yaml .yml .json .toml .md)

  # Verbs that indicate code modification intent
  @action_verbs ~w(fix debug refactor implement add create update modify build test
                   review delete remove migrate upgrade change install setup configure
                   deploy write edit optimize improve scaffold generate)

  # Words that indicate code context
  @code_context ~w(file code function module component endpoint route handler test
                   class method interface struct enum type schema model controller
                   service repository middleware hook plugin api database table
                   migration config dependency package)

  # Patterns that indicate casual/skip messages
  @casual_patterns [
    ~r/^(hi|hey|hello|sup|yo|howdy|greetings|good\s+(morning|afternoon|evening))\b/i,
    ~r/^(thanks|thank you|thx|ty|cheers|awesome|perfect|great|nice|cool|ok|okay|k|sure|yep|yeah|yes|no|nope)\b/i,
    ~r/^(bye|goodbye|see ya|later|cya|gotta go)\b/i
  ]

  # Patterns for memory operations (skip exploration)
  @memory_patterns [
    ~r/\b(remember|recall|save|forget|memorize|memo)\b.*\b(this|that|it)\b/i,
    ~r/\bwhat do you (remember|know|recall)\b/i
  ]

  # Patterns for pure questions (skip exploration)
  @question_patterns [
    ~r/^(what is|what are|what was|what were|explain|how does|how do|how is|how are|why does|why is|why do|tell me about|describe)\b/i
  ]

  # Pre-compiled combined pattern for code context words (avoids runtime regex compilation)
  @code_context_pattern Regex.compile!(
    "\\b(" <> Enum.map_join(@code_context, "|", &Regex.escape/1) <> ")\\b"
  )

  # Patterns for pure shell commands (skip exploration)
  @shell_patterns [
    ~r/^(run|execute|start|stop|restart|kill)\s+(mix|npm|yarn|pnpm|bun|cargo|go|python|pip|docker|kubectl|make|rake)\b/i
  ]

  # Project config files that identify project type
  @project_configs %{
    "mix.exs" => "Elixir/OTP",
    "package.json" => "Node.js",
    "go.mod" => "Go",
    "Cargo.toml" => "Rust",
    "pyproject.toml" => "Python",
    "requirements.txt" => "Python",
    "Gemfile" => "Ruby",
    "pom.xml" => "Java (Maven)",
    "build.gradle" => "Java (Gradle)",
    "CMakeLists.txt" => "C/C++ (CMake)",
    "Makefile" => "Make-based"
  }

  # ── Public API ─────────────────────────────────────────────────

  @doc """
  Decide whether to auto-explore before the ReAct loop.

  Returns `true` when the message looks like a code modification task.
  Zero-cost: deterministic regex/heuristic checks only, no LLM call.
  """
  @spec should_explore?(String.t(), map()) :: boolean()
  def should_explore?(message, state) do
    # Quick rejects
    cond do
      # Already explored this turn
      Map.get(state, :exploration_done, false) ->
        false

      # Plan mode active
      Map.get(state, :plan_mode, false) ->
        false

      # Too short (greetings, acks)
      String.length(String.trim(message)) < 30 ->
        false

      # Casual patterns
      Enum.any?(@casual_patterns, &Regex.match?(&1, message)) ->
        false

      # Memory operations
      Enum.any?(@memory_patterns, &Regex.match?(&1, message)) ->
        false

      # Pure shell commands
      Enum.any?(@shell_patterns, &Regex.match?(&1, message)) ->
        false

      # Pure questions without code context
      Enum.any?(@question_patterns, &Regex.match?(&1, message)) and
          not has_code_context?(message) ->
        false

      # Positive match: has action verb + code context
      has_action_intent?(message) ->
        true

      # Positive match: references file paths
      has_file_reference?(message) ->
        true

      # Positive match: mentions project/codebase
      has_project_reference?(message) ->
        true

      # Default: don't explore
      true ->
        false
    end
  end

  @doc """
  Maybe explore the codebase before the ReAct loop.

  Calls `should_explore?/2` and if true, runs exploration and injects
  the context as a system message before the user's message.

  Returns `{:explored, updated_state}` or `{:skip, state}`.
  """
  @spec maybe_explore(map(), String.t()) :: {:explored, map()} | {:skip, map()}
  def maybe_explore(state, message) do
    if should_explore?(message, state) do
      case run_exploration(message, state) do
        {context, files_read} when is_binary(context) and context != "" ->
          # Inject exploration context as a system message before the user's message
          exploration_msg = %{
            role: "system",
            content: context
          }

          # Insert the exploration message before the last message (which is the user's)
          messages = state.messages
          updated_messages = case Enum.split(messages, max(length(messages) - 1, 0)) do
            {before, [last]} -> before ++ [exploration_msg, last]
            {[], []} -> [exploration_msg]
            _ -> messages ++ [exploration_msg]
          end

          # Track explored files
          explored_files = Map.get(state, :explored_files, MapSet.new())
          new_explored = Enum.reduce(files_read, explored_files, &MapSet.put(&2, &1))

          updated_state = %{state |
            messages: updated_messages,
            explored_files: new_explored,
            exploration_done: true
          }

          Logger.info("[Explorer] Auto-explored: #{length(files_read)} files read, context injected")
          {:explored, updated_state}

        _ ->
          {:skip, %{state | exploration_done: true}}
      end
    else
      {:skip, state}
    end
  rescue
    e ->
      Logger.warning("[Explorer] Exploration failed: #{Exception.message(e)}")
      {:skip, state}
  end

  @doc """
  Run codebase exploration directly (no LLM round-trip).

  Calls tools via `Tools.execute_direct/2` (lock-free, no GenServer).
  Returns `{context_string, files_read_list}`.
  """
  @spec run_exploration(String.t(), map()) :: {String.t(), [String.t()]}
  def run_exploration(message, _state) do
    working_dir = detect_working_dir(message)
    files_read = []

    # 1. List root directory
    {structure, root_entries} = explore_directory(working_dir)
    files_read = if structure != "", do: [working_dir | files_read], else: files_read

    # 2. Detect project type from config files
    {project_type, config_file} = detect_project_type(working_dir, root_entries)

    # 3. Read main config file if found
    {config_summary, files_read} =
      if config_file do
        path = Path.join(working_dir, config_file)
        case Tools.execute_direct("file_read", %{"path" => path}) do
          {:ok, content} when is_binary(content) ->
            summary = summarize_config(config_file, content)
            {summary, [path | files_read]}
          _ ->
            {"", files_read}
        end
      else
        {"", files_read}
      end

    # 4. Extract keywords and find relevant files
    keywords = extract_keywords(message)
    {relevant_files, files_read} = find_relevant_files(working_dir, keywords, files_read)

    # 5. For large projects, try MCTS if available
    {mcts_results, files_read} =
      if length(root_entries) > 20 do
        run_mcts_index(working_dir, message, files_read)
      else
        {"", files_read}
      end

    # Build context string (capped at ~8KB)
    context = build_context(working_dir, project_type, structure, config_summary,
                           relevant_files, mcts_results)

    context = cap_context(context, 8_192)
    {context, Enum.uniq(files_read)}
  end

  # ── Private Helpers ────────────────────────────────────────────

  defp has_action_intent?(message) do
    lower = String.downcase(message)
    has_verb = Enum.any?(@action_verbs, fn verb ->
      String.contains?(lower, verb)
    end)
    has_verb and has_code_context?(message)
  end

  defp has_code_context?(message) do
    Regex.match?(@code_context_pattern, String.downcase(message))
  end

  defp has_file_reference?(message) do
    Enum.any?(@code_extensions, fn ext ->
      String.contains?(message, ext)
    end)
  end

  defp has_project_reference?(message) do
    lower = String.downcase(message)
    Regex.match?(~r/\b(project|codebase|repo|repository|workspace)\b/, lower) and
      (has_code_context?(message) or has_file_reference?(message) or
       Enum.any?(@action_verbs, &String.contains?(lower, &1)))
  end

  defp detect_working_dir(message) do
    # Try to extract a path from the message
    case Regex.run(~r{(?:^|[\s"'])(/[^\s"']+)}, message) do
      [_, path] ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: expanded, else: File.cwd!()
      _ ->
        File.cwd!()
    end
  end

  defp explore_directory(path) do
    case Tools.execute_direct("dir_list", %{"path" => path}) do
      {:ok, content} when is_binary(content) ->
        entries = content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 3) do
              [type, _size, name] -> {type, name}
              _ -> {"?", line}
            end
          end)

        # Summarize structure
        dirs = Enum.filter(entries, fn {type, _} -> type == "dir" end) |> Enum.map(&elem(&1, 1))
        files = Enum.filter(entries, fn {type, _} -> type == "file" end) |> Enum.map(&elem(&1, 1))

        structure =
          "**Directories:** #{Enum.join(Enum.take(dirs, 15), ", ")}" <>
          if(length(dirs) > 15, do: " (+#{length(dirs) - 15} more)", else: "") <>
          "\n**Root files:** #{Enum.join(Enum.take(files, 10), ", ")}" <>
          if(length(files) > 10, do: " (+#{length(files) - 10} more)", else: "")

        entry_names = Enum.map(entries, &elem(&1, 1))
        {structure, entry_names}

      _ ->
        {"", []}
    end
  end

  defp detect_project_type(working_dir, root_entries) do
    Enum.find_value(@project_configs, fn {config_file, project_type} ->
      if config_file in root_entries do
        {project_type, config_file}
      end
    end)
    |> case do
      nil ->
        # Fallback: check if config files exist on disk
        Enum.find_value(@project_configs, {"Unknown", nil}, fn {config_file, project_type} ->
          if File.exists?(Path.join(working_dir, config_file)) do
            {project_type, config_file}
          end
        end) || {"Unknown", nil}

      result -> result
    end
  end

  defp summarize_config("mix.exs", content) do
    # Extract deps and app name
    deps = Regex.scan(~r/\{:(\w+),/, content) |> Enum.map(&List.last/1) |> Enum.take(15)
    app = case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> "unknown"
    end
    "**App:** #{app}\n**Dependencies:** #{Enum.join(deps, ", ")}"
  end

  defp summarize_config("package.json", content) do
    case Jason.decode(content) do
      {:ok, parsed} ->
        deps = Map.keys(Map.get(parsed, "dependencies", %{})) |> Enum.take(10)
        dev_deps = Map.keys(Map.get(parsed, "devDependencies", %{})) |> Enum.take(5)
        name = Map.get(parsed, "name", "unknown")
        "**Package:** #{name}\n**Dependencies:** #{Enum.join(deps, ", ")}" <>
          if(dev_deps != [], do: "\n**Dev deps:** #{Enum.join(dev_deps, ", ")}", else: "")
      _ ->
        ""
    end
  end

  defp summarize_config("go.mod", content) do
    module = case Regex.run(~r/module\s+(.+)/, content) do
      [_, mod] -> mod
      _ -> "unknown"
    end
    requires = Regex.scan(~r/\t(.+)\s+v/, content) |> Enum.map(&List.last/1) |> Enum.take(10)
    "**Module:** #{module}\n**Requires:** #{Enum.join(requires, ", ")}"
  end

  defp summarize_config("Cargo.toml", content) do
    name = case Regex.run(~r/name\s*=\s*"(.+?)"/, content) do
      [_, n] -> n
      _ -> "unknown"
    end
    deps = Regex.scan(~r/^(\w+)\s*=\s*["{]/m, content) |> Enum.map(&List.last/1) |> Enum.take(10)
    "**Crate:** #{name}\n**Dependencies:** #{Enum.join(deps, ", ")}"
  end

  defp summarize_config(_file, content) do
    # Generic: just show first few lines
    lines = content |> String.split("\n", trim: true) |> Enum.take(5)
    Enum.join(lines, "\n")
  end

  defp extract_keywords(message) do
    # Remove common stop words and extract meaningful terms
    stop_words = MapSet.new(~w(the a an is are was were be been being have has had do does did
      will would could should may might shall can need to of in for on with at by from as into
      through during before after above below between out off over under again further then
      once that this these those i me my we our you your it its and but or nor not so if when
      what which who how all each every both few more most other some such no only same than
      too very just because about up please let fix add create make update modify change
      implement build write edit test review))

    message
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(stop_words, word) or String.length(word) < 3 end)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp find_relevant_files(working_dir, keywords, files_read) do
    if keywords == [] do
      {"", files_read}
    else
      # Build glob patterns from keywords
      patterns = Enum.flat_map(keywords, fn kw ->
        ["**/*#{kw}*", "**/*#{kw}*.ex", "**/*#{kw}*.ts", "**/*#{kw}*.go"]
      end)
      |> Enum.take(8)

      results =
        patterns
        |> Enum.flat_map(fn pattern ->
          case Tools.execute_direct("file_glob", %{"pattern" => pattern, "path" => working_dir}) do
            {:ok, content} when is_binary(content) ->
              if String.starts_with?(content, "No files") do
                []
              else
                content
                |> String.split("\n", trim: true)
                |> Enum.reject(&String.starts_with?(&1, "0 files"))
                |> Enum.flat_map(fn line ->
                  if String.contains?(line, "files found") do
                    []
                  else
                    [String.trim(line)]
                  end
                end)
              end
            _ ->
              []
          end
        end)
        |> Enum.uniq()
        |> Enum.reject(fn path ->
          # Skip non-code files and build artifacts
          String.contains?(path, "/_build/") or
          String.contains?(path, "/node_modules/") or
          String.contains?(path, "/deps/") or
          String.contains?(path, "/.git/") or
          String.contains?(path, "/target/") or
          String.contains?(path, "/vendor/")
        end)
        |> Enum.take(10)

      relevant_str =
        if results != [] do
          Enum.join(results, "\n")
        else
          ""
        end

      {relevant_str, results ++ files_read}
    end
  end

  defp run_mcts_index(working_dir, message, files_read) do
    case Tools.execute_direct("mcts_index", %{
      "goal" => message,
      "path" => working_dir,
      "max_iterations" => 30
    }) do
      {:ok, content} when is_binary(content) ->
        {content, files_read}
      _ ->
        {"", files_read}
    end
  rescue
    e -> Logger.debug("[Explorer] MCTS failed: #{Exception.message(e)}"); {"", files_read}
  end

  defp build_context(working_dir, project_type, structure, config_summary,
                     relevant_files, mcts_results) do
    parts = [
      "## Codebase Context (auto-explored)",
      "**Project:** #{project_type}",
      "**Root:** #{working_dir}",
      if(structure != "", do: structure, else: nil),
      if(config_summary != "", do: config_summary, else: nil),
      if(relevant_files != "", do: "**Relevant files found:**\n#{relevant_files}", else: nil),
      if(mcts_results != "", do: "**MCTS analysis:**\n#{mcts_results}", else: nil)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp cap_context(context, max_bytes) do
    if byte_size(context) > max_bytes do
      <<truncated::binary-size(max_bytes), _rest::binary>> = context
      # Find last valid UTF-8 boundary by dropping trailing invalid bytes
      truncated =
        case String.chunk(truncated, :valid) do
          [] -> ""
          chunks -> Enum.filter(chunks, &String.valid?/1) |> Enum.join()
        end
      String.trim_trailing(truncated) <> "\n[Context truncated]"
    else
      context
    end
  end
end
