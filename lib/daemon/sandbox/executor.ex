defmodule Daemon.Sandbox.Executor do
  @moduledoc """
  Unified execution interface for sandboxed skill commands.

  This is the single entry-point that `ShellExecute` (and any other skill)
  calls instead of invoking `System.cmd` directly.

  ## Routing logic

  ```
  sandbox_enabled? AND mode == :docker AND Docker.available?
    → Docker.execute/2  (full OS-level isolation)

  sandbox_enabled? AND mode == :docker AND Docker NOT available
    → {:error, "Docker sandbox enabled but Docker is not available"}
    (caller decides whether to fall back or surface the error to the user)

  sandbox_enabled? AND mode == :beam
    → beam_execute/2  (BEAM Task + timeout, no Docker)

  sandbox_enabled? == false (default)
    → beam_execute/2  (legacy behaviour, unchanged)
  ```

  ## Defense in depth

  The existing command blocklist + pattern checks in `ShellExecute` run
  **before** this module is called. The sandbox is a second, independent
  layer — not a replacement for those checks.
  """

  require Logger

  alias Daemon.Sandbox.{Config, Docker, Sprites, Wasm}

  @type exec_result ::
          {:ok, output :: String.t()}
          | {:ok, output :: String.t(), exit_code :: non_neg_integer()}
          | {:error, reason :: String.t()}

  @doc """
  Execute `command` (a shell string) according to the current sandbox config.

  ## Options

  All options are forwarded to the underlying backend:

  - `:timeout`    — ms, default 30_000
  - `:cwd`        — working directory (BEAM mode only; Docker always uses /workspace)
  - `:network`    — override network flag for this call (Docker mode)
  - `:image`      — override container image for this call (Docker mode)
  - `:extra_env`  — `[{"KEY", "val"}]` env vars to inject (Docker mode)
  - `:workspace`  — override host workspace path (Docker mode)

  ## Return values

  - `{:ok, output, exit_code}` — completed; caller should check exit_code
  - `{:error, reason}`         — could not start/connect to executor
  """
  @spec execute(String.t(), keyword()) :: exec_result()
  def execute(command, opts \\ []) do
    config = Config.from_config()

    cond do
      config.enabled and config.mode == :docker and Docker.available?() ->
        Logger.debug("[Sandbox.Executor] Routing to Docker sandbox")
        docker_opts = config_to_docker_opts(config, opts)
        Docker.execute(command, docker_opts)

      config.enabled and config.mode == :docker ->
        Logger.error(
          "[Sandbox.Executor] Docker sandbox is enabled but Docker daemon is unreachable"
        )

        {:error,
         "Docker sandbox enabled but Docker is not available. " <>
           "Either start Docker or set DAEMON_SANDBOX_ENABLED=false."}

      config.enabled and config.mode == :sprites and Sprites.available?() ->
        Logger.debug("[Sandbox.Executor] Routing to Sprites sandbox")
        Sprites.execute(command, opts)

      config.enabled and config.mode == :sprites ->
        Logger.error("[Sandbox.Executor] Sprites sandbox enabled but SPRITES_TOKEN not set")

        {:error,
         "Sprites sandbox enabled but SPRITES_TOKEN not set. Set SPRITES_TOKEN or change DAEMON_SANDBOX_MODE."}

      config.enabled and config.mode == :wasm and Wasm.available?() ->
        Logger.debug("[Sandbox.Executor] Routing to WASM sandbox")
        Wasm.execute(command, opts)

      config.enabled and config.mode == :wasm ->
        Logger.error("[Sandbox.Executor] WASM sandbox enabled but wasmtime is not available")

        {:error,
         "WASM sandbox enabled but wasmtime is not available. Install wasmtime or set DAEMON_SANDBOX_MODE=beam."}

      config.enabled and config.mode == :beam ->
        Logger.debug("[Sandbox.Executor] Routing to BEAM sandbox (mode=:beam)")
        beam_execute(command, opts)

      true ->
        # Sandbox disabled — use existing BEAM process execution (unchanged behaviour)
        Logger.debug("[Sandbox.Executor] Sandbox disabled — BEAM fallback")
        beam_execute(command, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Run command in a supervised BEAM Task with a timeout.
  # This replicates the original ShellExecute behaviour so disabling the sandbox
  # is a true no-op.
  @spec beam_execute(String.t(), keyword()) :: exec_result()
  # Cap subprocess BEAM VMs to 4 schedulers to prevent CPU/memory exhaustion.
  # Commands like `mix test` or `mix compile` spawn a new BEAM VM that defaults
  # to using all CPU cores — on a 10-core Mac Mini this causes load avg 30+.
  @subprocess_schedulers 4
  # Global concurrency limit — prevents memory exhaustion from dozens of
  # simultaneous mix test / mix compile subprocesses. Each mix test can spawn
  # child BEAM VMs, so 3 concurrent slots × N children = still plenty of load.
  @max_concurrent_subprocesses 3
  @concurrency_table :daemon_executor_slots

  defp beam_execute(command, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    cwd = Keyword.get(opts, :cwd, nil)

    case checkout_slot() do
      :ok ->
        parent = self()
        os_pid_ref = make_ref()

        try do
          task =
            Task.async(fn ->
              try do
                {shell, shell_args} = resolve_shell()
                env = subprocess_env()
                  |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

                port_opts = [:binary, :exit_status, :stderr_to_stdout, args: shell_args ++ [command], env: env]
                port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

                port = Port.open({:spawn_executable, to_charlist(shell)}, port_opts)
                {:os_pid, os_pid} = Port.info(port, :os_pid)
                send(parent, {os_pid_ref, os_pid})

                collect_port_output(port, [])
              rescue
                e -> {Exception.message(e), 1}
              end
            end)

          # Receive OS PID from the task (arrives almost immediately)
          os_pid = receive do
            {^os_pid_ref, pid} -> pid
          after
            5_000 -> nil
          end

          case Task.yield(task, timeout) || Task.shutdown(task) do
            {:ok, {output, exit_code}} ->
              {:ok, output, exit_code}

            nil ->
              if os_pid, do: kill_process_tree(os_pid)
              Logger.warning("[Sandbox.Executor] BEAM task timed out after #{timeout}ms")
              {:error, "Command timed out after #{timeout}ms"}
          end
        after
          checkin_slot()
        end

      :full ->
        Logger.warning("[Sandbox.Executor] All #{@max_concurrent_subprocesses} subprocess slots full, rejecting command")
        {:error, "Subprocess concurrency limit reached (#{@max_concurrent_subprocesses} slots full)"}
    end
  end

  # Collect all output from a Port until it exits.
  # Returns {output_binary, exit_code} matching System.cmd's return format.
  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | acc])
      {^port, {:exit_status, status}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end

  # Kill an OS process and all its children (the entire process tree).
  # This prevents orphaned beam.smp processes when mix test/compile times out.
  defp kill_process_tree(os_pid) do
    Logger.warning("[Sandbox.Executor] Killing process tree (OS PID #{os_pid})")
    # Kill children first, then parent. pkill -P sends to children of the given PID.
    System.cmd("sh", ["-c", "pkill -9 -P #{os_pid} 2>/dev/null; kill -9 #{os_pid} 2>/dev/null"],
      stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  # -- Global subprocess concurrency limiter (ETS counter) --

  @doc false
  def init_concurrency_table do
    if :ets.whereis(@concurrency_table) == :undefined do
      :ets.new(@concurrency_table, [:named_table, :public, :set])
      :ets.insert(@concurrency_table, {:slots_used, 0})
    end
    :ok
  end

  defp checkout_slot do
    init_concurrency_table()
    # Atomic increment — returns new value
    count = :ets.update_counter(@concurrency_table, :slots_used, {2, 1})
    if count > @max_concurrent_subprocesses do
      # Over limit — decrement back and reject
      :ets.update_counter(@concurrency_table, :slots_used, {2, -1})
      :full
    else
      :ok
    end
  end

  defp checkin_slot do
    try do
      :ets.update_counter(@concurrency_table, :slots_used, {2, -1, 0, 0})
    rescue
      ArgumentError -> :ok
    end
    :ok
  end

  # Resolve the shell to use for command execution.
  # On Windows, `sh` may not be in Erlang's PATH even if Git for Windows is installed.
  # We try (in order): `sh` from PATH, known Git/WSL paths, then fall back to cmd.exe.
  @spec resolve_shell() :: {String.t(), [String.t()]}
  defp resolve_shell do
    case :os.type() do
      {:win32, _} ->
        sh =
          System.find_executable("sh") ||
            Enum.find_value(
              [
                "C:/Program Files/Git/usr/bin/sh.exe",
                "C:/Program Files (x86)/Git/usr/bin/sh.exe"
              ],
              fn path -> if File.exists?(path), do: path end
            )

        if sh do
          {sh, ["-c"]}
        else
          {"cmd.exe", ["/c"]}
        end

      _ ->
        {System.find_executable("sh") || "/bin/sh", ["-c"]}
    end
  end

  # Merge config-level Docker options with per-call overrides.
  # The :image key in call_opts is validated against the allowlist before use;
  # any disallowed image is rejected and the config default is used instead.
  @spec config_to_docker_opts(Config.t(), keyword()) :: keyword()
  defp config_to_docker_opts(config, call_opts) do
    requested_image = Keyword.get(call_opts, :image, config.image)

    verified_image =
      if Config.image_allowed?(config, requested_image) do
        requested_image
      else
        Logger.warning(
          "[Sandbox.Executor] Rejected disallowed image: #{requested_image}, using #{config.image}"
        )

        config.image
      end

    config_defaults = [
      timeout: config.timeout,
      network: config.network,
      max_memory: config.max_memory,
      max_cpu: config.max_cpu,
      image: verified_image
    ]

    # Strip :image from call_opts so the verified value above is used
    Keyword.merge(config_defaults, Keyword.delete(call_opts, :image))
  end

  # Environment variables injected into all subprocesses.
  # Limits BEAM VM schedulers + disables crash dumps for child processes.
  defp subprocess_env do
    [
      {"ERL_AFLAGS", "+S #{@subprocess_schedulers}:#{@subprocess_schedulers}"},
      {"ERL_CRASH_DUMP_BYTES", "0"}
    ]
  end
end
