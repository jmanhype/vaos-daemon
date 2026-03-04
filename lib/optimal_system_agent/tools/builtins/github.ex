defmodule OptimalSystemAgent.Tools.Builtins.Github do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @allowed_commands ~w(
    pr_create pr_list pr_view pr_merge
    issue_create issue_list issue_view issue_comment
    repo_view run_list run_view
  )

  @gh_timeout 30_000

  @impl true
  def name, do: "github"

  @impl true
  def description,
    do:
      "Interact with GitHub — create PRs, list issues, view CI runs, comment, and more via the gh CLI. " <>
        "Requires gh (GitHub CLI) to be installed and authenticated."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "enum" => @allowed_commands,
          "description" =>
            "GitHub operation: pr_create, pr_list, pr_view, pr_merge, " <>
              "issue_create, issue_list, issue_view, issue_comment, repo_view, run_list, run_view"
        },
        "args" => %{
          "type" => "object",
          "description" =>
            "Command-specific arguments. " <>
              "pr_create: {title, body, base?, draft?}. " <>
              "pr_list: {state?, limit?}. " <>
              "pr_view: {number, json?}. " <>
              "pr_merge: {number, method?}. " <>
              "issue_create: {title, body, label?}. " <>
              "issue_list: {state?, limit?}. " <>
              "issue_view: {number}. " <>
              "issue_comment: {number, body}. " <>
              "repo_view: {json?}. " <>
              "run_list: {limit?}. " <>
              "run_view: {run_id}"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def available? do
    System.find_executable("gh") != nil
  end

  @impl true
  def execute(%{"command" => command} = params) do
    with :ok <- validate_command(command),
         :ok <- check_gh_installed(),
         :ok <- check_gh_auth() do
      args_map = Map.get(params, "args", %{}) || %{}
      run_command(command, args_map)
    end
  end

  def execute(_), do: {:error, "Missing required parameter: command"}

  # --- Command dispatch ---

  defp run_command("pr_create", args) do
    title = Map.get(args, "title")
    body = Map.get(args, "body")

    if is_nil(title) or title == "" do
      {:error, "pr_create requires: title"}
    else
      cli_args =
        ["pr", "create", "--title", title, "--body", body || ""]
        |> maybe_append(args["base"], "--base", args["base"])
        |> maybe_flag(args["draft"], "--draft")

      gh(cli_args)
    end
  end

  defp run_command("pr_list", args) do
    cli_args =
      ["pr", "list"]
      |> maybe_append(args["state"], "--state", args["state"])
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))

    gh(cli_args)
  end

  defp run_command("pr_view", args) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "pr_view requires: number"}
    else
      cli_args =
        ["pr", "view", to_string(number)]
        |> maybe_append(args["json"], "--json", args["json"])

      gh(cli_args)
    end
  end

  defp run_command("pr_merge", args) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "pr_merge requires: number"}
    else
      method = args["method"] || "merge"

      flag =
        case method do
          "squash" -> "--squash"
          "rebase" -> "--rebase"
          _ -> "--merge"
        end

      gh(["pr", "merge", to_string(number), flag])
    end
  end

  defp run_command("issue_create", args) do
    title = Map.get(args, "title")
    body = Map.get(args, "body")

    if is_nil(title) or title == "" do
      {:error, "issue_create requires: title"}
    else
      cli_args =
        ["issue", "create", "--title", title, "--body", body || ""]
        |> maybe_append(args["label"], "--label", args["label"])

      gh(cli_args)
    end
  end

  defp run_command("issue_list", args) do
    cli_args =
      ["issue", "list"]
      |> maybe_append(args["state"], "--state", args["state"])
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))

    gh(cli_args)
  end

  defp run_command("issue_view", args) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "issue_view requires: number"}
    else
      gh(["issue", "view", to_string(number)])
    end
  end

  defp run_command("issue_comment", args) do
    number = Map.get(args, "number")
    body = Map.get(args, "body")

    cond do
      is_nil(number) -> {:error, "issue_comment requires: number"}
      is_nil(body) or body == "" -> {:error, "issue_comment requires: body"}
      true -> gh(["issue", "comment", to_string(number), "--body", body])
    end
  end

  defp run_command("repo_view", args) do
    cli_args =
      ["repo", "view"]
      |> maybe_append(args["json"], "--json", args["json"])

    gh(cli_args)
  end

  defp run_command("run_list", args) do
    cli_args =
      ["run", "list"]
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))

    gh(cli_args)
  end

  defp run_command("run_view", args) do
    run_id = Map.get(args, "run_id")

    if is_nil(run_id) do
      {:error, "run_view requires: run_id"}
    else
      gh(["run", "view", to_string(run_id)])
    end
  end

  defp run_command(cmd, _args) do
    {:error,
     "Unknown command: #{cmd}. Valid: #{Enum.join(@allowed_commands, ", ")}"}
  end

  # --- Helpers ---

  defp gh(args) do
    task =
      Task.async(fn ->
        System.cmd("gh", args, stderr_to_stdout: true, cd: File.cwd!())
      end)

    case Task.yield(task, @gh_timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        out = String.trim(output)
        {:ok, if(out == "", do: "(no output)", else: out)}

      {:ok, {output, _code}} ->
        {:error, String.trim(output)}

      nil ->
        {:error, "gh command timed out after #{div(@gh_timeout, 1000)}s"}
    end
  rescue
    e -> {:error, "gh command failed: #{Exception.message(e)}"}
  end

  defp validate_command(command) do
    if command in @allowed_commands do
      :ok
    else
      {:error,
       "Unknown command: #{command}. Valid commands: #{Enum.join(@allowed_commands, ", ")}"}
    end
  end

  defp check_gh_installed do
    case System.find_executable("gh") do
      nil ->
        {:error,
         "gh (GitHub CLI) is not installed. Install from https://cli.github.com/"}

      _ ->
        :ok
    end
  end

  defp check_gh_auth do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        trimmed = String.trim(output)

        if String.contains?(trimmed, "not logged") or String.contains?(trimmed, "unauthenticated") do
          {:error,
           "gh is not authenticated. Run: gh auth login"}
        else
          # auth status sometimes exits non-zero but is still valid; treat as ok
          :ok
        end
    end
  rescue
    _ -> {:error, "Could not verify gh authentication status"}
  end

  # Append [flag, value] to list only when condition is truthy and value is non-empty.
  defp maybe_append(list, condition, flag, value) do
    if condition && value != nil && value != "" do
      list ++ [flag, to_string(value)]
    else
      list
    end
  end

  # Append a boolean flag to the list only when condition is truthy.
  defp maybe_flag(list, condition, flag) do
    if condition, do: list ++ [flag], else: list
  end
end
