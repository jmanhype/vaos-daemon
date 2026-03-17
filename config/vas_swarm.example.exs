# VAS-Swarm Configuration Example
# Copy this file to config/config.exs and customize as needed

import Config

# Enable VAS-Swarm integration
config :optimal_system_agent,
  vas_swarm_enabled: true

# Go Kernel gRPC endpoint
# The Kernel issues JWT tokens and receives telemetry/routing logs
config :optimal_system_agent,
  vas_kernel_url: "grpc://localhost:50051"
  # Or with TLS:
  # vas_kernel_url: "grpcs://kernel.example.com:50051"

# AMQP connection for telemetry and commands
# RabbitMQ broker for real-time coordination
config :optimal_system_agent,
  amqp_url: "amqp://guest:guest@localhost:5672"
  # Or with credentials and TLS:
  # amqp_url: "amqps://user:pass@rabbitmq.example.com:5671"

# Optional: Custom telemetry batch settings
config :optimal_system_agent, :vas_telemetry,
  flush_interval: 1000,  # milliseconds
  max_batch_size: 100     # messages per batch

# Optional: Custom gRPC client settings
config :optimal_system_agent, :vas_grpc,
  request_timeout: 5000,      # milliseconds
  reconnect_interval_min: 1000,  # milliseconds
  reconnect_interval_max: 30000,  # milliseconds
  circuit_threshold: 5,      # failures before circuit opens
  circuit_timeout: 30000     # milliseconds
