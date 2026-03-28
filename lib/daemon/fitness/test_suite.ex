defmodule Daemon.Fitness.TestSuite do
  @moduledoc """
  Fitness function: all tests pass.

  Runs `mix test` and treats any failure as a violation.
  """

  @behaviour Daemon.Fitness

  @impl true
  def name, do: "test_suite"

  @impl true
  def description, do: "All tests pass"

  @impl true
  def evaluate(workspace) do
    case Daemon.Sandbox.Executor.execute(
           "mix test --no-color 2>&1",
           cwd: workspace,
           timeout: 300_000
         ) do
      {:ok, _output, 0} ->
        {:kept, 1.0, "All tests pass"}

      {:ok, output, _code} ->
        failures = extract_failures(output)
        {:not_kept, score(output), Enum.join(failures, "\n")}

      {:error, reason} ->
        {:not_kept, 0.0, "Test suite failed to run: #{inspect(reason)}"}
    end
  end

  defp extract_failures(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "** (") or
        String.contains?(line, "test/") or
        String.match?(line, ~r/\d+ failures?/)
    end)
    |> Enum.take(20)
  end

  defp score(output) do
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, output) do
      [_, total, failures] ->
        t = String.to_integer(total)
        f = String.to_integer(failures)
        if t > 0, do: (t - f) / t, else: 0.0

      _ ->
        0.0
    end
  end
end
