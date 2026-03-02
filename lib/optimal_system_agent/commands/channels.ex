defmodule OptimalSystemAgent.Commands.Channels do
  @moduledoc """
  Channel management commands: /channels, /whatsapp.
  """

  @doc "Handle the `/channels` command with subcommand routing."
  def cmd_channels(arg, _session_id) do
    alias OptimalSystemAgent.Channels.Manager
    parts = String.split(String.trim(arg), ~r/\s+/, parts: 2)

    case parts do
      [""] ->
        cmd_channels_overview()

      ["connect", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}\n\nAvailable: #{Enum.join(Manager.known_channels(), ", ")}"}

          channel ->
            case Manager.start_channel(channel) do
              {:ok, pid} ->
                {:command, "Channel #{name} started (pid=#{inspect(pid)})"}

              {:error, :not_configured} ->
                {:command, "Channel #{name} is not configured. Run /setup to configure it."}

              {:error, reason} ->
                {:command, "Failed to start #{name}: #{inspect(reason)}"}
            end
        end

      ["disconnect", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}\n\nAvailable: #{Enum.join(Manager.known_channels(), ", ")}"}

          channel ->
            case Manager.stop_channel(channel) do
              :ok ->
                {:command, "Channel #{name} disconnected."}

              {:error, :not_running} ->
                {:command, "Channel #{name} is not running."}

              {:error, reason} ->
                {:command, "Failed to stop #{name}: #{inspect(reason)}"}
            end
        end

      ["status", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}"}

          channel ->
            case Manager.channel_status(channel) do
              {:ok, info} ->
                output =
                  """
                  Channel: #{info.name}
                    module:     #{inspect(info.module)}
                    pid:        #{inspect(info.pid)}
                    connected:  #{info.connected}
                    configured: #{info.configured}
                  """
                  |> String.trim()

                {:command, output}
            end
        end

      ["test", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}"}

          channel ->
            case Manager.test_channel(channel) do
              {:ok, :connected} ->
                {:command, "Channel #{name}: connected and responding."}

              {:error, :not_running} ->
                {:command, "Channel #{name}: not running. Use /channels connect #{name}"}

              {:error, :not_connected} ->
                {:command, "Channel #{name}: process alive but not connected."}

              {:error, :process_dead} ->
                {:command, "Channel #{name}: process is dead."}
            end
        end

      _ ->
        {:command,
         "Usage:\n  /channels                    List all channels\n  /channels connect <name>     Start a channel\n  /channels disconnect <name>  Stop a channel\n  /channels status <name>      Detailed status\n  /channels test <name>        Verify responding"}
    end
  end

  @doc "Handle the `/whatsapp` command with subcommand routing."
  def cmd_whatsapp(arg, _session_id) do
    parts = String.split(String.trim(arg), ~r/\s+/, parts: 2)

    case parts do
      [""] -> cmd_whatsapp_status()
      ["connect"] -> cmd_whatsapp_connect()
      ["disconnect"] -> cmd_whatsapp_disconnect()
      ["test"] -> cmd_whatsapp_test()

      _ ->
        {:command,
         "Usage:\n  /whatsapp             Status\n  /whatsapp connect     Connect via QR code\n  /whatsapp disconnect  Logout + stop\n  /whatsapp test        Verify connection"}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  defp cmd_channels_overview do
    alias OptimalSystemAgent.Channels.Manager
    channels = Manager.list_channels()
    active = Enum.count(channels, & &1.connected)

    lines =
      Enum.map_join(channels, "\n", fn ch ->
        status = if ch.connected, do: "active", else: "inactive"
        pid_str = if ch.pid, do: inspect(ch.pid), else: "-"

        "  #{String.pad_trailing(to_string(ch.name), 12)} #{String.pad_trailing(status, 10)} #{pid_str}"
      end)

    {:command,
     "Channels (#{active}/#{length(channels)} active):\n  #{String.pad_trailing("NAME", 12)} #{String.pad_trailing("STATUS", 10)} PID\n#{lines}"}
  end

  defp resolve_channel_name(name) when is_binary(name) do
    alias OptimalSystemAgent.Channels.Manager
    Enum.find(Manager.known_channels(), fn ch -> to_string(ch) == name end)
  end

  defp cmd_whatsapp_status do
    mode = Application.get_env(:optimal_system_agent, :whatsapp_mode, "auto")
    api_configured = Application.get_env(:optimal_system_agent, :whatsapp_token) != nil
    web_available = OptimalSystemAgent.WhatsAppWeb.available?()

    web_state =
      if web_available do
        case OptimalSystemAgent.WhatsAppWeb.connection_status() do
          {:ok, %{"connection" => conn, "jid" => jid}} ->
            "#{conn}#{if jid, do: " (#{jid})", else: ""}"

          _ ->
            "unknown"
        end
      else
        "sidecar not available"
      end

    output =
      """
      WhatsApp Status:
        mode:          #{mode}
        API (Cloud):   #{if api_configured, do: "configured", else: "not configured"}
        Web (Baileys): #{web_state}
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_whatsapp_connect do
    if not OptimalSystemAgent.WhatsAppWeb.available?() do
      {:command,
       "WhatsApp Web sidecar is not available.\nEnsure Node.js is installed and run: cd priv/sidecar/baileys && npm install"}
    else
      case OptimalSystemAgent.WhatsAppWeb.connect() do
        {:ok, %{"status" => "qr", "qr_text" => qr_text}}
        when is_binary(qr_text) and qr_text != "" ->
          {:command, "Scan this QR code with WhatsApp:\n\n#{qr_text}\n\nWaiting for scan..."}

        {:ok, %{"status" => "qr", "qr" => _qr}} ->
          {:command, "QR code generated but text rendering failed. Check sidecar logs."}

        {:ok, %{"status" => "connected", "jid" => jid}} ->
          {:command, "Already connected as #{jid}"}

        {:ok, %{"status" => "logged_out"}} ->
          {:command, "Session was logged out. Try /whatsapp connect again."}

        {:error, reason} ->
          {:command, "Failed to connect: #{inspect(reason)}"}
      end
    end
  end

  defp cmd_whatsapp_disconnect do
    if not OptimalSystemAgent.WhatsAppWeb.available?() do
      {:command, "WhatsApp Web sidecar is not running."}
    else
      case OptimalSystemAgent.WhatsAppWeb.logout() do
        {:ok, _} -> {:command, "WhatsApp Web disconnected and session cleared."}
        {:error, reason} -> {:command, "Disconnect failed: #{inspect(reason)}"}
      end
    end
  end

  defp cmd_whatsapp_test do
    api_ok =
      case OptimalSystemAgent.Channels.WhatsApp.connected?() do
        true -> "connected"
        false -> "not connected"
      end

    web_ok =
      if OptimalSystemAgent.WhatsAppWeb.available?() do
        case OptimalSystemAgent.WhatsAppWeb.health_check() do
          :ready -> "connected"
          :degraded -> "degraded (awaiting QR scan)"
          _ -> "not available"
        end
      else
        "sidecar not running"
      end

    {:command, "WhatsApp Test:\n  API (Cloud):   #{api_ok}\n  Web (Baileys): #{web_ok}"}
  end
end
