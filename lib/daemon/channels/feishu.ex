defmodule Daemon.Channels.Feishu do
  @moduledoc """
  Feishu/Lark (ByteDance) channel adapter.

  Receives events via webhook:
    POST /api/v1/channels/feishu/events

  Handles Feishu URL verification challenge (type: "url_verification").

  Sends messages via the Feishu Open API using the tenant_access_token,
  which is refreshed automatically every ~2 hours.

  ## Configuration

      config :daemon,
        feishu_app_id: System.get_env("FEISHU_APP_ID"),
        feishu_app_secret: System.get_env("FEISHU_APP_SECRET")

  The adapter starts only when `:feishu_app_id` is configured.

  ## Token refresh
  The adapter automatically fetches and refreshes the `tenant_access_token`
  (valid for 7200 seconds) via:
    POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal

  ## Encryption
  If the Feishu app is configured with an Encrypt Key, set:
      feishu_encrypt_key: System.get_env("FEISHU_ENCRYPT_KEY")
  The adapter will decrypt AES-CBC encrypted event payloads.
  """
  use GenServer
  @behaviour Daemon.Channels.Behaviour
  require Logger

  alias Daemon.Agent.Loop
  alias Daemon.Channels.Session
  alias Daemon.Utils.StructuredLogger

  @api_base "https://open.feishu.cn/open-apis"
  @send_timeout 15_000
  # Refresh 5 minutes before token expires
  @token_refresh_slack 300

  defstruct [
    :app_id,
    :app_secret,
    :encrypt_key,
    :tenant_access_token,
    :token_expires_at,
    connected: false
  ]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl Daemon.Channels.Behaviour
  def channel_name, do: :feishu

  @impl Daemon.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Daemon.Channels.Behaviour
  def send_message(receive_id, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, receive_id, message, opts}, @send_timeout)
    end
  end

  @impl Daemon.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Handle inbound event from Feishu (called by HTTP API).
  Returns `{:challenge, token}` for URL verification events.
  """
  def handle_event(body) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:event, body}, @send_timeout)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    app_id = Application.get_env(:daemon, :feishu_app_id)
    app_secret = Application.get_env(:daemon, :feishu_app_secret)
    encrypt_key = Application.get_env(:daemon, :feishu_encrypt_key)

    case app_id do
      nil ->
        StructuredLogger.info("Feishu adapter disabled", "Feishu",
          reason: "no_app_id"
        )
        :ignore

      _ ->
        StructuredLogger.info("Feishu adapter started", "Feishu",
          app_id: app_id
        )
        send(self(), :refresh_token)

        {:ok,
         %__MODULE__{
           app_id: app_id,
           app_secret: app_secret,
           encrypt_key: encrypt_key,
           connected: true
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, receive_id, message, opts}, _from, state) do
    state = maybe_refresh_token(state)
    result = do_send_message(state, receive_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:event, body}, _from, state) do
    # Decrypt if encrypted
    payload =
      case body do
        %{"encrypt" => ciphertext} ->
          decrypt_payload(ciphertext, state.encrypt_key)

        _ ->
          {:ok, body}
      end

    case payload do
      {:ok, decoded} ->
        result = route_event(decoded, state)
        {:reply, result, state}

      {:error, reason} ->
        StructuredLogger.warning("Feishu decryption failed", "Feishu",
          reason: inspect(reason)
        )
        {:reply, {:error, :decryption_failed}, state}
    end
  end

  @impl true
  def handle_info(:refresh_token, state) do
    new_state = do_refresh_token(state)
    # Schedule next refresh
    ttl =
      max(
        (new_state.token_expires_at || 0) - System.system_time(:second) - @token_refresh_slack,
        60
      )

    Process.send_after(self(), :refresh_token, ttl * 1_000)
    {:noreply, new_state}
  end

  # ── Event Routing ────────────────────────────────────────────────────

  # URL verification challenge
  defp route_event(%{"type" => "url_verification", "challenge" => challenge}, _state) do
    StructuredLogger.info("Feishu URL verification challenge", "Feishu", [])
    {:challenge, challenge}
  end

  # v1 event callback
  defp route_event(%{"header" => %{"event_type" => event_type}, "event" => event}, state) do
    spawn(fn -> dispatch_event(event_type, event, state) end)
    :ok
  end

  # v1 legacy event
  defp route_event(%{"event" => event, "type" => event_type}, state) do
    spawn(fn -> dispatch_event(event_type, event, state) end)
    :ok
  end

  defp route_event(body, _state) do
    Logger.debug("Feishu: Unhandled event shape: #{inspect(Map.keys(body))}")
    :ok
  end

  defp dispatch_event("im.message.receive_v1", event, state) do
    message = event["message"] || %{}
    sender = event["sender"] || %{}
    sender_id = get_in(sender, ["sender_id", "open_id"]) || "unknown"
    chat_id = message["chat_id"]
    content = message["content"]

    text =
      case Jason.decode(content || "{}") do
        {:ok, %{"text" => t}} -> String.trim(t)
        _ -> content || ""
      end

    if text != "" and chat_id do
      StructuredLogger.debug("Feishu message received", "Feishu",
        sender_id: sender_id,
        chat_id: chat_id,
        message_length: String.length(text)
      )
      session_id = "feishu_#{chat_id}_#{sender_id}"
      Session.ensure_loop(session_id, sender_id, :feishu)

      state = maybe_refresh_token(state)

      case Loop.process_message(session_id, text) do
        {:ok, response} ->
          do_send_message(state, chat_id, response, receive_id_type: "chat_id")

        {:filtered, signal} ->
          StructuredLogger.debug("Feishu signal filtered", "Feishu",
            signal_weight: signal.weight
          )

        {:error, reason} ->
          StructuredLogger.warning("Feishu agent error", "Feishu",
            chat_id: chat_id,
            reason: inspect(reason)
          )
      end
    end
  end

  defp dispatch_event(event_type, _event, _state) do
    Logger.debug("Feishu: Unhandled event type: #{event_type}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(state, receive_id, message, opts) do
    receive_id_type = Keyword.get(opts, :receive_id_type, "open_id")
    url = "#{@api_base}/im/v1/messages?receive_id_type=#{receive_id_type}"

    content = Jason.encode!(%{text: message})

    body = %{
      receive_id: receive_id,
      msg_type: "text",
      content: content
    }

    case Req.post(url,
           json: body,
           headers: [
             {"authorization", "Bearer #{state.tenant_access_token}"},
             {"content-type", "application/json; charset=utf-8"}
           ],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: 200, body: %{"code" => 0}}} ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        StructuredLogger.warning("Feishu rate limited", "Feishu",
          retry_after: retry_after
        )
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        StructuredLogger.warning("Feishu send failed", "Feishu",
          response: inspect(body)
        )
        {:error, body}

      {:error, reason} ->
        StructuredLogger.warning("Feishu HTTP error", "Feishu",
          error: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp do_refresh_token(state) do
    url = "#{@api_base}/auth/v3/tenant_access_token/internal"

    case Req.post(url,
           json: %{app_id: state.app_id, app_secret: state.app_secret},
           receive_timeout: 10_000
         ) do
      {:ok,
       %{status: 200, body: %{"code" => 0, "tenant_access_token" => token, "expire" => expire}}} ->
        StructuredLogger.debug("Feishu access token refreshed", "Feishu",
          expires_in: expire
        )
        expires_at = System.system_time(:second) + expire
        %{state | tenant_access_token: token, token_expires_at: expires_at}

      {:ok, %{body: body}} ->
        StructuredLogger.warning("Feishu token refresh failed", "Feishu",
          response: inspect(body)
        )
        state

      {:error, reason} ->
        StructuredLogger.warning("Feishu token refresh HTTP error", "Feishu",
          error: inspect(reason)
        )
        state
    end
  end

  defp maybe_refresh_token(state) do
    now = System.system_time(:second)
    expires_at = state.token_expires_at || 0

    if now >= expires_at - @token_refresh_slack do
      do_refresh_token(state)
    else
      state
    end
  end

  # ── Payload Decryption ───────────────────────────────────────────────

  defp decrypt_payload(_ciphertext, nil) do
    {:error, :no_encrypt_key}
  end

  defp decrypt_payload(ciphertext, encrypt_key) do
    try do
      # Feishu uses AES-CBC-256
      # Key = SHA256(encrypt_key)
      key = :crypto.hash(:sha256, encrypt_key)

      raw = Base.decode64!(ciphertext)
      # First 16 bytes are the IV
      <<iv::binary-16, encrypted::binary>> = raw
      decrypted = :crypto.crypto_one_time(:aes_256_cbc, key, iv, encrypted, false)

      # Remove PKCS7 padding
      pad_len = :binary.last(decrypted)
      content = binary_part(decrypted, 0, byte_size(decrypted) - pad_len)

      {:ok, Jason.decode!(content)}
    rescue
      e ->
        {:error, e}
    end
  end

  # ── Misc Helpers ─────────────────────────────────────────────────────

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) ||
           List.keyfind(headers, "x-ratelimit-reset-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> 5
        end

      nil ->
        5
    end
  end
end
