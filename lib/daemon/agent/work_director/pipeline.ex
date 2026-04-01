defmodule Daemon.Agent.WorkDirector.Pipeline do
  @moduledoc """
  Staged execution pipeline for WorkDirector dispatches.
  
  Extracted from WorkDirector to separate concerns. This module handles
  the complete dispatch lifecycle from branch creation through PR creation.
  
  ## Pipeline Stages
  - Stage 0:   Branch creation
  - Stage 0.5: Context enrichment (vault, knowledge, investigation, etc.)
  - Stage 1:   Implementation via Orchestrator
  - Stage 1.5: Branch recovery
  - Stage 1.9: Substance check
  - Stage 2:   Compilation verification
  - Stage 2.5: Grounded reference verification
  - Stage 2.75: Test gate
  - Stage 2.9: Code review
  - Stage 3:   Commit/push/PR
  """
  
  require Logger

  alias Daemon.Agent.WorkDirector.Backlog.WorkItem
  alias Daemon.Agent.WorkDirector.ContextEnrichment
  alias Daemon.Agent.WorkDirector.GroundedVerifier
  alias Daemon.Agent.WorkDirector.DispatchIntelligence
  alias Daemon.Agent.Orchestrator
  alias Daemon.Agent.AutoFixer
  alias Daemon.Agent.Orchestrator.SwarmMode
  alias Daemon.Agent.Debate
  
  # -- Pipeline Constants --
  @orchestrator_poll_interval_ms 10_000
  @orchestrator_timeout_ms :timer.minutes(15)
  @compile_fix_max_attempts 2
  @review_fix_max_attempts 1
  @agent_max_iterations 20
  @test_gate_timeout_ms 120_000
  @reference_fix_max_attempts 1
  
  @subprocess_schedulers 4

  # Feature flags are now in Application config :daemon, :work_director_flags
  # See config/config.exs for defaults
  @protected_path_patterns [
    "^lib/daemon/application\\.ex$",
    "^lib/daemon/supervisors/",
    "^lib/daemon/security/",
    "^lib/daemon/agent/loop\\.ex$",
    "^config/runtime\\.exs$",
    "^mix\\.exs$",
    "^mix\\.lock$"
  ]
  
  @daemon_repo "jmanhype/vaos-daemon"

  # Helper to get flags from runtime config
  defp get_flag(flag_name, default) do
    Application.get_env(:daemon, :work_director_flags, %{})
    |> Map.get(flag_name, default)
  end

  @doc """
  Run the complete staged dispatch pipeline.
  
  ## Parameters
  - item: WorkItem to dispatch
  - branch: Branch name (from WorkDirector.branch_name/1)
  - session_id: Unique session identifier
  - repo_path: Path to the git repository
  
  ## Returns
  - {:ok, synthesis, branch} on success
  - {:error, reason} on failure
  """
  def run(item, branch, session_id, repo_path) do
    # Stage 0: Create the branch ourselves
    Logger.info("[Pipeline] Stage 0: Creating branch #{branch}")
    case create_branch(branch, repo_path) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[Pipeline] Stage 0 failed: #{inspect(reason)}")
        throw({:stage0_failed, reason})
    end

    # Stage 0.5: Pre-research context enrichment
    pre_research_context = build_pre_research_context(item, repo_path, session_id)

    # Stage 1: Implementation — agent only writes code, no git operations
    Logger.info("[Pipeline] Stage 1: Dispatching implementation to Orchestrator")
    prompt = build_implementation_prompt(item, repo_path, pre_research_context)

    case execute_and_poll(prompt, session_id, item) do
      {:completed, synthesis} ->
        Logger.info("[Pipeline] Stage 1 complete: agent finished implementation")

        # Stage 1.5: Recover branch if agent switched away
        recover_branch(branch, repo_path)

        # Stage 1.9: Substance check — reject stubs
        maybe_check_substance(branch, repo_path)

        # Stage 2: Verify compilation (with retry loop)
        case verify_and_fix_compilation(item, branch, session_id, repo_path, 0) do
          :ok ->
            Logger.info("[Pipeline] Stage 2 complete: compilation verified")
            # Recover branch if compile-fix agent switched away
            recover_branch(branch, repo_path)

            # Stage 2.5: Grounded verification — check phantom references
            case verify_and_fix_references(branch, session_id, repo_path, 0) do
              :ok ->
                Logger.info("[Pipeline] Stage 2.5 complete: references verified")
              {:warnings, warnings} ->
                Logger.info("[Pipeline] Stage 2.5 passed with warnings: #{Enum.join(warnings, "; ")}")
              {:error, _reason} ->
                Logger.warning("[Pipeline] Stage 2.5 failed: phantom references unfixable")
                cleanup_branch(branch, repo_path)
                throw({:stage2_5_failed, :phantom_references})
            end

            # Stage 2.75: Test gate (hard — blocks PR on failure)
            maybe_run_test_gate(branch, repo_path)

            # Stage 2.9: Code review (debate/review)
            maybe_run_code_review(item, branch, session_id, repo_path)

            # Recover branch before finalize — agents may have switched during stages 2.5-2.9
            recover_branch(branch, repo_path)

            # Stage 3: Commit, push, PR
            case finalize_branch(item, branch, repo_path) do
              {:ok, _pr_info} ->
                Logger.info("[Pipeline] Stage 3 complete: branch #{branch} committed and pushed")
                # Switch back to main for next dispatch
                System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
                {:ok, synthesis, branch}

              {:error, :no_changes} ->
                Logger.warning("[Pipeline] Stage 3 failed: no file changes detected")
                cleanup_branch(branch, repo_path)
                {:error, {:empty_branch, synthesis}}

              {:error, reason} ->
                Logger.warning("[Pipeline] Stage 3 failed: #{inspect(reason)}")
                cleanup_branch(branch, repo_path)
                {:error, {:commit_failed, reason}}
            end

          {:error, reason} ->
            Logger.warning("[Pipeline] Stage 2 failed: compilation cannot be fixed")
            cleanup_branch(branch, repo_path)
            {:error, {:compilation_unfixable, reason}}
        end

      {:failed, error} ->
        Logger.warning("[Pipeline] Stage 1 failed: #{inspect(error)}")
        cleanup_branch(branch, repo_path)
        {:error, {:orchestrator_failed, error}}

      {:timeout, last_status} ->
        Logger.warning("[Pipeline] Stage 1 timed out")
        cleanup_branch(branch, repo_path)
        {:error, {:timeout, last_status}}
    end
  catch
    {:stage0_failed, reason} -> {:error, {:no_branch, reason}}
    {:stage1_9_failed, reason} -> {:error, {:stub_detected, reason}}
    {:stage2_5_failed, reason} -> {:error, {:phantom_references, reason}}
    {:stage2_75_failed, reason} -> {:error, {:test_failure, reason}}
  end



  # -- Stage 0.5: Context Enrichment --

  defp build_pre_research_context(item, repo_path, session_id) do
    ContextEnrichment.build(item, repo_path, session_id)
  end
  # -- Stage 1.9: Substance Check --

  defp maybe_check_substance(branch, repo_path) do
    if get_flag(:substance_check, true) do
      try do
        case GroundedVerifier.get_diff(branch, repo_path) do
          {:ok, diff} ->
            analysis = GroundedVerifier.analyze_substance(diff)

            unless analysis.has_substance do
              Logger.warning(
                "[Pipeline] Stage 1.9: STUB — #{analysis.meaningful_lines} lines, stubs: #{inspect(analysis.stub_patterns)}"
              )

              cleanup_branch(branch, repo_path)
              throw({:stage1_9_failed, {:stub_detected, analysis}})
            end

            if analysis.warnings != [] do
              Logger.info("[Pipeline] Stage 1.9: OK with warnings: #{Enum.join(analysis.warnings, "; ")}")
            else
              Logger.info("[Pipeline] Stage 1.9: Substance OK (#{analysis.meaningful_lines} lines)")
            end

          {:error, reason} ->
            Logger.warning("[Pipeline] Stage 1.9: diff failed (non-blocking): #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.warning("[Pipeline] Stage 1.9 error (non-blocking): #{Exception.message(e)}")
      catch
        :exit, r ->
          Logger.warning("[Pipeline] Stage 1.9 exit (non-blocking): #{inspect(r)}")
      end
    end
  end

  # -- Stage 2.75: Test Gate --

  defp maybe_run_test_gate(branch, repo_path) do
    if get_flag(:test_gate, true) do
      try do
        Logger.info("[Pipeline] Stage 2.75: Running tests")
        recover_branch(branch, repo_path)

        # Use Port.open directly so we can explicitly close it on timeout,
        # guaranteeing SIGHUP delivery to the OS process.
        mix_exe = System.find_executable("mix") || "mix"
        parent = self()
        port_ref = make_ref()

        # Only test files related to changed source files — avoids pre-existing failures
        test_files = related_test_files(repo_path)
        test_args = case test_files do
          [] ->
            Logger.info("[Pipeline] Stage 2.75: No related test files, skipping test gate")
            nil
          files ->
            Logger.info("[Pipeline] Stage 2.75: Testing #{length(files)} related file(s)")
            ["test", "--max-failures", "5"] ++ files
        end

        # Skip test execution if no related tests found
        unless test_args do
          Logger.info("[Pipeline] Stage 2.75: Skipped (no related tests)")
          throw(:test_gate_skipped)
        end

        task = Task.async(fn ->
          port = Port.open({:spawn_executable, mix_exe}, [
            :binary, :exit_status, :stderr_to_stdout,
            args: test_args,
            cd: String.to_charlist(repo_path),
            env: [
              {~c"MIX_ENV", ~c"test"},
              {~c"ERL_AFLAGS", ~c"+S #{@subprocess_schedulers}:#{@subprocess_schedulers}"}
            ]
          ])
          send(parent, {port_ref, port})
          test_gate_collect_output(port, [])
        end)

        # Receive port ref for explicit cleanup on timeout
        test_port = receive do
          {^port_ref, port} -> port
        after
          5_000 -> nil
        end

        case Task.yield(task, @test_gate_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {_output, 0}} ->
            Logger.info("[Pipeline] Stage 2.75: Tests PASSED")

          {:ok, {output, _}} ->
            summary =
              output
              |> String.split("\n")
              |> Enum.filter(&(String.contains?(&1, "failure") or String.contains?(&1, "error")))
              |> Enum.take(3)
              |> Enum.join("; ")

            Logger.warning(
              "[Pipeline] Stage 2.75: Tests FAILED (hard gate): #{String.slice(summary, 0, 500)}"
            )
            cleanup_branch(branch, repo_path)
            throw({:stage2_75_failed, {:test_failure, String.slice(summary, 0, 500)}})

          nil ->
            # Explicitly close port to send SIGHUP to the OS process
            if test_port do
              try do Port.close(test_port) catch _, _ -> :ok end
            end
            Logger.warning("[Pipeline] Stage 2.75: Tests TIMED OUT (hard gate) after #{div(@test_gate_timeout_ms, 1000)}s")
            cleanup_branch(branch, repo_path)
            throw({:stage2_75_failed, {:test_timeout, "#{div(@test_gate_timeout_ms, 1000)}s"}})
        end
      rescue
        e -> Logger.warning("[Pipeline] Stage 2.75 error: #{Exception.message(e)}")
      catch
        :throw, :test_gate_skipped -> :ok
        :exit, r -> Logger.warning("[Pipeline] Stage 2.75 exit: #{inspect(r)}")
      end
    end
  end

  defp test_gate_collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        test_gate_collect_output(port, [data | acc])
      {^port, {:exit_status, code}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}
    end
  end

  # Find test files related to changed source files in the current branch
  defp related_test_files(repo_path) do
    try do
      {diff_output, 0} = System.cmd("git", ["diff", "--name-only", "main...HEAD"],
        cd: repo_path, stderr_to_stdout: true)

      diff_output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "lib/"))
      |> Enum.flat_map(fn src_file ->
        test_file = src_file
          |> String.replace_prefix("lib/daemon/", "test/")
          |> String.replace_suffix(".ex", "_test.exs")
        if File.exists?(Path.join(repo_path, test_file)), do: [test_file], else: []
      end)
      |> Enum.uniq()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # -- Stage 2.9: Code Review --

  defp maybe_run_code_review(item, branch, session_id, repo_path) do
    # Phase 2: force_review from judgment context overrides the flag
    judgment_ctx = Process.get(:dispatch_judgment_context)
    force_review = is_map(judgment_ctx) and judgment_ctx[:force_review] == true

    if get_flag(:code_review, true) or force_review do
      try do
        Logger.info("[Pipeline] Stage 2.9: Running code review via debate")
        recover_branch(branch, repo_path)

        # Get actual diff content — includes committed + uncommitted + untracked
        # (agent may not have committed yet at this stage)
        diff = case Daemon.Agent.WorkDirector.GroundedVerifier.get_diff(branch, repo_path) do
          {:ok, d} -> d
          {:error, _} -> ""
        end

        if byte_size(diff) > 10 do
          review_prompt = """
          Review this Elixir code change for '#{item.title}'.
          Check for: correctness, security issues, missing error handling, Elixir best practices.

          IMPORTANT: Your first line MUST be exactly one of:
          VERDICT: PASS
          VERDICT: FIX

          Then 3-5 bullet points explaining your assessment.

          ```diff
          #{String.slice(diff, 0, 4000)}
          ```
          """

          case Debate.run(review_prompt, providers: ["anthropic"], timeout: 30_000) do
            {:ok, %{synthesis: synthesis}} ->
              verdict = parse_review_verdict(synthesis)
              Logger.info("[Pipeline] Stage 2.9: Review verdict=#{verdict}: #{String.slice(synthesis, 0, 300)}")

              if get_flag(:review_fix_loop, true) and verdict == :fix do
                run_reflexion_fix(item, branch, session_id, repo_path, synthesis)
              end

            {:error, reason} ->
              Logger.warning("[Pipeline] Stage 2.9: Review failed (non-blocking): #{inspect(reason)}")
          end
        else
          Logger.warning("[Pipeline] Stage 2.9: No diff to review (#{byte_size(diff)} bytes)")
        end
      rescue
        e -> Logger.warning("[Pipeline] Stage 2.9 error: #{Exception.message(e)}")
      catch
        :exit, r -> Logger.warning("[Pipeline] Stage 2.9 exit: #{inspect(r)}")
      end
    end
  end

  defp parse_review_verdict(synthesis) do
    first_line = synthesis |> String.trim() |> String.split("\n") |> hd() |> String.upcase()

    cond do
      String.contains?(first_line, "PASS") -> :pass
      String.contains?(first_line, "FIX") -> :fix
      # Heuristic fallback: if review mentions critical issues, treat as fix
      String.contains?(String.downcase(synthesis), "critical") or
          String.contains?(String.downcase(synthesis), "security vulnerability") ->
        :fix
      true -> :pass
    end
  end

  defp run_reflexion_fix(_item, branch, session_id, repo_path, synthesis) do
    Logger.info("[Pipeline] Stage 2.9: Reflexion — dispatching refinement agent (max_attempts=#{@review_fix_max_attempts})")

    refinement_prompt = """
    A code review found issues with your implementation. Fix them.

    ## Repository
    The codebase is at: `#{repo_path}`
    You are on branch `#{branch}`.

    CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
    For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

    ## MANDATORY GIT RULES — VIOLATION = TASK FAILURE
    - NEVER run `git checkout`, `git switch`, or `git branch -D` — stay on `#{branch}`
    - NEVER run `git commit`, `git push`, `git add`, `git stash`, `git merge`, `git rebase`
    - ANY git command that changes branch state will cause your work to be LOST

    ## Code Review Feedback
    #{String.slice(synthesis, 0, 3000)}

    ## Instructions
    1. Read the files mentioned in the review
    2. Fix ONLY the issues identified in the review
    3. Run `mix compile` to verify (use cwd: "#{repo_path}")
    4. Do NOT add features, refactor beyond what's requested, or change unrelated code

    Do NOT modify: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
    """

    fix_session = "#{session_id}-review-fix"

    case execute_and_poll(refinement_prompt, fix_session) do
      {:completed, _} ->
        case run_compile(repo_path) do
          :ok ->
            Logger.info("[Pipeline] Stage 2.9: Refinement complete, compilation OK")

          {:error, _} ->
            Logger.warning("[Pipeline] Stage 2.9: Refinement broke compilation (non-blocking)")
        end

      {:failed, reason} ->
        Logger.warning("[Pipeline] Stage 2.9: Refinement failed (non-blocking): #{inspect(reason)}")

      {:timeout, _} ->
        Logger.warning("[Pipeline] Stage 2.9: Refinement timed out (non-blocking)")
    end
  end

  defp create_branch(branch, repo_path) do
    # Remove stale lock file from crashed git processes
    lock_path = Path.join([repo_path, ".git", "index.lock"])
    if File.exists?(lock_path), do: File.rm(lock_path)

    # Nuclear cleanup: abort any in-progress merge/rebase/cherry-pick, then hard reset
    System.cmd("git", ["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["rebase", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: repo_path, stderr_to_stdout: true)

    # Delete ALL stale workdir/ branches (from previous cycles or other systems)
    {branches_raw, _} = System.cmd("git", ["branch"], cd: repo_path, stderr_to_stdout: true)
    branches_raw
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "workdir/"))
    |> Enum.each(fn b ->
      System.cmd("git", ["branch", "-D", b], cd: repo_path, stderr_to_stdout: true)
    end)

    # Delete stale remote branch if it exists (prevents push rejection)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)

    case System.cmd("git", ["checkout", "-b", branch, "main"], cd: repo_path, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git checkout -b failed: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Recover if the agent switched away from the workdir branch during Stage 1.
  # Stashes any uncommitted changes, switches to the correct branch, then unstashes.
  # If the agent committed to main, cherry-picks those commits to the branch and resets main.
  defp recover_branch(branch, repo_path) do
    {current_raw, _} = System.cmd("git", ["branch", "--show-current"], cd: repo_path, stderr_to_stdout: true)
    current = String.trim(current_raw)

    if current == branch do
      Logger.debug("[Pipeline] Branch OK: still on #{branch}")
    else
      Logger.warning("[Pipeline] Branch drift! Expected #{branch}, on #{current}. Recovering...")

      # Check if agent made rogue commits on the wrong branch (e.g., main)
      if current == "main" do
        {ahead_raw, _} = System.cmd("git", ["rev-list", "origin/main..main", "--count"], cd: repo_path, stderr_to_stdout: true)
        ahead = String.trim(ahead_raw) |> String.to_integer()

        if ahead > 0 do
          Logger.warning("[Pipeline] Found #{ahead} rogue commit(s) on main — cherry-picking to #{branch}")
          # Get the rogue commit SHAs
          {shas_raw, _} = System.cmd("git", ["rev-list", "origin/main..main", "--reverse"], cd: repo_path, stderr_to_stdout: true)
          rogue_shas = String.split(shas_raw, "\n", trim: true)

          # Stash any uncommitted changes
          System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

          # Reset main to origin/main (remove rogue commits from main)
          System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)

          # Switch to the workdir branch
          System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true)

          # Cherry-pick the rogue commits onto the branch
          Enum.each(rogue_shas, fn sha ->
            case System.cmd("git", ["cherry-pick", sha], cd: repo_path, stderr_to_stdout: true) do
              {_, 0} -> Logger.info("[Pipeline] Cherry-picked #{String.slice(sha, 0, 8)} to #{branch}")
              {err, _} ->
                Logger.warning("[Pipeline] Cherry-pick failed for #{String.slice(sha, 0, 8)}: #{String.trim(err)}")
                System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
            end
          end)

          # Unstash working tree changes
          System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        else
          # No rogue commits, just stash + switch
          System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

          case System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true) do
            {_, 0} -> :ok
            {_, _} ->
              Logger.warning("[Pipeline] Branch #{branch} gone from main — recreating")
              System.cmd("git", ["checkout", "-b", branch], cd: repo_path, stderr_to_stdout: true)
          end

          System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        end
      else
        # On some other branch entirely — stash + switch
        System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

        case System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true) do
          {_, 0} ->
            System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)

          {_err, _} ->
            # Branch doesn't exist (was deleted) — recreate from main, not current HEAD
            Logger.warning("[Pipeline] Branch #{branch} gone — recreating from main")
            System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
            System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)
            System.cmd("git", ["checkout", "-b", branch, "main"], cd: repo_path, stderr_to_stdout: true)
            System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        end
      end
    end
  rescue
    e ->
      Logger.error("[Pipeline] Branch recovery failed: #{Exception.message(e)}")
  end

  defp cleanup_branch(branch, repo_path) do
    # Nuclear cleanup: abort any in-progress operations, hard reset to origin/main
    System.cmd("git", ["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["rebase", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp execute_and_poll(prompt, session_id, item \\ nil) do
    # Swarm dispatch: use SwarmMode with pattern selection
    if get_flag(:swarm_dispatch, false) and item != nil do
      execute_via_swarm(prompt, session_id, item)
    else
      # Specialist routing: let Orchestrator auto-decompose and route
      enable_specialist_routing = get_flag(:specialist_routing, true)
      opts =
        if enable_specialist_routing do
          Logger.info("[Pipeline] Stage 1: Using specialist routing (Orchestrator auto-decomposition)")
          [max_iterations: @agent_max_iterations, tier: :elite]
        else
          [force_simple: true, max_iterations: @agent_max_iterations, tier: :elite]
        end

      case Orchestrator.execute(prompt, session_id, opts) do
        {:ok, task_id} -> await_orchestrator_completion(task_id)
        {:error, reason} -> {:failed, reason}
      end
    end
  end

  defp execute_via_swarm(prompt, session_id, item) do
    pattern = select_swarm_pattern(item)
    Logger.info("[Pipeline] Stage 1: Using swarm pattern #{inspect(pattern)}")

    case SwarmMode.launch(prompt,
           pattern: pattern,
           session_id: session_id,
           timeout_ms: @orchestrator_timeout_ms
         ) do
      {:ok, swarm_id} ->
        await_swarm_completion(swarm_id)

      {:error, reason} ->
        Logger.warning("[Pipeline] Swarm launch failed, falling back to simple dispatch: #{inspect(reason)}")
        opts = [force_simple: true, max_iterations: @agent_max_iterations, tier: :elite]

        case Orchestrator.execute(prompt, session_id, opts) do
          {:ok, task_id} -> await_orchestrator_completion(task_id)
          {:error, r} -> {:failed, r}
        end
    end
  end

  defp select_swarm_pattern(item) do
    title = String.downcase(item.title || "")
    desc = String.downcase(item.description || "")
    text = title <> " " <> desc

    cond do
      String.contains?(text, "security") or String.contains?(text, "audit") -> :debate
      String.contains?(text, "test") or String.contains?(text, "spec") -> :review
      String.contains?(text, "refactor") or String.contains?(text, "review") -> :review
      String.contains?(text, "debug") or String.contains?(text, "fix") -> :parallel
      String.contains?(text, "pipeline") or String.contains?(text, "migration") -> :pipeline
      true -> :review
    end
  end

  defp await_swarm_completion(swarm_id) do
    deadline = System.monotonic_time(:millisecond) + @orchestrator_timeout_ms
    poll_swarm(swarm_id, deadline)
  end

  defp poll_swarm(swarm_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, :deadline_exceeded}
    else
      case SwarmMode.status(swarm_id) do
        {:ok, %{status: :completed, result: result}} ->
          {:completed, result || ""}

        {:ok, %{status: :failed, error: error}} ->
          {:failed, error}

        {:ok, %{status: status}} when status in [:running, :planning] ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_swarm(swarm_id, deadline)

        {:error, :not_found} ->
          {:failed, :swarm_not_found}

        _ ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_swarm(swarm_id, deadline)
      end
    end
  rescue
    _ -> {:failed, :swarm_poll_error}
  catch
    :exit, _ -> {:failed, :swarm_poll_exit}
  end

  defp verify_and_fix_compilation(item, branch, session_id, repo_path, attempt) do
    if get_flag(:autofixer, true) do
      verify_compilation_autofixer(session_id, repo_path)
    else
      verify_compilation_simple(item, branch, session_id, repo_path, attempt)
    end
  end

  defp verify_compilation_autofixer(session_id, repo_path) do
    case run_compile(repo_path) do
      :ok ->
        :ok

      {:error, _} ->
        Logger.info("[Pipeline] Stage 2 (AutoFixer): delegating compilation fix")

        try do
          case AutoFixer.run(%{
                 type: :compile,
                 session_id: "#{session_id}-autofix",
                 cwd: repo_path,
                 max_iterations: 10,
                 command: "mix compile"
               }) do
            {:ok, %{success: true, iterations: n}} ->
              Logger.info("[Pipeline] Stage 2 (AutoFixer): fixed in #{n} iterations")
              :ok

            {:ok, %{success: false, remaining_errors: errors}} ->
              {:error, {:autofixer_exhausted, Enum.join(errors, "\n")}}

            {:error, reason} ->
              {:error, {:autofixer_error, reason}}
          end
        rescue
          e ->
            Logger.warning("[Pipeline] AutoFixer crashed, falling back: #{Exception.message(e)}")
            verify_compilation_simple(nil, nil, nil, repo_path, 0)
        catch
          :exit, reason ->
            Logger.warning("[Pipeline] AutoFixer exit, falling back: #{inspect(reason)}")
            verify_compilation_simple(nil, nil, nil, repo_path, 0)
        end
    end
  end

  defp verify_compilation_simple(_item, _branch, _session_id, repo_path, attempt)
       when attempt >= @compile_fix_max_attempts do
    case run_compile(repo_path) do
      :ok -> :ok
      {:error, errors} -> {:error, {:max_fix_attempts, errors}}
    end
  end

  defp verify_compilation_simple(item, branch, session_id, repo_path, attempt) do
    case run_compile(repo_path) do
      :ok ->
        :ok

      {:error, errors} ->
        Logger.info("[Pipeline] Stage 2: Compilation failed (attempt #{attempt + 1}), dispatching fix agent")

        fix_prompt = """
        Fix the following compilation errors in this Elixir/OTP codebase.

        ## Repository
        The codebase is at: `#{repo_path}`
        You are on branch `#{branch}`.

        CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
        For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

        ## MANDATORY GIT RULES — VIOLATION = TASK FAILURE
        - NEVER run `git checkout`, `git switch`, or `git branch -D` — stay on `#{branch}`
        - NEVER run `git commit`, `git push`, `git add`, `git stash`, `git merge`, `git rebase`
        - ANY git command that changes branch state will cause your work to be LOST

        ## Compilation Errors
        ```
        #{String.slice(errors, 0, 3000)}
        ```

        ## Instructions
        1. Read the files mentioned in the errors
        2. Fix the compilation errors
        3. Run `mix compile` to verify the fix (use cwd: "#{repo_path}")
        4. If new errors appear, fix those too

        ONLY fix compilation errors. Do NOT add features, refactor, or change behavior.
        Do NOT modify: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
        """

        fix_session = "#{session_id}-fix-#{attempt}"

        case execute_and_poll(fix_prompt, fix_session) do
          {:completed, _} ->
            verify_compilation_simple(item, branch, session_id, repo_path, attempt + 1)

          {:failed, reason} ->
            {:error, {:fix_agent_failed, reason}}

          {:timeout, _} ->
            {:error, :fix_agent_timeout}
        end
    end
  end

  defp run_compile(repo_path) do
    # Use plain `mix compile` — NOT --warnings-as-errors, because this codebase
    # has 60+ pre-existing warnings (Bcrypt, film_pipeline, etc.) that would
    # cause false failures on every agent attempt.
    case System.cmd("mix", ["compile"],
           cd: repo_path, stderr_to_stdout: true,
           env: [{"MIX_ENV", "dev"}, {"ERL_AFLAGS", "+S #{@subprocess_schedulers}:#{@subprocess_schedulers}"}]) do
      {_output, 0} -> :ok
      {output, _} ->
        # Filter out warnings — only report actual errors
        errors = output
          |> String.split("\n")
          |> Enum.filter(fn line ->
            String.contains?(line, "** (CompileError)") or
            String.contains?(line, "error:") or
            String.contains?(line, "== Compilation error")
          end)
          |> Enum.join("\n")

        if errors == "" do
          # Only warnings, no real errors — treat as success
          :ok
        else
          {:error, output}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Stage 2.5: Grounded Reference Verification --

  defp verify_and_fix_references(_branch, _session_id, _repo_path, attempt)
       when attempt > @reference_fix_max_attempts do
    {:error, :max_reference_fix_attempts}
  end

  defp verify_and_fix_references(branch, session_id, repo_path, attempt) do
    case GroundedVerifier.verify(branch, repo_path) do
      {:ok, []} ->
        :ok

      {:ok, warnings} ->
        {:warnings, warnings}

      {:error, violations} ->
        Logger.warning("[Pipeline] Stage 2.5: #{length(violations)} phantom reference(s) found (attempt #{attempt + 1})")
        Enum.each(violations, fn v -> Logger.warning("[Pipeline] Stage 2.5 violation: #{v}") end)

        fix_prompt = """
        Fix the following reference errors in this Elixir/OTP codebase.

        ## Repository
        The codebase is at: `#{repo_path}`
        You are on branch `#{branch}`.

        CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
        For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

        ## MANDATORY GIT RULES — VIOLATION = TASK FAILURE
        - NEVER run `git checkout`, `git switch`, or `git branch -D` — stay on `#{branch}`
        - NEVER run `git commit`, `git push`, `git add`, `git stash`, `git merge`, `git rebase`
        - ANY git command that changes branch state will cause your work to be LOST

        ## Reference Violations
        #{GroundedVerifier.fix_prompt(violations)}

        ## Instructions
        1. For each violation, either CREATE the missing module with real functionality, or CHANGE the code to use an existing module
        2. Run `mix compile` to verify (use cwd: "#{repo_path}")
        3. Do NOT create empty stubs — every module must have real working code

        Do NOT modify: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
        """

        fix_session = "#{session_id}-reffix-#{attempt}"

        case execute_and_poll(fix_prompt, fix_session) do
          {:completed, _} ->
            # Re-verify after fix (also re-check compilation since fix agent may have introduced errors)
            case run_compile(repo_path) do
              :ok -> verify_and_fix_references(branch, session_id, repo_path, attempt + 1)
              {:error, _} -> {:error, :fix_broke_compilation}
            end

          {:failed, reason} ->
            {:error, {:reference_fix_failed, reason}}

          {:timeout, _} ->
            {:error, :reference_fix_timeout}
        end
    end
  end

  defp finalize_branch(item, branch, repo_path) do
    # Last-resort recovery: ensure we're on the correct branch before committing
    recover_branch(branch, repo_path)

    {current_raw, _} = System.cmd("git", ["branch", "--show-current"], cd: repo_path, stderr_to_stdout: true)
    current = String.trim(current_raw)

    if current != branch do
      Logger.error("[Pipeline] Stage 3 ABORT: on #{current}, expected #{branch}. Recovery failed.")
      {:error, {:wrong_branch, current, branch}}
    else
      finalize_branch_impl(item, branch, repo_path)
    end
  end

  defp finalize_branch_impl(item, branch, repo_path) do
    # Resolve any unmerged files by accepting the current version (ours)
    {unmerged, _} = System.cmd("git", ["diff", "--name-only", "--diff-filter=U"], cd: repo_path, stderr_to_stdout: true)
    unmerged_files = unmerged |> String.split("\n", trim: true)
    if unmerged_files != [] do
      Logger.warning("[Pipeline] Stage 3: Resolving #{length(unmerged_files)} unmerged file(s): #{inspect(unmerged_files)}")
      Enum.each(unmerged_files, fn f ->
        System.cmd("git", ["checkout", "--ours", f], cd: repo_path, stderr_to_stdout: true)
        System.cmd("git", ["add", f], cd: repo_path, stderr_to_stdout: true)
      end)
    end

    # Check what files changed
    case System.cmd("git", ["diff", "--name-only", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} when byte_size(output) > 2 ->
        files = output |> String.split("\n", trim: true) |> filter_safe_files()

        if files == [] do
          {:error, :no_changes}
        else
          # Git add only safe files
          System.cmd("git", ["add" | files], cd: repo_path, stderr_to_stdout: true)

          # Commit
          commit_msg = "feat: #{item.title}\n\nSource: #{item.source}\nPriority: #{item.base_priority}\n\nAutonomously generated by WorkDirector staged execution."
          case System.cmd("git", ["commit", "-m", commit_msg], cd: repo_path, stderr_to_stdout: true) do
            {_, 0} ->
              # Push
              case System.cmd("git", ["push", "origin", branch], cd: repo_path, stderr_to_stdout: true) do
                {_, 0} ->
                  # Create draft PR
                  pr_body = "Source: #{item.source}\nPriority: #{item.base_priority}\n\n#{String.slice(item.description || "", 0, 500)}\n\n---\n_Autonomously generated by WorkDirector staged execution._"
                  pr_result = System.cmd("gh", [
                    "pr", "create", "--draft",
                    "--title", item.title,
                    "--repo", @daemon_repo,
                    "--body", pr_body
                  ], cd: repo_path, stderr_to_stdout: true)

                  case pr_result do
                    {url, 0} -> {:ok, %{pr_url: String.trim(url)}}
                    {_, _} -> {:ok, %{pr_url: nil, note: "pushed but PR creation failed"}}
                  end

                {push_err, _} ->
                  {:error, {:push_failed, push_err}}
              end

            {commit_err, _} ->
              {:error, {:commit_failed, commit_err}}
          end
        end

      _ ->
        # Also check untracked files
        case System.cmd("git", ["status", "--porcelain"], cd: repo_path, stderr_to_stdout: true) do
          {output, 0} when byte_size(output) > 2 ->
            # There are changes — extract file paths
            files =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(fn line -> String.slice(line, 3..-1//1) |> String.trim() end)
              |> Enum.reject(&(&1 == ""))
              |> filter_safe_files()

            if files == [] do
              {:error, :no_changes}
            else
              System.cmd("git", ["add" | files], cd: repo_path, stderr_to_stdout: true)
              commit_msg = "feat: #{item.title}\n\nSource: #{item.source}\nPriority: #{item.base_priority}\n\nAutonomously generated by WorkDirector staged execution."
              case System.cmd("git", ["commit", "-m", commit_msg], cd: repo_path, stderr_to_stdout: true) do
                {_, 0} ->
                  case System.cmd("git", ["push", "origin", branch], cd: repo_path, stderr_to_stdout: true) do
                    {_, 0} ->
                      pr_body = "Source: #{item.source}\nPriority: #{item.base_priority}\n\n#{String.slice(item.description || "", 0, 500)}"
                      pr_result = System.cmd("gh", [
                        "pr", "create", "--draft",
                        "--title", item.title,
                        "--repo", @daemon_repo,
                        "--body", pr_body
                      ], cd: repo_path, stderr_to_stdout: true)
                      case pr_result do
                        {url, 0} -> {:ok, %{pr_url: String.trim(url)}}
                        {_, _} -> {:ok, %{pr_url: nil}}
                      end
                    {err, _} -> {:error, {:push_failed, err}}
                  end
                {err, _} -> {:error, {:commit_failed, err}}
              end
            end

          _ ->
            {:error, :no_changes}
        end
    end
  rescue
    e -> {:error, {:finalize_exception, Exception.message(e)}}
  end

  defp filter_safe_files(files) do
    regexes = Enum.map(@protected_path_patterns, &Regex.compile!/1)

    Enum.reject(files, fn file ->
      Enum.any?(regexes, fn regex -> Regex.match?(regex, file) end)
    end)
  end

  defp build_implementation_prompt(item, repo_path, pre_research_context) do
    source_context =
      case item.source do
        :vision ->
          "This task comes from VISION.md — a strategic product goal."

        :issues ->
          number = get_in(item.metadata, ["number"])
          if number, do: "This task comes from GitHub Issue ##{number}. Closes ##{number}.", else: "This task comes from a GitHub Issue."

        :investigation ->
          "This task originated from an investigation finding backed by evidence."

        :fitness ->
          "This task addresses a fitness function violation."

        :manual ->
          "This task was manually submitted by a human operator."
      end

    # Pre-compute codebase context via DispatchIntelligence (zero LLM cost)
    # Use cached result from risk assessment if available
    codebase_context =
      case Process.get(:dispatch_intelligence_cache) do
        %{execution_trace: trace} ->
          Logger.debug("[Pipeline] DispatchIntelligence enriched prompt for '#{item.title}' (cached)")
          trace

        _ ->
          case DispatchIntelligence.enrich(item.title, item.description || "", repo_path) do
            {:ok, %{execution_trace: trace}} ->
              Logger.debug("[Pipeline] DispatchIntelligence enriched prompt for '#{item.title}'")
              trace

            {:error, reason} ->
              Logger.warning("[Pipeline] DispatchIntelligence failed: #{inspect(reason)}")
              ""
          end
      end

    branch = branch_name(item)

    """
    #{source_context}

    ## Repository
    The codebase is located at: `#{repo_path}`
    You are on branch: `#{branch}`

    CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
    Example: shell_execute(command: "mix compile", cwd: "#{repo_path}")
    For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

    ## MANDATORY GIT RULES — VIOLATION = TASK FAILURE
    - NEVER run `git checkout`, `git switch`, or `git branch` — you are already on the correct branch `#{branch}`
    - NEVER run `git commit`, `git push`, `git add`, or `git stash` — post-processing handles this
    - NEVER run `git merge`, `git rebase`, `git cherry-pick`, or `git pull`
    - If you need to see what branch you're on, use `git branch --show-current` ONLY
    - ANY git command that changes branch state will cause your work to be LOST

    #{codebase_context}
    #{pre_research_context}

    ## Task
    **#{item.title}**

    #{item.description}

    ## Instructions
    Your ONLY job is to implement the code changes described above.

    1. Study the reference implementations and file territory above
    2. Implement the changes using file_write / file_edit tools with ABSOLUTE paths
    3. Use shell_execute with cwd: "#{repo_path}" to run `mix compile`
    4. If compilation fails, read the errors and fix them
    5. Run `mix test` for relevant test files (with cwd: "#{repo_path}")
    6. Verify your implementation is complete and compiles cleanly

    IMPORTANT: Do NOT modify any files matching: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
    You MUST make at least one meaningful code change. Finish your implementation — do NOT just explore the codebase.
    """
  end

  defp branch_name(%WorkItem{title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    "workdir/#{slug}"
  end


  defp await_orchestrator_completion(task_id) do
    deadline = System.monotonic_time(:millisecond) + @orchestrator_timeout_ms
    poll_orchestrator(task_id, deadline)
  end

  defp poll_orchestrator(task_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, :deadline_exceeded}
    else
      case Orchestrator.progress(task_id) do
        {:ok, %{status: :completed, synthesis: synthesis}} ->
          {:completed, synthesis || ""}

        {:ok, %{status: :failed, error: error}} ->
          {:failed, error}

        {:ok, %{status: status}} when status in [:running, :planning] ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_orchestrator(task_id, deadline)

        {:error, :not_found} ->
          # Task may have been cleaned up — treat as failure
          {:failed, :task_not_found}

        _ ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_orchestrator(task_id, deadline)
      end
    end
  rescue
    _ -> {:failed, :poll_error}
  catch
    :exit, _ -> {:failed, :poll_exit}
  end
end
