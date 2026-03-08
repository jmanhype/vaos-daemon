defmodule OptimalSystemAgent.Agent.AutoFixer do
  @moduledoc """
  Auto-test/lint fix loop for iterative error correction.

  Runs tests or linters, captures errors, feeds them to the agent for fixing,
  and repeats until all checks pass or max iterations reached.

  ## Flow

  1. Run test/lint command
  2. If passes → done
  3. If fails → extract errors, send to agent for fix
  4. Agent applies fixes
  5. Repeat from step 1

  ## Usage

      # Synchronous (blocks until done)
      AutoFixer.run(%{type: :test, session_id: "abc"})
      
      # Async (returns immediately, emits events)
      {:ok, task_ref} = AutoFixer.run_async(%{type: :test, session_id: "abc"})
      
      # With options
      AutoFixer.run(%{
        type: :test,
        command: "mix test",
        max_iterations: 5,
        stale_only: true,        # Only run affected tests
        session_id: session_id
      })

  ## Supported Types

  - `:test` — Run tests, parse failures, fix code
  - `:lint` — Run linter, parse errors, fix code  
  - `:typecheck` — Run type checker, parse errors, fix code
  - `:compile` — Run compiler, parse errors, fix code
  """

  require Logger

  alias OptimalSystemAgent.Sandbox.Executor
  alias MiosaProviders.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Workspace

  @default_max_iterations 5
  @default_timeout_ms 120_000
  @max_errors_to_show 10
  
  # ETS table for error pattern cache
  @cache_table :osa_autofix_cache

  @type fix_type :: :test | :lint | :typecheck | :compile | :custom
  @type fix_result :: %{
          success: boolean(),
          iterations: non_neg_integer(),
          final_output: String.t(),
          fixes_applied: [String.t()],
          remaining_errors: [String.t()]
        }

  @type run_opts :: %{
          required(:type) => fix_type(),
          required(:session_id) => String.t(),
          optional(:command) => String.t(),
          optional(:max_iterations) => non_neg_integer(),
          optional(:timeout_ms) => non_neg_integer(),
          optional(:cwd) => String.t(),
          optional(:stale_only) => boolean()
        }

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Run the auto-fix loop asynchronously.
  
  Returns immediately with a task reference. Progress is emitted via events.
  Call `Task.await(task_ref)` to get final result.
  """
  @spec run_async(run_opts()) :: {:ok, Task.t()} | {:error, String.t()}
  def run_async(opts) do
    ensure_cache_table()

    try do
      task = Task.async(fn -> run(opts) end)
      {:ok, task}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Run the auto-fix loop for the given type.

  Returns when all checks pass or max iterations reached.
  """
  @spec run(run_opts()) :: {:ok, fix_result()} | {:error, String.t()}
  def run(opts) do
    ensure_cache_table()
    
    type = opts[:type] || :test
    session_id = opts[:session_id]
    max_iterations = min(opts[:max_iterations] || @default_max_iterations, 20)
    timeout = opts[:timeout_ms] || @default_timeout_ms
    cwd = opts[:cwd] || Workspace.get_cwd()
    stale_only = opts[:stale_only] || false

    base_command = opts[:command] || default_command(type, cwd)
    command = maybe_add_stale_flag(base_command, type, stale_only)

    if command == nil do
      {:error, "Could not detect #{type} command for this project"}
    else
      state = %{
        type: type,
        command: command,
        session_id: session_id,
        max_iterations: max_iterations,
        timeout: timeout,
        cwd: cwd,
        stale_only: stale_only,
        iteration: 0,
        fixes_applied: [],
        last_errors: [],
        error_cache: %{}
      }

      Bus.emit(:system_event, %{
        event: :auto_fixer_started,
        session_id: session_id,
        type: type,
        command: command,
        max_iterations: max_iterations,
        stale_only: stale_only
      })

      run_loop(state)
    end
  end

  @doc """
  Detect the appropriate command for a project.
  """
  @spec detect_command(fix_type(), String.t()) :: String.t() | nil
  def detect_command(type, cwd) do
    default_command(type, cwd)
  end
  
  @doc """
  Clear the error pattern cache.
  """
  def clear_cache do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete_all_objects(@cache_table)
    end
    :ok
  end

  # ── Private Functions ──────────────────────────────────────────────
  
  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:set, :public, :named_table])
        rescue
          ArgumentError -> :ok  # Another process won the race
        end
      _ -> :ok
    end
  end
  
  defp maybe_add_stale_flag(nil, _type, _stale), do: nil
  defp maybe_add_stale_flag(command, :test, true) do
    cond do
      String.contains?(command, "mix test") -> command <> " --stale"
      String.contains?(command, "pytest") -> command <> " --lf"  # last failed
      String.contains?(command, "jest") -> command <> " --onlyChanged"
      String.contains?(command, "go test") -> command  # Go doesn't have stale
      true -> command
    end
  end
  defp maybe_add_stale_flag(command, _type, _stale), do: command

  defp run_loop(%{iteration: iteration, max_iterations: max} = state) when iteration >= max do
    Logger.warning("[AutoFixer] Max iterations (#{max}) reached")
    
    Bus.emit(:system_event, %{
      event: :auto_fixer_completed,
      session_id: state.session_id,
      success: false,
      iterations: iteration,
      reason: "max_iterations"
    })

    {:ok,
     %{
       success: false,
       iterations: iteration,
       final_output: "Max iterations reached. Some errors remain.",
       fixes_applied: state.fixes_applied,
       remaining_errors: state.last_errors
     }}
  end

  defp run_loop(state) do
    iteration = state.iteration + 1

    Bus.emit(:system_event, %{
      event: :auto_fixer_iteration,
      session_id: state.session_id,
      iteration: iteration,
      max_iterations: state.max_iterations,
      type: state.type
    })

    Logger.info("[AutoFixer] Iteration #{iteration}/#{state.max_iterations}: Running #{state.command}")

    case run_check(state.command, state.cwd, state.timeout) do
      {:ok, output, 0} ->
        # Success! All checks pass
        Logger.info("[AutoFixer] All checks pass on iteration #{iteration}")

        Bus.emit(:system_event, %{
          event: :auto_fixer_completed,
          session_id: state.session_id,
          success: true,
          iterations: iteration
        })

        {:ok,
         %{
           success: true,
           iterations: iteration,
           final_output: output,
           fixes_applied: state.fixes_applied,
           remaining_errors: []
         }}

      {:ok, output, _exit_code} ->
        # Failure — parse errors and attempt fix
        errors = parse_errors(state.type, output)

        if errors == [] do
          # Can't parse errors, return failure
          Logger.warning("[AutoFixer] Failed but couldn't parse errors")
          
          {:ok,
           %{
             success: false,
             iterations: iteration,
             final_output: output,
             fixes_applied: state.fixes_applied,
             remaining_errors: ["Unparseable output: #{String.slice(output, 0, 500)}"]
           }}
        else
          Logger.info("[AutoFixer] Found #{length(errors)} errors, attempting fix")

          case attempt_fix(state, errors, iteration) do
            {:ok, fix_description} ->
              state = %{
                state
                | iteration: iteration,
                  fixes_applied: state.fixes_applied ++ [fix_description],
                  last_errors: errors
              }

              run_loop(state)

            {:error, reason} ->
              Logger.error("[AutoFixer] Fix attempt failed: #{reason}")

              {:ok,
               %{
                 success: false,
                 iterations: iteration,
                 final_output: "Fix attempt failed: #{reason}",
                 fixes_applied: state.fixes_applied,
                 remaining_errors: errors
               }}
          end
        end

      {:error, reason} ->
        {:error, "Failed to run check command: #{reason}"}
    end
  end

  defp run_check(command, cwd, timeout) do
    case Executor.execute(command, cwd: cwd, timeout: timeout) do
      {:ok, output, exit_code} -> {:ok, output, exit_code}
      {:ok, output} -> {:ok, output, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_fix(state, errors, iteration) do
    # Check cache for similar error patterns
    cache_key = compute_error_cache_key(state.type, errors)
    cached_hint = lookup_cache(cache_key)

    # Build a prompt for the agent to fix the errors
    error_summary = format_errors(state.type, errors)

    cache_context =
      case cached_hint do
        nil -> ""
        hint -> """

        **Previous Fix Hint:** This error pattern has been fixed before using this approach:
        #{hint}

        Try this approach first.
        """
      end

    prompt = """
    ## Auto-Fix Iteration #{iteration}

    The #{state.type} check failed with the following errors:

    #{error_summary}
    #{cache_context}

    Please analyze these errors and fix them. For each error:
    1. Read the relevant file
    2. Understand the issue
    3. Apply the fix using file_edit or file_write

    After fixing, I will re-run the checks automatically.
    """

    # Get tools for fixing
    tools = Tools.list_tools_direct()
    fix_tools = Enum.filter(tools, fn t -> t.name in ~w(file_read file_edit file_write shell_execute) end)

    # Run a mini agent loop to apply fixes
    messages = [
      %{role: "system", content: fix_system_prompt(state.type)},
      %{role: "user", content: prompt}
    ]

    case run_fix_agent(messages, fix_tools, state.cwd, 0, 10) do
      {:ok, response} ->
        # Store successful fix pattern in cache
        store_in_cache(cache_key, extract_fix_summary(response))
        {:ok, "Fixed #{length(errors)} errors: #{String.slice(response, 0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # ── Cache Helpers ──────────────────────────────────────────────────
  
  defp compute_error_cache_key(type, errors) do
    # Create a normalized key from error patterns (strip line numbers, file paths)
    patterns =
      errors
      |> Enum.map(&normalize_error_for_cache/1)
      |> Enum.sort()
      |> Enum.join("|")

    :erlang.phash2({type, patterns})
  end
  
  defp normalize_error_for_cache(error) do
    error
    |> String.replace(~r/:\d+:\d+/, ":N:N")  # Strip line:col
    |> String.replace(~r/\b\d+\b/, "N")       # Strip numbers
    |> String.replace(~r/["'][^"']+["']/, "S") # Strip string literals
    |> String.slice(0, 100)                    # Limit length
  end
  
  defp lookup_cache(key) do
    if :ets.whereis(@cache_table) != :undefined do
      case :ets.lookup(@cache_table, key) do
        [{^key, hint}] -> hint
        _ -> nil
      end
    else
      nil
    end
  end
  
  defp store_in_cache(key, hint) when is_binary(hint) and hint != "" do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.insert(@cache_table, {key, hint})
    end
    :ok
  end
  defp store_in_cache(_key, _hint), do: :ok
  
  defp extract_fix_summary(response) do
    # Extract the key fix action from the response
    response
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "fixed") or
      String.contains?(line, "changed") or
      String.contains?(line, "updated") or
      String.contains?(line, "replaced")
    end)
    |> Enum.take(3)
    |> Enum.join("\n")
    |> String.slice(0, 300)
  end

  defp run_fix_agent(_messages, _tools, _cwd, iteration, max_iters) when iteration >= max_iters do
    {:error, "Fix agent hit max iterations"}
  end

  defp run_fix_agent(messages, tools, cwd, iteration, max_iters) do
    # Set workspace for tools
    Workspace.set_agent_cwd(cwd)

    case Providers.chat(messages, tools: tools, temperature: 0.2, max_tokens: 4000) do
      {:ok, %{content: content, tool_calls: []}} ->
        Workspace.clear_agent_cwd()
        {:ok, content}

      {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) and tool_calls != [] ->
        messages = messages ++ [%{role: "assistant", content: content, tool_calls: tool_calls}]

        messages =
          Enum.reduce(tool_calls, messages, fn tool_call, msgs ->
            result =
              case Tools.execute_direct(tool_call.name, tool_call.arguments) do
                {:ok, output} -> output
                {:error, reason} -> "Error: #{reason}"
              end

            msgs ++ [%{role: "tool", tool_call_id: tool_call.id, content: result}]
          end)

        run_fix_agent(messages, tools, cwd, iteration + 1, max_iters)

      {:ok, %{content: content}} when is_binary(content) ->
        Workspace.clear_agent_cwd()
        {:ok, content}

      {:error, reason} ->
        Workspace.clear_agent_cwd()
        {:error, "LLM error: #{inspect(reason)}"}
    end
  end

  defp fix_system_prompt(:test) do
    """
    You are an expert test fixer. Your job is to analyze test failures and fix the underlying code.

    When fixing tests:
    1. Read the failing test file to understand what's expected
    2. Read the implementation file to understand the current behavior
    3. Determine if the bug is in the test or the implementation
    4. Apply the smallest fix that makes the test pass
    5. Don't change test assertions unless the test itself is wrong

    Use file_read to examine files, and file_edit to apply fixes.
    """
  end

  defp fix_system_prompt(:lint) do
    """
    You are an expert linter fixer. Your job is to fix lint errors and style violations.

    When fixing lint errors:
    1. Read the file with the error
    2. Understand the lint rule being violated
    3. Apply the idiomatic fix for that language
    4. Ensure the fix doesn't break functionality

    Common fixes: formatting, unused variables, import ordering, type annotations.
    """
  end

  defp fix_system_prompt(:typecheck) do
    """
    You are an expert type error fixer. Your job is to fix type checking errors.

    When fixing type errors:
    1. Read the file with the error
    2. Understand the expected vs actual types
    3. Fix the type annotation or the value, whichever is incorrect
    4. Propagate type fixes if needed

    Use file_read to examine files, and file_edit to apply fixes.
    """
  end

  defp fix_system_prompt(:compile) do
    """
    You are an expert compiler error fixer. Your job is to fix compilation errors.

    When fixing compile errors:
    1. Read the file with the error
    2. Understand the syntax or semantic error
    3. Apply the minimal fix to make it compile
    4. Check for related errors in the same file

    Use file_read to examine files, and file_edit to apply fixes.
    """
  end

  defp fix_system_prompt(_) do
    """
    You are an expert code fixer. Analyze the errors and apply fixes.
    Use file_read to examine files, and file_edit to apply fixes.
    """
  end

  # ── Error Parsing ──────────────────────────────────────────────────

  defp parse_errors(:test, output) do
    cond do
      # Elixir/ExUnit
      output =~ "** (ExUnit" or output =~ "test/" ->
        parse_elixir_test_errors(output)

      # Jest/Vitest
      output =~ "FAIL" and output =~ "●" ->
        parse_jest_errors(output)

      # Go
      output =~ "--- FAIL:" ->
        parse_go_test_errors(output)

      # Python/Pytest
      output =~ "FAILED" and output =~ "short test summary" ->
        parse_pytest_errors(output)

      true ->
        # Generic: split on common error patterns
        extract_generic_errors(output)
    end
  end

  defp parse_errors(:lint, output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ":"))
    |> Enum.filter(fn line ->
      String.contains?(line, "error") or
        String.contains?(line, "warning") or
        String.match?(line, ~r/:\d+:\d+:/)
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_errors(:typecheck, output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/error|TypeError|type.*mismatch/i))
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_errors(:compile, output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/error|Error|undefined|cannot find/i))
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_errors(_, output) do
    extract_generic_errors(output)
  end

  defp parse_elixir_test_errors(output) do
    # Match patterns like "test/foo_test.exs:42" or "** (RuntimeError)"
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.match?(line, ~r/^\s+\d+\)/) or
        String.contains?(line, "** (") or
        String.match?(line, ~r/test\/.*\.exs:\d+/)
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_jest_errors(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "●") or
        String.contains?(line, "Expected") or
        String.contains?(line, "Received") or
        String.match?(line, ~r/at.*\.(js|ts|tsx):\d+/)
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_go_test_errors(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "--- FAIL:") or
        String.match?(line, ~r/_test\.go:\d+/) or
        String.contains?(line, "Error Trace:")
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp parse_pytest_errors(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "FAILED") or
        String.contains?(line, "AssertionError") or
        String.match?(line, ~r/test_.*\.py:\d+/)
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp extract_generic_errors(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.match?(line, ~r/error|fail|exception|assert/i) and
        String.length(line) > 10 and
        String.length(line) < 500
    end)
    |> Enum.take(@max_errors_to_show)
  end

  defp format_errors(type, errors) do
    header =
      case type do
        :test -> "Test Failures"
        :lint -> "Lint Errors"
        :typecheck -> "Type Errors"
        :compile -> "Compile Errors"
        _ -> "Errors"
      end

    """
    ### #{header}

    ```
    #{Enum.join(errors, "\n")}
    ```
    """
  end

  # ── Command Detection ──────────────────────────────────────────────

  defp default_command(:test, cwd) do
    cond do
      File.exists?(Path.join(cwd, "mix.exs")) -> "mix test"
      File.exists?(Path.join(cwd, "package.json")) -> detect_js_test_command(cwd)
      File.exists?(Path.join(cwd, "go.mod")) -> "go test ./..."
      File.exists?(Path.join(cwd, "Cargo.toml")) -> "cargo test"
      File.exists?(Path.join(cwd, "pyproject.toml")) -> "pytest"
      File.exists?(Path.join(cwd, "pytest.ini")) -> "pytest"
      File.exists?(Path.join(cwd, "requirements.txt")) -> "python -m pytest"
      true -> nil
    end
  end

  defp default_command(:lint, cwd) do
    cond do
      File.exists?(Path.join(cwd, "mix.exs")) -> "mix credo"
      File.exists?(Path.join(cwd, "package.json")) -> detect_js_lint_command(cwd)
      File.exists?(Path.join(cwd, "go.mod")) -> "golangci-lint run"
      File.exists?(Path.join(cwd, "Cargo.toml")) -> "cargo clippy"
      File.exists?(Path.join(cwd, "pyproject.toml")) -> "ruff check ."
      true -> nil
    end
  end

  defp default_command(:typecheck, cwd) do
    cond do
      File.exists?(Path.join(cwd, "mix.exs")) -> "mix dialyzer"
      File.exists?(Path.join(cwd, "tsconfig.json")) -> "npx tsc --noEmit"
      File.exists?(Path.join(cwd, "package.json")) -> "npx tsc --noEmit"
      File.exists?(Path.join(cwd, "pyproject.toml")) -> "mypy ."
      true -> nil
    end
  end

  defp default_command(:compile, cwd) do
    cond do
      File.exists?(Path.join(cwd, "mix.exs")) -> "mix compile --warnings-as-errors"
      File.exists?(Path.join(cwd, "go.mod")) -> "go build ./..."
      File.exists?(Path.join(cwd, "Cargo.toml")) -> "cargo build"
      File.exists?(Path.join(cwd, "tsconfig.json")) -> "npx tsc"
      true -> nil
    end
  end

  defp default_command(:custom, _cwd), do: nil

  defp detect_js_test_command(cwd) do
    case File.read(Path.join(cwd, "package.json")) do
      {:ok, content} ->
        cond do
          content =~ "vitest" -> "npx vitest run"
          content =~ "jest" -> "npx jest"
          content =~ "mocha" -> "npx mocha"
          content =~ "\"test\":" -> "npm test"
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp detect_js_lint_command(cwd) do
    case File.read(Path.join(cwd, "package.json")) do
      {:ok, content} ->
        cond do
          content =~ "eslint" -> "npx eslint ."
          content =~ "biome" -> "npx biome check"
          content =~ "\"lint\":" -> "npm run lint"
          true -> nil
        end

      _ ->
        nil
    end
  end
end
