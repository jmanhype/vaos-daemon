defmodule OptimalSystemAgent.Tools.Builtins.ComputeVm do
  @behaviour MiosaTools.Behaviour

  require Logger

  @moduledoc """
  HTTP client for the miosa-compute API.

  Exposes VM lifecycle and execution operations as a single OSA tool.
  The LLM picks the operation via the `operation` parameter.

  Base URL: MIOSA_COMPUTE_URL env var (default http://localhost:4001).

  ## Operations

    - `create`     — boot a new VM from a template
    - `status`     — poll VM state (creating | running | paused | stopped)
    - `wait`       — block until VM reaches running state (polls every 3s, default 120s timeout)
    - `exec`       — run a shell command inside the VM and return stdout/stderr
    - `read_file`  — read a file from the VM filesystem
    - `write_file` — write/overwrite a file on the VM filesystem
    - `destroy`    — shut down and remove the VM

  ## Example (ReAct experiment loop)

      # 1. Boot
      compute_vm(operation: create, template_id: python-ml, size: medium)
      # → {vm_id: "vm_abc123"}

      # 2. Wait until running
      compute_vm(operation: wait, vm_id: vm_abc123)
      # → "VM vm_abc123 is running"

      # 3. Write train.py
      compute_vm(operation: write_file, vm_id: vm_abc123, path: /workspace/train.py, content: "...")

      # 4. Run 5-minute experiment
      compute_vm(operation: exec, vm_id: vm_abc123,
                 command: "timeout 300 python train.py 2>&1 | tail -20",
                 timeout: 320)

      # 5. Read result
      compute_vm(operation: read_file, vm_id: vm_abc123, path: /workspace/val_bpb.txt)

      # 6. Cleanup
      compute_vm(operation: destroy, vm_id: vm_abc123)
  """

  @default_base_url "http://localhost:4001"
  # 6 min — covers the 5-min training + overhead
  @exec_default_timeout_s 360

  # ── Behaviour callbacks ────────────────────────────────────────────

  @impl true
  def name, do: "compute_vm"

  @impl true
  def description,
    do:
      "Manage Firecracker microVMs for isolated ML experiments. " <>
        "Supports: create, status, wait (poll until running), exec (run shell command), read_file, write_file, destroy."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => ["create", "status", "wait", "exec", "read_file", "write_file", "destroy"],
          "description" => "The operation to perform on the VM"
        },
        "vm_id" => %{
          "type" => "string",
          "description" => "VM identifier (required for all operations except create)"
        },
        "template_id" => %{
          "type" => "string",
          "description" =>
            "Template to boot from (create only). Use 'python-ml' for PyTorch experiments."
        },
        "size" => %{
          "type" => "string",
          "enum" => ["small", "medium", "large"],
          "description" =>
            "VM size (create only): small=1vCPU/512MB, medium=2vCPU/2GB, large=2vCPU/4GB"
        },
        "gpu" => %{
          "type" => "boolean",
          "description" => "Request GPU passthrough (requires GPU-enabled host)"
        },
        "timeout_s" => %{
          "type" => "integer",
          "description" => "Wait timeout in seconds (wait only, default 120)"
        },
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run (exec only)"
        },
        "timeout" => %{
          "type" => "integer",
          "description" =>
            "Exec timeout in seconds (exec only, default #{@exec_default_timeout_s})"
        },
        "path" => %{
          "type" => "string",
          "description" => "Absolute file path inside the VM (read_file / write_file)"
        },
        "content" => %{
          "type" => "string",
          "description" => "File content to write (write_file only)"
        }
      },
      "required" => ["operation"]
    }
  end

  @impl true
  def execute(%{"operation" => op} = params) do
    base = base_url()

    case op do
      "create" ->
        create_vm(base, params)

      "status" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          get_vm(base, vm_id)
        end

      "wait" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          timeout_s = Map.get(params, "timeout_s", 120)
          wait_until_running(base, vm_id, timeout_s)
        end

      "exec" ->
        with {:ok, vm_id} <- require_param(params, "vm_id"),
             {:ok, command} <- require_param(params, "command") do
          exec_command(base, vm_id, command, Map.get(params, "timeout", @exec_default_timeout_s))
        end

      "read_file" ->
        with {:ok, vm_id} <- require_param(params, "vm_id"),
             {:ok, path} <- require_param(params, "path") do
          read_file(base, vm_id, path)
        end

      "write_file" ->
        with {:ok, vm_id} <- require_param(params, "vm_id"),
             {:ok, path} <- require_param(params, "path"),
             {:ok, content} <- require_param(params, "content") do
          write_file(base, vm_id, path, content)
        end

      "destroy" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          destroy_vm(base, vm_id)
        end

      _ ->
        {:error,
         "Unknown operation '#{op}'. Valid: create, status, wait, exec, read_file, write_file, destroy"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: operation"}

  # ── API calls ─────────────────────────────────────────────────────

  defp create_vm(base, params) do
    body =
      %{}
      |> maybe_put("template_id", Map.get(params, "template_id", "python-ml"))
      |> maybe_put("size", Map.get(params, "size", "medium"))
      |> maybe_put("gpu", Map.get(params, "gpu"))

    case post(base, "/api/v1/vms", body) do
      {:ok, %{"id" => id, "status" => status}} ->
        {:ok, "VM created. vm_id=#{id} status=#{status}"}

      {:ok, %{"vm_id" => id}} ->
        {:ok, "VM created. vm_id=#{id}"}

      {:ok, resp} ->
        {:ok, "VM created. #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "create failed: #{reason}"}
    end
  end

  defp get_vm(base, vm_id) do
    case get(base, "/api/v1/vms/#{vm_id}") do
      {:ok, %{"status" => status} = vm} ->
        ip = Map.get(vm, "ip_address", "unknown")
        {:ok, "VM #{vm_id}: status=#{status} ip=#{ip}"}

      {:ok, resp} ->
        {:ok, inspect(resp)}

      {:error, reason} ->
        {:error, "status failed: #{reason}"}
    end
  end

  @wait_poll_interval_ms 3_000
  @terminal_vm_states ["stopped", "destroyed", "error"]

  defp wait_until_running(base, vm_id, timeout_s) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_s * 1_000
    do_wait(base, vm_id, deadline_ms, timeout_s)
  end

  defp do_wait(base, vm_id, deadline_ms, timeout_s) do
    case get(base, "/api/v1/vms/#{vm_id}") do
      {:ok, %{"status" => "running"}} ->
        {:ok, "VM #{vm_id} is running"}

      {:ok, %{"status" => status}} when status in @terminal_vm_states ->
        {:error, "VM #{vm_id} reached terminal state '#{status}' — cannot continue waiting"}

      {:ok, _} ->
        now_ms = System.monotonic_time(:millisecond)

        if now_ms >= deadline_ms do
          {:error, "VM did not reach running state in #{timeout_s}s"}
        else
          Process.sleep(@wait_poll_interval_ms)
          do_wait(base, vm_id, deadline_ms, timeout_s)
        end

      {:error, reason} ->
        {:error, "wait failed while polling VM #{vm_id}: #{reason}"}
    end
  end

  defp exec_command(base, vm_id, command, timeout_s) when is_integer(timeout_s) do
    body = %{"command" => command, "timeout" => timeout_s}

    # HTTP request timeout must exceed the exec timeout
    http_timeout_ms = (timeout_s + 30) * 1_000

    case post(base, "/api/v1/vms/#{vm_id}/exec", body, recv_timeout: http_timeout_ms) do
      {:ok, %{"stdout" => stdout, "exit_code" => code}} ->
        stderr = Map.get(body, "stderr", "")

        output =
          [stdout, stderr]
          |> Enum.reject(&(&1 == "" or is_nil(&1)))
          |> Enum.join("\n")

        if code == 0 do
          {:ok, output}
        else
          {:error, "Exit #{code}:\n#{output}"}
        end

      {:ok, %{"output" => out, "exit_code" => code}} ->
        if code == 0, do: {:ok, out}, else: {:error, "Exit #{code}:\n#{out}"}

      {:ok, resp} ->
        {:ok, inspect(resp)}

      {:error, reason} ->
        {:error, "exec failed: #{reason}"}
    end
  end

  defp exec_command(base, vm_id, command, timeout_s) do
    parsed =
      cond do
        is_binary(timeout_s) -> String.to_integer(timeout_s)
        true -> @exec_default_timeout_s
      end

    exec_command(base, vm_id, command, parsed)
  end

  defp read_file(base, vm_id, path) do
    case get(base, "/api/v1/vms/#{vm_id}/files?path=#{URI.encode(path)}") do
      {:ok, %{"content" => content}} ->
        {:ok, content}

      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, resp} ->
        {:ok, inspect(resp)}

      {:error, reason} ->
        {:error, "read_file failed: #{reason}"}
    end
  end

  defp write_file(base, vm_id, path, content) do
    body = %{"path" => path, "content" => content}

    case post(base, "/api/v1/vms/#{vm_id}/files", body) do
      {:ok, _} ->
        {:ok, "Written #{byte_size(content)} bytes to #{path} on VM #{vm_id}"}

      {:error, reason} ->
        {:error, "write_file failed: #{reason}"}
    end
  end

  defp destroy_vm(base, vm_id) do
    case delete(base, "/api/v1/vms/#{vm_id}") do
      {:ok, _} -> {:ok, "VM #{vm_id} destroyed"}
      {:error, reason} -> {:error, "destroy failed: #{reason}"}
    end
  end

  # ── HTTP helpers ──────────────────────────────────────────────────

  defp get(base, path, opts \\ []) do
    url = base <> path
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    case Req.get(url, receive_timeout: timeout, connect_options: [timeout: 5_000]) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        {:ok, maybe_decode(body)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Not found: #{path}"}

      {:ok, %Req.Response{status: s, body: body}} ->
        {:error, "HTTP #{s}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp post(base, path, body, opts \\ []) do
    url = base <> path
    timeout = Keyword.get(opts, :recv_timeout, 60_000)

    case Req.post(url,
           json: body,
           receive_timeout: timeout,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: s, body: resp_body}} when s in 200..299 ->
        {:ok, maybe_decode(resp_body)}

      {:ok, %Req.Response{status: s, body: resp_body}} ->
        {:error, "HTTP #{s}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp delete(base, path) do
    url = base <> path

    case Req.delete(url, receive_timeout: 15_000, connect_options: [timeout: 5_000]) do
      {:ok, %Req.Response{status: s}} when s in 200..299 -> {:ok, :deleted}
      {:ok, %Req.Response{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp maybe_decode(body) when is_map(body), do: body
  defp maybe_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end
  defp maybe_decode(body), do: body

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "Missing required parameter for this operation: #{key}"}
      "" -> {:error, "Parameter '#{key}' must not be empty"}
      value -> {:ok, value}
    end
  end

  defp base_url do
    System.get_env("MIOSA_COMPUTE_URL") ||
      Application.get_env(:optimal_system_agent, :miosa_compute_url, @default_base_url)
  end
end
