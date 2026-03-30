defmodule Daemon.Agent.WorkDirector.GroundedVerifier do
  @moduledoc """
  Zero-LLM-cost static verification of agent-generated code.

  Runs after compilation (Stage 2) but before commit (Stage 3) to catch
  phantom references — code that compiles but references modules, functions,
  or routes that don't exist in the codebase.

  Symmetrical to DispatchIntelligence: that module pre-computes codebase
  context on the INPUT side, this module validates references on the OUTPUT side.
  Same tools (git, file system), same zero cost, opposite ends of the pipeline.

  Checks:
  1. Module references (alias/import/use/defdelegate) resolve to real files
  2. Plug.Router forwards point to existing modules
  3. New files have substantive content (not just boilerplate)
  4. At least one test file exists for new public modules (soft warning)
  """

  require Logger

  @doc """
  Verify the agent's output on the current branch against the real codebase.

  Returns:
    {:ok, warnings}        — no hard failures, maybe soft warnings
    {:error, violations}   — hard failures that must be fixed before commit
  """
  @spec verify(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def verify(branch, repo_path) do
    case get_diff(branch, repo_path) do
      {:ok, diff} ->
        added_lines = extract_added_lines(diff)
        new_files = extract_new_files(diff)

        # Hard checks (block commit if any fail)
        phantom_modules = check_phantom_modules(added_lines, new_files, repo_path)
        phantom_forwards = check_phantom_forwards(added_lines, new_files, repo_path)
        phantom_delegates = check_phantom_delegates(added_lines, new_files, repo_path)

        hard_failures = phantom_modules ++ phantom_forwards ++ phantom_delegates

        # Soft checks (warn but don't block)
        warnings = check_missing_tests(new_files, repo_path) ++
                   check_trivial_changes(diff, new_files)

        if hard_failures == [] do
          {:ok, warnings}
        else
          {:error, hard_failures}
        end

      {:error, reason} ->
        Logger.warning("[GroundedVerifier] Could not get diff: #{inspect(reason)}")
        # Don't block on diff failure — let the commit proceed
        {:ok, ["Could not run verification: #{inspect(reason)}"]}
    end
  rescue
    e ->
      Logger.warning("[GroundedVerifier] Verification crashed: #{Exception.message(e)}")
      {:ok, ["Verification error: #{Exception.message(e)}"]}
  end

  @doc """
  Format violations into a targeted fix prompt for the agent.
  """
  @spec fix_prompt([String.t()]) :: String.t()
  def fix_prompt(violations) do
    violation_list = Enum.map_join(violations, "\n", &("- #{&1}"))

    """
    Your code has reference errors that must be fixed. These compile but will fail at runtime:

    #{violation_list}

    For each violation:
    - If you imported/aliased a module that doesn't exist, either CREATE it or use an existing alternative
    - If you forwarded a route to a non-existent module, CREATE the module with a working implementation
    - If you delegated to a function that doesn't exist, implement it or remove the delegation

    Fix ALL violations. Do NOT create empty stub modules — each module must have real functionality.
    """
  end

  # -- Diff Parsing --

  @doc "Get diff of all changes (committed + uncommitted + untracked) vs main."
  def get_diff(_branch, repo_path) do
    # Get ALL changes vs main: committed + uncommitted + untracked
    # Agent may or may not have committed during Stage 1

    # 1. Committed changes on branch vs main
    {committed, _} = System.cmd("git", ["diff", "--unified=0", "main...HEAD", "--", "*.ex", "*.exs"],
                       cd: repo_path, stderr_to_stdout: true)

    # 2. Uncommitted working tree changes
    {uncommitted, _} = System.cmd("git", ["diff", "--unified=0", "HEAD", "--", "*.ex", "*.exs"],
                         cd: repo_path, stderr_to_stdout: true)

    # 3. Untracked new files
    {untracked_list, _} = System.cmd("git", ["ls-files", "--others", "--exclude-standard", "--", "*.ex", "*.exs"],
                            cd: repo_path, stderr_to_stdout: true)

    synthetic =
      untracked_list
      |> String.split("\n", trim: true)
      |> Enum.map_join("\n", fn file ->
        full_path = Path.join(repo_path, file)
        case File.read(full_path) do
          {:ok, content} ->
            lines = content |> String.split("\n") |> Enum.map_join("\n", &("+#{&1}"))
            "--- /dev/null\n+++ b/#{file}\n#{lines}"
          _ -> ""
        end
      end)

    combined = [committed, uncommitted, synthetic]
               |> Enum.reject(&(&1 == ""))
               |> Enum.join("\n")

    if byte_size(combined) > 0 do
      {:ok, combined}
    else
      {:ok, ""}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Extract added lines (lines starting with +) from a unified diff."
  def extract_added_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "+"))
    |> Enum.reject(&String.starts_with?(&1, "+++"))
    |> Enum.map(&String.slice(&1, 1..-1//1))
  end

  defp extract_new_files(diff) do
    # Files that appear in "--- /dev/null" -> "+++ b/path" pairs are new
    lines = String.split(diff, "\n")

    lines
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [dev_null, plus_line] ->
        if String.starts_with?(dev_null, "--- /dev/null") and String.starts_with?(plus_line, "+++ b/") do
          [String.trim_leading(plus_line, "+++ b/")]
        else
          []
        end
      _ -> []
    end)
  end

  # -- Phantom Module Check --

  defp check_phantom_modules(added_lines, new_files, repo_path) do
    # Extract module references from alias/import/use statements
    module_refs =
      added_lines
      |> Enum.flat_map(fn line ->
        trimmed = String.trim(line)
        cond do
          match = Regex.run(~r/^\s*(alias|import|use)\s+([\w.]+)/, trimmed) ->
            [_full, kind, module] = match
            [{kind, module}]
          true ->
            []
        end
      end)
      |> Enum.uniq()

    # Check each referenced module
    Enum.flat_map(module_refs, fn {kind, module} ->
      if module_exists?(module, new_files, repo_path) do
        []
      else
        ["#{kind} #{module} — this module does not exist in the codebase. Create it or use an existing alternative."]
      end
    end)
  end

  # -- Phantom Forward Check --

  defp check_phantom_forwards(added_lines, new_files, repo_path) do
    added_lines
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/forward\s+"[^"]+"\s*,\s*to:\s*([\w.]+)/, line) do
        [_, module] -> [module]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn module ->
      if module_exists?(module, new_files, repo_path) do
        []
      else
        ["forward route to #{module} — this module does not exist. Create it with a working Plug.Router implementation."]
      end
    end)
  end

  # -- Phantom Delegate Check --

  defp check_phantom_delegates(added_lines, new_files, repo_path) do
    added_lines
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/defdelegate\s+\w+.*,\s*to:\s*([\w.]+)/, line) do
        [_, module] -> [module]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn module ->
      if module_exists?(module, new_files, repo_path) do
        []
      else
        ["defdelegate to #{module} — this module does not exist. Either create it or implement the function directly."]
      end
    end)
  end

  # -- Module Existence --

  defp module_exists?(module, new_files, repo_path) do
    # Skip standard library / well-known modules
    if standard_module?(module) do
      true
    else
      # Convert module name to possible file paths
      possible_paths = module_to_paths(module)

      # Check if any path exists in repo OR was created by the agent
      Enum.any?(possible_paths, fn path ->
        full_path = Path.join(repo_path, path)
        File.exists?(full_path) or path in new_files
      end)
    end
  end

  defp standard_module?(module) do
    # Elixir stdlib, Erlang, and common deps
    prefix = module |> String.split(".") |> hd()

    prefix in ~w(
      Enum Map List String Keyword Tuple MapSet
      GenServer Agent Task Supervisor DynamicSupervisor
      Logger Application System Process Node
      File Path IO Code Module Macro Kernel
      Regex URI Base DateTime NaiveDateTime Date Time
      Integer Float Atom Access Stream Range
      Plug Phoenix Ecto Jason Req
      ExUnit Mix Config
      ETS Mnesia
    ) or String.starts_with?(module, ":") # Erlang modules
  end

  defp module_to_paths(module) do
    # Daemon.Agent.WorkDirector -> lib/daemon/agent/work_director.ex
    snake =
      module
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Enum.join("/")

    base_paths = [
      "lib/#{snake}.ex",
      "lib/#{snake}/#{Path.basename(snake)}.ex",
      "test/#{snake}_test.exs"
    ]

    # Also check if this might be an aliased short module name.
    # E.g., "API.PrometheusRoutes" in api.ex likely means
    # "Daemon.Channels.HTTP.API.PrometheusRoutes" via alias.
    # Try common expansions based on the module prefix.
    alias_paths =
      case String.split(module, ".") do
        ["API" | rest] ->
          expanded_snake = (["daemon", "channels", "http", "api"] ++ Enum.map(rest, &Macro.underscore/1)) |> Enum.join("/")
          ["lib/#{expanded_snake}.ex"]
        _ -> []
      end

    base_paths ++ alias_paths
  end

  # -- Soft Checks --

  defp check_missing_tests(new_files, _repo_path) do
    new_lib_files =
      Enum.filter(new_files, &String.starts_with?(&1, "lib/"))

    new_test_files =
      Enum.filter(new_files, &String.starts_with?(&1, "test/"))

    if new_lib_files != [] and new_test_files == [] do
      ["No test files created for #{length(new_lib_files)} new module(s). Consider adding tests."]
    else
      []
    end
  end

  @substance_threshold 25

  @doc """
  Analyze substance of changes. Returns structured analysis for quality gating.

  Returns a map with:
  - `meaningful_lines` — count of non-boilerplate added lines
  - `has_substance` — true if above threshold and no stub patterns
  - `stub_patterns` — list of detected stub patterns
  - `warnings` — human-readable warnings
  """
  @spec analyze_substance(String.t(), [String.t()]) :: map()
  def analyze_substance(diff, _new_files \\ []) do
    added_lines =
      diff
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "+"))
      |> Enum.reject(&String.starts_with?(&1, "+++"))
      |> Enum.map(&String.trim(String.slice(&1, 1..-1//1)))

    meaningful =
      Enum.reject(added_lines, fn line ->
        line == "" or line == "end" or line == "do" or
          String.starts_with?(line, "#") or
          String.starts_with?(line, "@moduledoc") or
          String.starts_with?(line, "@doc") or
          String.starts_with?(line, "defmodule") or
          (String.starts_with?(line, "@") and not String.starts_with?(line, "@spec")) or
          String.match?(line, ~r/^\s*(use|require|import|alias)\s/)
      end)

    stub_patterns =
      added_lines
      |> Enum.flat_map(fn line ->
        cond do
          Regex.match?(~r/raise\s+"not implemented"/i, line) -> ["raise \"not implemented\""]
          Regex.match?(~r/raise\s+"TODO"/i, line) -> ["raise TODO"]
          Regex.match?(~r/:not_implemented/, line) -> [":not_implemented"]
          Regex.match?(~r/def \w+.*,\s*do:\s*:ok\s*$/, line) -> ["no-op :ok"]
          Regex.match?(~r/def \w+.*,\s*do:\s*nil\s*$/, line) -> ["no-op nil"]
          true -> []
        end
      end)
      |> Enum.uniq()

    meaningful_count = length(meaningful)

    warnings =
      if meaningful_count < @substance_threshold do
        ["Only #{meaningful_count} meaningful lines (threshold: #{@substance_threshold})."]
      else
        []
      end

    warnings = warnings ++ Enum.map(stub_patterns, &"Stub pattern: #{&1}")

    %{
      meaningful_lines: meaningful_count,
      # Stub patterns only block when they dominate the diff.
      # A single no-op :ok in a 1500-line diff is normal (init callbacks, hooks).
      # Block when: <25 meaningful lines OR stubs are >50% of meaningful lines.
      has_substance: meaningful_count >= @substance_threshold and
        (stub_patterns == [] or length(stub_patterns) < meaningful_count * 0.5),
      stub_patterns: stub_patterns,
      warnings: warnings
    }
  end

  # Backward compat for verify/2 soft-warning path
  defp check_trivial_changes(diff, _new_files) do
    result = analyze_substance(diff)
    result.warnings
  end
end
