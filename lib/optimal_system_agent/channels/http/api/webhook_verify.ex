defmodule OptimalSystemAgent.Channels.HTTP.API.WebhookVerify do
  @moduledoc """
  Webhook signature verification for channel integrations.

  Each function returns:
    - `:ok` — signature valid
    - `{:error, :no_secret}` — config key is nil; request must be rejected
    - `{:error, :invalid_signature}` — HMAC/header mismatch
  """
  import Plug.Conn

  @doc "Verify Telegram x-telegram-bot-api-secret-token header."
  @spec verify_telegram(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_telegram(_conn, nil), do: {:error, :no_secret}

  def verify_telegram(conn, expected_secret) do
    provided = get_req_header(conn, "x-telegram-bot-api-secret-token") |> List.first("")

    if Plug.Crypto.secure_compare(provided, expected_secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc "Verify WhatsApp x-hub-signature-256 header (Meta webhook pattern)."
  @spec verify_whatsapp(Plug.Conn.t(), binary(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_whatsapp(_conn, _raw_body, nil), do: {:error, :no_secret}

  def verify_whatsapp(conn, raw_body, app_secret) do
    header = get_req_header(conn, "x-hub-signature-256") |> List.first("")
    expected_hex = Base.encode16(:crypto.mac(:hmac, :sha256, app_secret, raw_body), case: :lower)
    expected = "sha256=" <> expected_hex

    if Plug.Crypto.secure_compare(header, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc "Verify DingTalk sign query param using HMAC-SHA256."
  @spec verify_dingtalk(String.t(), String.t(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_dingtalk(_timestamp, _sign, nil), do: {:error, :no_secret}

  def verify_dingtalk(timestamp, sign, secret) do
    string_to_sign = "#{timestamp}\n#{secret}"
    expected = :crypto.mac(:hmac, :sha256, secret, string_to_sign) |> Base.encode64()

    if Plug.Crypto.secure_compare(sign, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc """
  Verify Signal webhook x-signal-signature header.

  signal-cli-rest-api uses the same `sha256=<hex>` HMAC pattern as Meta webhooks.
  The header name is `x-signal-signature`.

  Returns `{:error, :no_secret}` when the configured secret is nil so the
  caller can decide whether to warn-and-process (dev mode) or reject.
  """
  @spec verify_signal(Plug.Conn.t(), binary(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_signal(_conn, _raw_body, nil), do: {:error, :no_secret}

  def verify_signal(conn, raw_body, secret) do
    header = get_req_header(conn, "x-signal-signature") |> List.first("")
    expected_hex = Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw_body), case: :lower)
    expected = "sha256=" <> expected_hex

    if Plug.Crypto.secure_compare(header, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc "Verify email inbound x-webhook-secret header."
  @spec verify_email(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_email(_conn, nil), do: {:error, :no_secret}

  def verify_email(conn, expected_secret) do
    provided = get_req_header(conn, "x-webhook-secret") |> List.first("")

    if Plug.Crypto.secure_compare(provided, expected_secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
