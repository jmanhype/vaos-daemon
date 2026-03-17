# VAS-Swarm Dockerfile
# Multi-stage build for Elixir/Phoenix service

# Build stage
FROM elixir:1.19-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base npm git python3

# Set ERLANG flags
ENV MIX_ENV=prod \
    ERL_AFLAGS="-kernel shell_history enabled"

# Copy mix files
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Copy source code
COPY . .

# Install npm dependencies (if any)
RUN if [ -d "assets" ]; then cd assets && npm ci && cd ..; fi

# Build the application
RUN mix compile
RUN mix release

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache openssl ncurses-libs libstdc++

# Copy the release from builder
COPY --from=builder /app/_build/prod/rel/optimal_system_agent .

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    chown -R appuser:appuser /app

USER appuser

# Expose ports
# 4000: Phoenix HTTP server
# 4369: EPMD (Erlang Port Mapper Daemon)
# Dynamic range: 9100-9200: Distributed Erlang nodes
EXPOSE 4000 4369 9100-9200

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD bin/optimal_system_agent eval "case :gen_server.call(:health_check, :ping) do :pong -> 0; _ -> 1 end" || exit 1

# Run the application
CMD ["bin/optimal_system_agent", "start"]
