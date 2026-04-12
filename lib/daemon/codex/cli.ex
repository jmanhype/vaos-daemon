defmodule Daemon.Codex.CLI do
  @moduledoc """
  Thin wrapper around the local Codex CLI for non-interactive automation runs.
  """

  @type exec_opt ::
          {:cd, String.t()}
          | {:model, String.t()}
          | {:profile, String.t()}
          | {:sandbox, String.t()}
          | {:output_last_message, String.t()}
          | {:idle_timeout_ms, non_neg_integer()}
          | {:json, boolean()}
          | {:skip_git_repo_check, boolean()}
          | {:full_auto, boolean()}
          | {:danger_full_access, boolean()}

  @spec available?() :: boolean()
  def available?, do: executable() != nil

  @spec executable() :: String.t() | nil
  def executable, do: System.find_executable("codex")

  @spec exec_args(String.t(), [exec_opt()]) :: [String.t()]
  def exec_args(prompt, opts \\ []) when is_binary(prompt) do
    cd = Keyword.get(opts, :cd, File.cwd!())

    flags =
      []
      |> put_option("--cd", cd)
      |> put_option("--model", Keyword.get(opts, :model))
      |> put_option("--profile", Keyword.get(opts, :profile))
      |> put_option("--sandbox", Keyword.get(opts, :sandbox))
      |> put_option("--output-last-message", Keyword.get(opts, :output_last_message))
      |> put_flag("--json", Keyword.get(opts, :json, false))
      |> put_flag("--skip-git-repo-check", Keyword.get(opts, :skip_git_repo_check, false))
      |> put_execution_mode(opts)

    ["exec" | flags] ++ [prompt]
  end

  @spec run_exec(String.t(), [exec_opt()]) ::
          {:ok, non_neg_integer()} | {:idle_timeout, pos_integer()} | {:error, String.t()}
  def run_exec(prompt, opts \\ []) when is_binary(prompt) do
    case executable() do
      nil ->
        {:error, "codex executable not found in PATH"}

      executable ->
        args = exec_args(prompt, opts)
        cwd = Keyword.get(opts, :cd, File.cwd!())
        idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, 0)

        try do
          port =
            Port.open(
              {:spawn_executable, executable},
              [
                {:args, args},
                :stream,
                :binary,
                :exit_status,
                :stderr_to_stdout,
                {:cd, String.to_charlist(cwd)}
              ]
            )

          case stream_port(port, idle_timeout_ms) do
            {:idle_timeout, timeout_ms} -> {:idle_timeout, timeout_ms}
            code -> {:ok, code}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  defp put_option(args, _flag, nil), do: args
  defp put_option(args, flag, value), do: args ++ [flag, value]

  defp put_flag(args, _flag, false), do: args
  defp put_flag(args, _flag, nil), do: args
  defp put_flag(args, flag, true), do: args ++ [flag]

  defp put_execution_mode(args, opts) do
    cond do
      Keyword.get(opts, :danger_full_access, false) ->
        args ++ ["--dangerously-bypass-approvals-and-sandbox"]

      Keyword.get(opts, :full_auto, true) ->
        args ++ ["--full-auto"]

      true ->
        args
    end
  end

  defp stream_port(port, idle_timeout_ms)
       when is_integer(idle_timeout_ms) and idle_timeout_ms > 0 do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_port(port, idle_timeout_ms)

      {^port, {:exit_status, code}} ->
        code
    after
      idle_timeout_ms ->
        terminate_port(port)
        {:idle_timeout, idle_timeout_ms}
    end
  end

  defp stream_port(port, _idle_timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_port(port, 0)

      {^port, {:exit_status, code}} ->
        code
    end
  end

  defp terminate_port(port) do
    port
    |> port_os_pid()
    |> terminate_process_tree()

    safe_port_close(port)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      [{:os_pid, os_pid}] when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp terminate_process_tree(nil), do: :ok

  defp terminate_process_tree(os_pid) when is_integer(os_pid) do
    Enum.each(child_pids(os_pid), &terminate_process_tree/1)
    send_signal(os_pid, "-TERM")
    Process.sleep(200)
    send_signal(os_pid, "-KILL")
  end

  defp child_pids(os_pid) do
    case System.find_executable("pgrep") do
      nil ->
        []

      executable ->
        case System.cmd(executable, ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.flat_map(fn line ->
              case Integer.parse(String.trim(line)) do
                {pid, ""} -> [pid]
                _ -> []
              end
            end)

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  defp send_signal(os_pid, signal) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        _ = System.cmd(executable, [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end
end
