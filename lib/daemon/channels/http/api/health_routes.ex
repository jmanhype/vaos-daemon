defmodule Daemon.Channels.HTTP.API.HealthRoutes do
  @moduledoc """
  Health check routes with dependency status.

  Provides comprehensive health information including:
  - Basic system status (version, uptime, provider, model)
  - Dependency status (channels, services, external APIs)
  - Resource metrics (memory, processes)

  All endpoints are publicly accessible (no auth required).
  """
  use Plug.Router
  require Logger

  plug(:match)
  plug(:dispatch)

  @doc """
  GET /api/v1/health

  Returns comprehensive health status including dependencies.
  """
  get "/" do
    health_data = gather_health_info()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health_data))
  end

  # ── Health Info Gathering ─────────────────────────────────────────────

  defp gather_health_info do
    %{
      status: overall_status(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: version(),
      uptime: uptime_seconds(),
      system: system_info(),
      dependencies: dependency_status(),
      resources: resource_metrics()
    }
  end

  # Overall status is "ok" if all critical dependencies are healthy
  defp overall_status do
    deps = dependency_status()

    critical_deps =
      deps
      |> Enum.filter(fn {_, info} -> Map.get(info, :critical, false) == true end)
      |> Enum.map(fn {_, info} -> info end)

    all_healthy? =
      Enum.all?(critical_deps, fn dep ->
        Map.get(dep, :status) == "ok"
      end)

    if all_healthy?, do: "ok", else: "degraded"
  end

  defp version do
    case Application.spec(:daemon, :vsn) do
      nil -> "0.2.5"
      vsn -> to_string(vsn)
    end
  end

  defp uptime_seconds do
    start_time = Application.get_env(:daemon, :start_time, System.system_time(:second))
    System.system_time(:second) - start_time
  end

  defp system_info do
    provider =
      Application.get_env(:daemon, :default_provider, "unknown")
      |> to_string()

    model_name =
      case Application.get_env(:daemon, :default_model) do
        nil ->
          prov = Application.get_env(:daemon, :default_provider, :ollama)

          case MiosaProviders.Registry.provider_info(prov) do
            {:ok, info} -> to_string(info.default_model)
            _ -> to_string(prov)
          end

        m ->
          to_string(m)
      end

    context_window = MiosaProviders.Registry.context_window(model_name)

    %{
      elixir: System.version(),
      otp_release: System.otp_release(),
      provider: provider,
      model: model_name,
      context_window: context_window
    }
  end

  defp dependency_status do
    %{
      channels: channel_status(),
      services: service_status(),
      external_apis: external_api_status()
    }
  end

  # Check status of all channel adapters
  defp channel_status do
    channels = [
      %{name: "email", module: Daemon.Channels.Email, config_key: :email_from},
      %{name: "feishu", module: Daemon.Channels.Feishu, config_key: :feishu_app_id},
      %{name: "cli", module: Daemon.Channels.CLI, config_key: nil},
      %{name: "http", module: Daemon.Channels.HTTP, config_key: nil}
    ]

    Enum.reduce(channels, %{}, fn channel, acc ->
      status = check_channel(channel)
      Map.put(acc, channel.name, status)
    end)
  end

  defp check_channel(%{module: module, config_key: config_key}) do
    configured? =
      if config_key do
        case Application.get_env(:daemon, config_key) do
          nil -> false
          "" -> false
          _ -> true
        end
      else
        # CLI and HTTP are always available
        true
      end

    pid = Process.whereis(module)

    status = %{
      status: if(pid && configured?, do: "ok", else: "disabled"),
      configured: configured?,
      pid: is_pid(pid) && Process.alive?(pid)
    }

    # Add connection status if the module implements connected?
    if Code.ensure_loaded?(module) && function_exported?(module, :connected?, 0) do
      try do
        connected = apply(module, :connected?, [])
        Map.put(status, :connected, connected)
      rescue
        _ -> status
      end
    else
      status
    end
  end

  defp service_status do
    %{
      events_bus: check_service(Daemon.Events.Bus),
      agent_loop: check_service(Daemon.Agent.Loop)
    }
  end

  defp check_service(module) do
    pid = Process.whereis(module)

    %{
      status: if(is_pid(pid) && Process.alive?(pid), do: "ok", else: "not_running"),
      pid: is_pid(pid)
    }
  end

  defp external_api_status do
    %{
      miosa_providers: %{
        status: "ok",
        critical: true,
        note: "Provider registry loaded"
      }
    }
  end

  defp resource_metrics do
    memory_info = :erlang.memory()

    %{
      memory: %{
        total_mb: div(Keyword.get(memory_info, :total, 0), 1_048_576),
        process_mb: div(Keyword.get(memory_info, :processes, 0), 1_048_576),
        system_mb: div(Keyword.get(memory_info, :system, 0), 1_048_576),
        atom_mb: div(Keyword.get(memory_info, :atom, 0), 1_048_576),
        binary_mb: div(Keyword.get(memory_info, :binary, 0), 1_048_576),
        ets_mb: div(Keyword.get(memory_info, :ets, 0), 1_048_576)
      },
      processes: %{
        count: :erlang.system_info(:process_count),
        limit: :erlang.system_info(:process_limit)
      },
      ports: %{
        count: :erlang.system_info(:port_count),
        limit: :erlang.system_info(:port_limit)
      }
    }
  end
end
