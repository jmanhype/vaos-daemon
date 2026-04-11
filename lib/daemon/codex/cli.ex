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

  @spec run_exec(String.t(), [exec_opt()]) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run_exec(prompt, opts \\ []) when is_binary(prompt) do
    case executable() do
      nil ->
        {:error, "codex executable not found in PATH"}

      executable ->
        args = exec_args(prompt, opts)
        cwd = Keyword.get(opts, :cd, File.cwd!())

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

          {:ok, stream_port(port)}
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

  defp stream_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_port(port)

      {^port, {:exit_status, code}} ->
        code
    end
  end
end
