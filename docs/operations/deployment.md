# Deployment Guide

> Production deployment, Docker, and operational best practices

## Prerequisites

- **Elixir** 1.17+ / **OTP** 28+
- **SQLite3** (included via ecto_sqlite3)
- **Optional**: Docker (for sandbox), Go 1.21+ (for sidecars), Python 3.10+ (for embeddings)

## Local Development

```bash
# Clone and setup
git clone <repo-url>
cd Daemon
mix deps.get
mix ecto.create
mix ecto.migrate

# Configure provider
cp .env.example .env
# Edit .env with your API keys

# Run interactive
mix daemon.chat

# Run HTTP API server
mix daemon.serve

# Run tests
mix test
```

## Building a Release

```bash
# Build production release
MIX_ENV=prod mix release

# The release is at _build/prod/rel/daemon/
# Run it:
_build/prod/rel/daemon/bin/daemon start
```

## Docker Deployment

### Dockerfile

```dockerfile
FROM elixir:1.17-otp-28 AS build

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libstdc++6 openssl libncurses5 locales sqlite3 \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

WORKDIR /app
COPY --from=build /app/_build/prod/rel/daemon ./

# Create data directory
RUN mkdir -p /data/osa
ENV DAEMON_CONFIG_DIR=/data/osa

EXPOSE 8089
VOLUME ["/data/osa"]

CMD ["bin/daemon", "start"]
```

### Docker Compose

```yaml
version: "3.8"

services:
  osa:
    build: .
    ports:
      - "8089:8089"
    volumes:
      - osa-data:/data/osa
      - ./.env:/app/.env:ro
    environment:
      - DAEMON_HTTP_PORT=8089
      - DAEMON_REQUIRE_AUTH=true
      - DAEMON_SHARED_SECRET=${DAEMON_SHARED_SECRET}
    restart: unless-stopped

volumes:
  osa-data:
```

### Run

```bash
docker compose up -d
docker compose logs -f osa
```

## Reverse Proxy (Nginx)

```nginx
upstream osa {
    server 127.0.0.1:8089;
}

server {
    listen 443 ssl http2;
    server_name osa.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/osa.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/osa.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://osa;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket support (for future use)
    location /ws {
        proxy_pass http://osa;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

## Environment Variables for Production

```bash
# Required
DAEMON_DEFAULT_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...

# Security
DAEMON_REQUIRE_AUTH=true
DAEMON_SHARED_SECRET=<generate-a-strong-secret>

# Budget limits
DAEMON_DAILY_BUDGET_USD=100.0
DAEMON_MONTHLY_BUDGET_USD=1000.0

# Optional: Enable features
DAEMON_SANDBOX_ENABLED=true
DAEMON_FLEET_ENABLED=false
DAEMON_TREASURY_ENABLED=true

# Optional: Quiet hours (no heartbeat)
DAEMON_QUIET_HOURS="23:00-08:00"
```

## Production Checklist

### Security
- [ ] `DAEMON_REQUIRE_AUTH=true` with strong `DAEMON_SHARED_SECRET`
- [ ] HTTPS via reverse proxy
- [ ] No API keys in code or Docker images
- [ ] Sandbox enabled for untrusted tool execution
- [ ] Budget limits configured
- [ ] Firewall: only expose port 443 (via proxy)

### Reliability
- [ ] Supervisor tree handles crashes automatically (OTP)
- [ ] SQLite WAL mode enabled (default)
- [ ] Session persistence configured
- [ ] Memory persistence configured
- [ ] Backups for `~/.daemon/` directory

### Monitoring
- [ ] Health endpoint: `GET /health` returns 200
- [ ] Budget alerts configured
- [ ] Log aggregation (stdout/stderr to your logging system)
- [ ] Disk usage monitoring (SQLite + sessions can grow)

### Performance
- [ ] Context compaction thresholds tuned
- [ ] Budget per-call limits set
- [ ] Appropriate tier/model selection for workload
- [ ] Connection pool size adequate (default: 5)

## Backups

```bash
# Back up all Daemon data
tar -czf osa-backup-$(date +%Y%m%d).tar.gz ~/.daemon/

# Back up just the database
sqlite3 ~/.daemon/osa.db ".backup /backups/osa-$(date +%Y%m%d).db"
```

## Systemd Service

```ini
[Unit]
Description=Daemon Agent
After=network.target

[Service]
Type=simple
User=osa
WorkingDirectory=/opt/osa
ExecStart=/opt/osa/bin/daemon start
ExecStop=/opt/osa/bin/daemon stop
Restart=on-failure
RestartSec=5
Environment=HOME=/opt/osa
EnvironmentFile=/opt/osa/.env

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable osa
sudo systemctl start osa
sudo systemctl status osa
journalctl -u osa -f
```

## macOS LaunchAgent

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.miosa.osa</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/daemon</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/osa.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/osa-error.log</string>
</dict>
</plist>
```

```bash
cp com.miosa.osa.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.miosa.osa.plist
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Port 8089 in use | Another process | `DAEMON_HTTP_PORT=8090` or find/kill the process |
| Provider timeout | API rate limit or network | Check budget, try fallback provider |
| SQLite locked | Multiple processes | Ensure only one Daemon instance per database |
| Sidecar not starting | Missing binary | Check `DAEMON_GO_TOKENIZER_ENABLED` and binary path |
| Out of memory | Context too large | Lower compaction thresholds, reduce `max_tokens` |
