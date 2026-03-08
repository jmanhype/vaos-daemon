# Channels: Messaging Adapters

This document covers all non-HTTP, non-CLI channel adapters: the nine messaging platform integrations. Each is a `GenServer` that implements `Channels.Behaviour` and starts only when its required configuration is present.

All adapters follow the same inbound flow:
1. Receive a platform event (webhook POST or long-poll).
2. Call `Channels.Session.ensure_loop/3` to get or start an `Agent.Loop`.
3. Call `Agent.Loop.process_message/2`.
4. Send the response back via the platform API.

---

## Telegram

**Module:** `OptimalSystemAgent.Channels.Telegram`

Operates in webhook mode. Telegram POSTs updates to `POST /api/v1/channels/telegram/webhook`.

### Configuration

```elixir
config :optimal_system_agent,
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN")
```

### Webhook registration

```elixir
OptimalSystemAgent.Channels.Telegram.set_webhook("https://yourdomain.com")
# Registers: https://yourdomain.com/api/v1/channels/telegram/webhook
```

### Message handling

- Inbound text messages are processed via `process_update/1`.
- Callback queries (button presses) are converted to text messages with the button's `callback_data`.
- Unsupported update types are logged and ignored.

### Outbound

`send_message/3` calls `POST /bot{token}/sendMessage` with `parse_mode: "MarkdownV2"` by default. Optional `keyboard:` in opts creates an inline keyboard (`reply_markup.inline_keyboard`). Rate-limit 429 responses return `{:error, {:rate_limited, retry_after}}`.

### Session IDs

Format: `telegram_<chat_id>`

---

## Discord

**Module:** `OptimalSystemAgent.Channels.Discord`

Operates in webhook/interactions mode. Discord POSTs interactions to `POST /api/v1/channels/discord/webhook`.

### Configuration

```elixir
config :optimal_system_agent,
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  discord_application_id: System.get_env("DISCORD_APPLICATION_ID"),
  discord_public_key: System.get_env("DISCORD_PUBLIC_KEY")
```

`discord_public_key` is used for Ed25519 signature verification on inbound interactions. If not set, verification is skipped (development only).

### Interaction types handled

| Type | Handling |
|------|---------|
| 1 (Ping) | Returns `{:pong, %{type: 1}}` — required by Discord |
| 2 (Application command) | Deferred response (`{type: 5}`), processes slash command asynchronously |
| 3 (Message component) | Deferred ACK (`{type: 6}`), processes `custom_id` as input |

### Outbound

`send_message/3` calls `POST /channels/{channel_id}/messages` with `Authorization: Bot {token}`. Messages over 2000 characters are chunked.

### Session IDs

Format: `discord_<user_id>`

---

## Slack

**Module:** `OptimalSystemAgent.Channels.Slack`

Uses the Slack Events API. Slack POSTs events to `POST /api/v1/channels/slack/events`.

### Configuration

```elixir
config :optimal_system_agent,
  slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
  slack_signing_secret: System.get_env("SLACK_SIGNING_SECRET")
```

- `slack_bot_token` — `xoxb-...` Bot token for sending (`chat.postMessage`).
- `slack_signing_secret` — HMAC-SHA256 verification of inbound payloads. Requests older than 300 seconds are rejected.

### Event handling

- `url_verification` challenge: returns `{:challenge, value}` synchronously.
- `message` events from bots are ignored to prevent loops.
- Regular user messages: session per `user_id + channel`.
- `thread_ts` opt in `send_message/3` enables threaded replies.

### Signature verification

Payload: `"v0:{timestamp}:{raw_body}"`, expected signature: `"v0=" + hex(HMAC-SHA256(signing_secret, payload))`.

### Session IDs

Format: `slack_<user_id>_<channel_id>`

---

## WhatsApp

**Module:** `OptimalSystemAgent.Channels.WhatsApp`

Uses the Meta Cloud API (Graph API v21.0). Receives messages via `POST /api/v1/channels/whatsapp/webhook`; Meta webhook verification via `GET /api/v1/channels/whatsapp/webhook`.

### Configuration

```elixir
config :optimal_system_agent,
  whatsapp_token: System.get_env("WHATSAPP_TOKEN"),
  whatsapp_phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID"),
  whatsapp_verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN")
```

### Mode selection

Supports a `whatsapp_mode` config key (`"api"`, `"web"`, `"auto"`). In `"auto"` mode, prefers WhatsApp Web if `OptimalSystemAgent.WhatsAppWeb.available?/0` returns true; otherwise falls back to the Meta Graph API.

### Inbound processing

Processes `whatsapp_business_account` objects. Iterates entries → changes → messages. Supports `"text"` message type; other types are logged. Marks messages as read before processing.

### Verification challenge

`verify_challenge/1` checks `hub.mode == "subscribe"` and `hub.verify_token == state.verify_token`. Returns `{:ok, challenge}` or `{:error, :forbidden}`.

### Session IDs

Format: `whatsapp_<from_phone_number>`

---

## Matrix

**Module:** `OptimalSystemAgent.Channels.Matrix`

Uses the Matrix Client-Server API with long-polling via `/sync`. No external library required.

### Configuration

```elixir
config :optimal_system_agent,
  matrix_homeserver: System.get_env("MATRIX_HOMESERVER"),   # e.g. "https://matrix.org"
  matrix_access_token: System.get_env("MATRIX_ACCESS_TOKEN"),
  matrix_user_id: System.get_env("MATRIX_USER_ID")          # e.g. "@bot:matrix.org"
```

### Sync loop

On start, the adapter sends itself `:start_sync`, which begins a polling loop:
1. `GET /_matrix/client/v3/sync?timeout=30000[&since=<next_batch>]`
2. Processes timeline events from all joined rooms.
3. Automatically accepts room invites (`POST /join/{room_id}`).
4. Filters out own messages and events older than 60 seconds.
5. Reschedules immediately; on error waits 5 seconds.

`next_batch` is held in process state only (not persisted). Restart will briefly reprocess recent events.

### Outbound

`send_message/3` calls `PUT /rooms/{room_id}/send/m.room.message/{txn_id}` with `msgtype: "m.text"`. Transaction IDs are incremented in state.

### Session IDs

Format: `matrix_<room_id>_<sender_id>`

---

## Signal

**Module:** `OptimalSystemAgent.Channels.Signal`

Signal Private Messenger adapter. See `lib/optimal_system_agent/channels/signal.ex` for current implementation details.

### Configuration

```elixir
config :optimal_system_agent,
  signal_phone: System.get_env("SIGNAL_PHONE")
```

---

## QQ

**Module:** `OptimalSystemAgent.Channels.QQ`

Tencent Open Platform bot adapter. Receives events via `POST /api/v1/channels/qq/webhook`.

### Configuration

```elixir
config :optimal_system_agent,
  qq_app_id: System.get_env("QQ_APP_ID"),
  qq_app_secret: System.get_env("QQ_APP_SECRET"),
  qq_token: System.get_env("QQ_TOKEN")
```

### Signature verification

Ed25519: `message = timestamp + nonce + body`. Signature provided as hex. Token provided as hex Ed25519 public key.

### Access token

OAuth2 access token is fetched automatically from `https://bots.qq.com/app/getAppAccessToken` using `app_id` + `app_secret`. Refreshed on a timer (token TTL ~7200s, refreshed 300s before expiry). The OAuth token takes precedence over the static `qq_token` for API calls.

### Event routing

| Event type | Handling |
|-----------|---------|
| `op: 13` (URL verification) | Returns `{:challenge, %{plain_token, signature}}` |
| `AT_MESSAGE_CREATE` | Process message |
| `MESSAGE_CREATE` | Process message |

At-mention prefixes (`<@id>`) are stripped before processing. Replies include the original `msg_id`.

### API base

`https://api.sgroup.qq.com` (production). `https://sandbox.api.sgroup.qq.com` for sandbox.

### Session IDs

Format: `qq_<user_id>_<channel_id>`

---

## DingTalk

**Module:** `OptimalSystemAgent.Channels.DingTalk`

Alibaba DingTalk custom robot adapter. Receives events via `POST /api/v1/channels/dingtalk/webhook`.

### Configuration

```elixir
config :optimal_system_agent,
  dingtalk_access_token: System.get_env("DINGTALK_ACCESS_TOKEN"),
  dingtalk_secret: System.get_env("DINGTALK_SECRET")   # optional
```

### Outbound signing

When `dingtalk_secret` is set, outbound webhook URLs include `?timestamp=<ms>&sign=<base64(HMAC-SHA256(secret, "<ms>\n<secret>"))>`.

### Message format

Messages are sent to a group webhook URL (not individual chats — DingTalk robot webhooks are group-scoped). Format is selected automatically:
- `:auto` — uses `markdown` type if the response contains `**`, `##`, `` ` ``, or `- `; otherwise `text`.
- `:markdown` — `msgtype: "markdown"` with `title: "OSA Agent"`.
- `:text` — `msgtype: "text"`.

### Error codes

DingTalk returns `errcode: 130101` for rate limiting.

### Session IDs

Format: `dingtalk_<conversation_id>_<sender_id>`

---

## Feishu (Lark)

**Module:** `OptimalSystemAgent.Channels.Feishu`

ByteDance Feishu/Lark Open API adapter. Receives events via `POST /api/v1/channels/feishu/events`.

### Configuration

```elixir
config :optimal_system_agent,
  feishu_app_id: System.get_env("FEISHU_APP_ID"),
  feishu_app_secret: System.get_env("FEISHU_APP_SECRET"),
  feishu_encrypt_key: System.get_env("FEISHU_ENCRYPT_KEY")   # optional
```

### Token refresh

`tenant_access_token` is fetched via `POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal` using `app_id` + `app_secret`. Valid for 7200 seconds; refreshed 300 seconds before expiry using a scheduled `handle_info(:refresh_token)`. Token is also refreshed on demand before each send.

### Event encryption

If the Feishu app has an Encrypt Key configured, inbound event payloads are AES-256-CBC encrypted. The key is `SHA256(encrypt_key)`. The first 16 bytes of the decoded payload are the IV; PKCS7 padding is stripped.

### Event routing

| Event | Handling |
|-------|---------|
| `type: "url_verification"` | Returns `{:challenge, token}` |
| `im.message.receive_v1` | Process text message |
| `v1 legacy events` | Dispatched by `event_type` string |

### Outbound

`send_message/3` calls `POST /im/v1/messages?receive_id_type=<type>` with `msg_type: "text"` and JSON-encoded content. `receive_id_type` defaults to `"open_id"`; pass `receive_id_type: "chat_id"` in opts for group chat replies.

### Session IDs

Format: `feishu_<chat_id>_<sender_open_id>`

---

## Common Behaviour

All nine adapters share:

- `init/1` returns `:ignore` when required config is absent.
- `connected?/0` checks the process is alive and calls `state.connected`.
- Rate-limit 429 responses return `{:error, {:rate_limited, retry_after}}`.
- `{:filtered, signal}` from `Loop.process_message` is logged at debug level and produces no outbound message.
- `{:error, reason}` from `Loop.process_message` sends a generic error reply.

---

## See Also

- [overview.md](overview.md) — Behaviour contract, Manager, Session, Starter
- [http.md](http.md) — HTTP channel and webhook route modules
