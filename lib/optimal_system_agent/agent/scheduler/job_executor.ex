defmodule OptimalSystemAgent.Agent.Scheduler.JobExecutor do
  @moduledoc """
  Executes cron jobs, trigger actions, and agent tasks.

  Handles the four cron job types (agent, command, webhook, unknown), the three
  trigger action types (agent, command, unknown), shell command execution with
  security validation and output limits, outbound HTTP for webhook jobs, and
  template interpolation for trigger payloads.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @max_output_bytes OptimalSystemAgent.Security.ShellPolicy.max_output_bytes()
  @webhook_timeout_ms 10_000

  # ── Cron Job Execution ────────────────────────────────────────────────

  def execute_cron_job(%{"type" => "agent", "job" => task} = job) do
    Logger.debug("Cron '#{job["id"]}': running agent task")
    execute_task(task, "cron_#{job["id"]}")
  end

  def execute_cron_job(%{"type" => "command", "command" => command} = job) do
    Logger.debug("Cron '#{job["id"]}': running command")
    run_shell_command(command)
  end

  def execute_cron_job(%{"type" => "webhook"} = job) do
    url = job["url"] || ""
    method = String.upcase(job["method"] || "GET")
    headers = job["headers"] || %{}

    Logger.debug("Cron '#{job["id"]}': sending #{method} #{url}")

    with :ok <- validate_url(url) do
      case http_request(method, url, headers, "") do
        {:ok, _status, _body} ->
          {:ok, "webhook delivered"}

        {:error, reason} ->
          # on_failure: "agent" falls back to an agent task
          if job["on_failure"] == "agent" && is_binary(job["failure_job"]) do
            Logger.info("Cron '#{job["id"]}': webhook failed, running failure_job via agent")
            execute_task(job["failure_job"], "cron_#{job["id"]}_fallback")
          else
            {:error, reason}
          end
      end
    else
      {:error, reason} ->
        Logger.warning("Cron '#{job["id"]}': blocked webhook to #{url} — #{reason}")
        {:error, reason}
    end
  end

  def execute_cron_job(job) do
    {:error, "Unknown job type: #{inspect(job["type"])}"}
  end

  # ── Trigger Action Execution ──────────────────────────────────────────

  def execute_trigger_action(%{"type" => "agent", "job" => job_template} = trigger, payload) do
    task = interpolate(job_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running agent task")
    execute_task(task, "trigger_#{trigger["id"]}")
  end

  def execute_trigger_action(
        %{"type" => "command", "command" => cmd_template} = trigger,
        payload
      ) do
    command = interpolate(cmd_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running command")
    run_shell_command(command)
  end

  def execute_trigger_action(trigger, _payload) do
    {:error, "Unknown trigger type: #{inspect(trigger["type"])}"}
  end

  # ── Template Interpolation ────────────────────────────────────────────

  @doc """
  Replace {{payload}} with the full payload as JSON, {{timestamp}} with the
  current ISO 8601 timestamp, and {{payload.key}} with a specific top-level key
  value. All substituted values are shell-escaped to prevent injection.
  """
  def interpolate(template, payload) when is_binary(template) and is_map(payload) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    payload_json = Jason.encode!(payload)

    template
    |> String.replace("{{timestamp}}", timestamp)
    |> String.replace("{{payload}}", shell_escape(payload_json))
    |> then(fn t ->
      Regex.replace(~r/\{\{payload\.(\w+)\}\}/, t, fn _match, key ->
        value = Map.get(payload, key)
        if is_nil(value), do: "''", else: shell_escape(to_string(value))
      end)
    end)
  end

  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  def shell_escape(value), do: shell_escape(to_string(value))

  # ── Shell Command Execution ───────────────────────────────────────────

  def run_shell_command(command) when is_binary(command) do
    command =
      command
      |> String.replace(~r/\s*&\s*$/, "")
      |> String.replace(~r/^\s*nohup\s+/, "")
      |> String.trim()

    if command == "" do
      {:error, "Blocked: empty command"}
    else
      case OptimalSystemAgent.Security.ShellPolicy.validate(command) do
        :ok ->
          task =
            Task.async(fn ->
              System.cmd("sh", ["-c", command], stderr_to_stdout: true)
            end)

          case Task.yield(task, 30_000) || Task.shutdown(task) do
            {:ok, {output, 0}} ->
              truncated =
                if byte_size(output) > @max_output_bytes do
                  String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
                else
                  output
                end

              {:ok, truncated}

            {:ok, {output, code}} ->
              {:error, "Exit #{code}:\n#{output}"}

            nil ->
              {:error, "Command timed out after 30 seconds"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Outbound HTTP (webhook type) ──────────────────────────────────────

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_scheme}
      is_nil(uri.host) -> {:error, :no_host}
      uri.host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"] -> {:error, :loopback}
      String.starts_with?(uri.host || "", "169.254.") -> {:error, :link_local}
      String.starts_with?(uri.host || "", "10.") -> {:error, :private}
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, uri.host || "") -> {:error, :private}
      String.starts_with?(uri.host || "", "192.168.") -> {:error, :private}
      true -> :ok
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  def http_request(method, url, headers, body) do
    :ok = :inets.start(:httpc, profile: :default)

    headers_list =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request =
      case method do
        "GET" -> {String.to_charlist(url), headers_list}
        _ -> {String.to_charlist(url), headers_list, ~c"application/json", body}
      end

    opts = [{:timeout, @webhook_timeout_ms}]

    method_atom =
      case String.downcase(method) do
        "get" -> :get
        "post" -> :post
        "put" -> :put
        "delete" -> :delete
        "patch" -> :patch
        _ -> :get
      end

    case :httpc.request(method_atom, request, opts, []) do
      {:ok, {{_vsn, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "HTTP error: #{Exception.message(e)}"}
  end

  # ── Agent Task Execution ──────────────────────────────────────────────

  @doc """
  Start a one-shot agent loop under DynamicSupervisor, run a task through it,
  then stop the loop process. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def execute_task(task_description, session_id) do
    case DynamicSupervisor.start_child(
           OptimalSystemAgent.Channels.Supervisor,
           {Loop, session_id: session_id, channel: :heartbeat}
         ) do
      {:ok, _pid} ->
        result = Loop.process_message(session_id, task_description)

        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] -> GenServer.stop(pid, :normal)
          _ -> :ok
        end

        case result do
          {:ok, response} -> {:ok, response}
          {:filtered, _signal} -> {:ok, "filtered"}
          {:error, reason} -> {:error, to_string(reason)}
        end

      {:error, reason} ->
        {:error, "Failed to start agent loop: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
