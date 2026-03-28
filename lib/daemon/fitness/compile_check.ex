defmodule Daemon.Fitness.CompileCheck do
  @moduledoc """
  Fitness function: codebase compiles with zero warnings.

  Runs `mix compile --warnings-as-errors` and treats any warning as a violation.
  """

  @behaviour Daemon.Fitness

  @impl true
  def name, do: "compile_check"

  @impl true
  def description, do: "Codebase compiles with zero warnings"

  @impl true
  def evaluate(workspace) do
    case Daemon.Sandbox.Executor.execute(
           "mix compile --warnings-as-errors 2>&1",
           cwd: workspace,
           timeout: 120_000
         ) do
      {:ok, _output, 0} ->
        {:kept, 1.0, "Clean compilation"}

      {:ok, output, _code} ->
        warnings = extract_warnings(output)
        {:not_kept, score(warnings), Enum.join(warnings, "\n")}

      {:error, reason} ->
        {:not_kept, 0.0, "Compile check failed to run: #{inspect(reason)}"}
    end
  end

  defp extract_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "warning:"))
    |> Enum.uniq()
  end

  defp score(warnings) do
    max(0.0, 1.0 - length(warnings) * 0.1)
  end
end
