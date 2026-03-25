defmodule Daemon.Tools.Builtins.ComputeVm do
  @behaviour MiosaTools.Behaviour

  require Logger

  @moduledoc """
  HTTP client for the miosa-compute API.

  Exposes VM lifecycle and execution operations as a single OSA tool.
  The LLM picks the operation via the `operation` parameter.

  Base URL: MIDAEMON_COMPUTE_URL env var (default http://localhost:4001).
  Auth:      MIDAEMON_COMPUTE_API_KEY env var (optional Bearer token).

  ## Operations

    - `create`      — boot a new VM from a template
    - `list`        — list all VMs (filtered by status if given)
    - `status`      — poll VM state (creating | running | paused | stopped)
    - `wait_ready`  — block until VM reaches `running` state (up to timeout)
    - `exec`        — run a shell command inside the VM and return stdout/stderr
    - `read_file`   — read a file from the VM filesystem
    - `write_file`  — write/overwrite a file on the VM filesystem
    - `snapshot`    — save current VM state as a named snapshot
    - `restart`     — restart a running VM
    - `destroy`     — shut down and remove the VM

  ## Example (ReAct experiment loop)

      # 1. Boot and wait until ready
      compute_vm(operation: create, template_id: python-ml, size: medium, wait: true)
      # → {vm_id: "vm_abc123", status: "running", ip: "192.168.1.2"}

      # 2. Write train.py
      compute_vm(operation: write_file, vm_id: vm_abc123, path: /workspace/train.py, content: "...")

      # 3. Run 5-minute experiment
      compute_vm(operation: exec, vm_id: vm_abc123,
                 command: "timeout 300 python train.py 2>&1 | tail -20",
                 timeout: 320)

      # 4. Read result
      compute_vm(operation: read_file, vm_id: vm_abc123, path: /workspace/val_bpb.txt)

      # 5. Snapshot before cleanup
      compute_vm(operation: snapshot, vm_id: vm_abc123, snapshot_name: exp-001)

      # 6. Cleanup
      compute_vm(operation: destroy, vm_id: vm_abc123)
  """

  @default_base_url "http://localhost:4001"
  # 6 min — covers the 5-min training + overhead
  @exec_default_timeout_s 360
  # wait_ready polling settings
  @wait_ready_interval_ms 2_000
  @wait_ready_default_timeout_s 120

  # ── Behaviour callbacks ────────────────────────────────────────────

  @impl true
  def name, do: "compute_vm"

  @impl true
  def description,
    do:
      "Manage Firecracker microVMs for isolated ML experiments and code execution. " <>
        "Supports: create (with optional wait), list, status, wait_ready, exec (run shell command), " <>
        "read_file, write_file, snapshot, restart, destroy."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => [
            "create",
            "list",
            "status",
            "wait_ready",
            "exec",
            "read_file",
            "write_file",
            "snapshot",
            "restart",
            "destroy"
          ],
          "description" => "The operation to perform on the VM"
        },
        "vm_id" => %{
          "type" => "string",
          "description" => "VM identifier (required for all operations except create and list)"
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
        "wait" => %{
          "type" => "boolean",
          "description" =>
            "If true, wait until VM is running before returning (create only, default false)"
        },
        "status_filter" => %{
          "type" => "string",
          "enum" => ["all", "running", "creating", "stopped", "paused"],
          "description" => "Filter VMs by status (list only, default: all)"
        },
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run (exec only)"
        },
        "timeout" => %{
          "type" => "integer",
          "description" =>
            "Timeout in seconds. For exec: max command duration (default #{@exec_default_timeout_s}). " <>
              "For wait_ready: max time to wait (default #{@wait_ready_default_timeout_s})."
        },
        "path" => %{
          "type" => "string",
          "description" => "Absolute file path inside the VM (read_file / write_file)"
        },
        "content" => %{
          "type" => "string",
          "description" => "File content to write (write_file only)"
        },
        "snapshot_name" => %{
          "type" => "string",
          "description" => "Name for the snapshot (snapshot only, default: auto-generated)"
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

      "list" ->
        list_vms(base, Map.get(params, "status_filter", "all"))

      "status" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          get_vm(base, vm_id)
        end

      "wait_ready" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          timeout_s = Map.get(params, "timeout", @wait_ready_default_timeout_s)
          wait_for_ready(base, vm_id, to_seconds(timeout_s, @wait_ready_default_timeout_s))
        end

      "exec" ->
        with {:ok, vm_id} <- require_param(params, "vm_id"),
             {:ok, command} <- require_param(params, "command") do
          exec_command(
            base,
            vm_id,
            command,
            Map.get(params, "timeout", @exec_default_timeout_s)
          )
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

      "snapshot" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          snapshot_name = Map.get(params, "snapshot_name") || auto_snapshot_name()
          snapshot_vm(base, vm_id, snapshot_name)
        end

      "restart" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          restart_vm(base, vm_id)
        end

      "destroy" ->
        with {:ok, vm_id} <- require_param(params, "vm_id") do
          destroy_vm(base, vm_id)
        end

      _ ->
        {:error,
         "Unknown operation '#{op}'. Valid: create, list, status, wait_ready, exec, read_file, write_file, snapshot, restart, destroy"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: operation"}

  # ── API calls ─────────────────────────────────────────────────────

  defp create_vm(base, params) do
    body =
      %{}
      |> maybe_put("template_id", Map.get(params, "template_id", "python-ml"))
      |> maybe_put("size", Map.get(params, "size", "medium"))

    case post(base, "/api/v1/vms", body) do
      {:ok, resp} ->
        vm_id = Map.get(resp, "id") || Map.get(resp, "vm_id")
        status = Map.get(resp, "status", "creating")

        if vm_id do
          if Map.get(params, "wait", false) do
            case wait_for_ready(base, vm_id, @wait_ready_default_timeout_s) do
              {:ok, ready_msg} -> {:ok, "VM created and ready. vm_id=#{vm_id}\n#{ready_msg}"}
              {:error, reason} -> {:ok, "VM created (vm_id=#{vm_id}) but not yet ready: #{reason}"}
            end
          else
            ip = Map.get(resp, "ip_address", "pending")
            {:ok, "VM created. vm_id=#{vm_id} status=#{status} ip=#{ip}"}
          end
        else
          {:ok, "VM created. #{inspect(resp)}"}
        end

      {:error, reason} ->
        {:error, "create failed: #{reason}"}
    end
  end

  defp list_vms(base, filter) do
    path =
      case filter do
        "all" -> "/api/v1/vms"
        f -> "/api/v1/vms?status=#{f}"
      end

    case get(base, path) do
      {:ok, vms} when is_list(vms) ->
        count = length(vms)

        summary =
          vms
          |> Enum.map(fn vm ->
            id = Map.get(vm, "id") || Map.get(vm, "vm_id", "?")
            st = Map.get(vm, "status", "?")
            ip = Map.get(vm, "ip_address", "")
            ip_part = if ip != "", do: " ip=#{ip}", else: ""
            "  #{id}  status=#{st}#{ip_part}"
          end)
          |> Enum.join("\n")

        {:ok, "#{count} VM(s):\n#{summary}"}

      {:ok, %{"vms" => vms}} when is_list(vms) ->
        list_vms_format(vms)

      {:ok, resp} ->
        {:ok, inspect(resp)}

      {:error, reason} ->
        {:error, "list failed: #{reason}"}
    end
  end

  defp list_vms_format(vms) do
    count = length(vms)

    summary =
      vms
      |> Enum.map(fn vm ->
        id = Map.get(vm, "id") || Map.get(vm, "vm_id", "?")
        st = Map.get(vm, "status", "?")
        "  #{id}  status=#{st}"
      end)
      |> Enum.join("\n")

    {:ok, "#{count} VM(s):\n#{summary}"}
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

  defp wait_for_ready(base, vm_id, timeout_s) do
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1_000
    poll_until_running(base, vm_id, deadline)
  end

  defp poll_until_running(base, vm_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, "VM #{vm_id} did not reach running state within timeout"}
    else
      case get(base, "/api/v1/vms/#{vm_id}") do
        {:ok, %{"status" => "running"} = vm} ->
          ip = Map.get(vm, "ip_address", "unknown")
          {:ok, "VM #{vm_id} is running. ip=#{ip}"}

        {:ok, %{"status" => status}} when status in ["stopped", "failed", "error"] ->
          {:error, "VM #{vm_id} reached terminal state: #{status}"}

        {:ok, _} ->
          Process.sleep(@wait_ready_interval_ms)
          poll_until_running(base, vm_id, deadline)

        {:error, _} ->
          Process.sleep(@wait_ready_interval_ms)
          poll_until_running(base, vm_id, deadline)
      end
    end
  end

  defp exec_command(base, vm_id, command, timeout_s) when is_integer(timeout_s) do
    body = %{"command" => command, "timeout" => timeout_s}

    # HTTP request timeout must exceed the exec timeout
    http_timeout_ms = (timeout_s + 30) * 1_000

    case post(base, "/api/v1/vms/#{vm_id}/exec", body, recv_timeout: http_timeout_ms) do
      {:ok, %{"stdout" => stdout, "exit_code" => code} = resp} ->
        stderr = Map.get(resp, "stderr", "")

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
    exec_command(base, vm_id, command, to_seconds(timeout_s, @exec_default_timeout_s))
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

  defp snapshot_vm(base, vm_id, snapshot_name) do
    body = %{"name" => snapshot_name}

    case post(base, "/api/v1/vms/#{vm_id}/snapshots", body) do
      {:ok, %{"snapshot_id" => sid}} ->
        {:ok, "Snapshot '#{snapshot_name}' created (id=#{sid}) for VM #{vm_id}"}

      {:ok, resp} ->
        {:ok, "Snapshot created: #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "snapshot failed: #{reason}"}
    end
  end

  defp restart_vm(base, vm_id) do
    case post(base, "/api/v1/vms/#{vm_id}/restart", %{}) do
      {:ok, _} ->
        {:ok, "VM #{vm_id} restarting. Use status to check when running."}

      {:error, reason} ->
        {:error, "restart failed: #{reason}"}
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

    case Req.get(url,
           receive_timeout: timeout,
           connect_options: [timeout: 5_000],
           headers: auth_headers()
         ) do
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
           connect_options: [timeout: 5_000],
           headers: auth_headers()
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

    case Req.delete(url,
           receive_timeout: 15_000,
           connect_options: [timeout: 5_000],
           headers: auth_headers()
         ) do
      {:ok, %Req.Response{status: s}} when s in 200..299 -> {:ok, :deleted}
      {:ok, %Req.Response{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp auth_headers do
    case System.get_env("MIDAEMON_COMPUTE_API_KEY") do
      nil -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end
  end

  defp maybe_decode(body) when is_map(body), do: body
  defp maybe_decode(body) when is_list(body), do: body

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

  defp to_seconds(value, _default) when is_integer(value), do: value
  defp to_seconds(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end
  defp to_seconds(_, default), do: default

  defp auto_snapshot_name do
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 19) |> String.replace(":", "-")
    "snap-#{ts}"
  end

  defp base_url do
    System.get_env("MIDAEMON_COMPUTE_URL") ||
      Application.get_env(:daemon, :miosa_compute_url, @default_base_url)
  end
end
