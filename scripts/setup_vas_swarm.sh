#!/bin/bash
# VAS-Swarm Setup Script
# Run this to configure VAS-Swarm integration for Daemon

set -e

echo "=== VAS-Swarm Setup Script ==="
echo ""

# Check if we're in the Daemon/VAS-Swarm directory
if [ ! -f "mix.exs" ]; then
    echo "Error: mix.exs not found. Please run this script from the Daemon/VAS-Swarm root directory."
    exit 1
fi

echo "✓ Found Daemon/VAS-Swarm directory"

# Check if VAS-Swarm is already configured
if grep -q "vas_swarm_enabled: true" config/config.exs 2>/dev/null; then
    echo "⚠ VAS-Swarm appears to be already enabled in config/config.exs"
    read -p "Do you want to reconfigure? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

# Prompt for configuration
echo ""
echo "=== Configuration ==="
echo ""

# Enable VAS-Swarm
echo "Enabling VAS-Swarm integration..."

# Backup existing config
if [ -f "config/config.exs" ]; then
    cp config/config.exs config/config.exs.backup
    echo "✓ Backed up config/config.exs to config/config.exs.backup"
fi

# Add VAS-Swarm configuration to config
cat >> config/config.exs << 'EOF'

# VAS-Swarm Integration Configuration
import Config

config :daemon,
  vas_swarm_enabled: true

# Go Kernel gRPC endpoint
# The Kernel issues JWT tokens and receives telemetry/routing logs
config :daemon,
  vas_kernel_url: "grpc://localhost:50051"

# AMQP connection for telemetry and commands
config :daemon,
  amqp_url: "amqp://guest:guest@localhost:5672"

EOF

echo "✓ Added VAS-Swarm configuration to config/config.exs"

# Check dependencies
echo ""
echo "=== Dependencies ==="
echo ""

# Check if grpc and gun are in mix.exs
if grep -q "{:grpc," mix.exs && grep -q "{:gun," mix.exs; then
    echo "✓ gRPC dependencies already in mix.exs"
else
    echo "⚠ gRPC dependencies may need to be added to mix.exs"
    echo "  The following should be present:"
    echo "    {:grpc, \"~> 0.7\", optional: true}"
    echo "    {:gun, \"~> 2.0\", optional: true}"
    echo ""
    read -p "Should I add these dependencies? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Add dependencies (simple approach - after amqp line)
        sed -i.bak '/{:amqp, "~> 4.1", optional: true},/a\
  # gRPC client for VAS-Swarm Kernel communication (optional)\
  {:grpc, "~> 0.7", optional: true},\
  {:gun, "~> 2.0", optional: true},' mix.exs
        echo "✓ Added gRPC dependencies to mix.exs"
    fi
fi

# Install dependencies
echo ""
echo "=== Installing Dependencies ==="
echo ""

read -p "Should I install dependencies? (Y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    mix deps.get
    echo "✓ Dependencies installed"
fi

# Compile
echo ""
echo "=== Compiling ==="
echo ""

read -p "Should I compile the project? (Y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    mix compile
    echo "✓ Project compiled"
fi

# Run tests
echo ""
echo "=== Running Tests ==="
echo ""

read -p "Should I run VAS-Swarm integration tests? (Y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    mix test test/optimal_system_agent/vas_swarm/
    echo "✓ Tests completed"
fi

# Generate gRPC stubs (optional)
echo ""
echo "=== gRPC Stubs ==="
echo ""

if command -v protoc &> /dev/null; then
    echo "✓ protoc is installed"
    read -p "Should I generate gRPC Elixir stubs from kernel.proto? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Check if protoc-gen-grpc-elixir is installed
        if command -v protoc-gen-grpc-elixir &> /dev/null; then
            protoc --elixir_out=./lib --grpc_out=./lib protos/kernel.proto
            echo "✓ Generated gRPC stubs"
        else
            echo "⚠ protoc-gen-grpc-elixir not found"
            echo "  To generate stubs later, run:"
            echo "    go install github.com/elixir-grpc/protoc-gen-grpc-elixir@latest"
            echo "    protoc --elixir_out=./lib --grpc_out=./lib protos/kernel.proto"
        fi
    fi
else
    echo "⚠ protoc not found (optional, for gRPC stub generation)"
fi

# Summary
echo ""
echo "=== Setup Complete ==="
echo ""
echo "VAS-Swarm integration has been configured!"
echo ""
echo "Next steps:"
echo "  1. Review config/config.exs to customize settings"
echo "  2. Start the Go Kernel service (if not already running)"
echo "  3. Start RabbitMQ (if using AMQP)"
echo "  4. Start Daemon: bin/osa or mix osa.serve"
echo ""
echo "Documentation:"
echo "  - Integration guide: README-VAS-SWARM.md"
echo "  - Implementation details: VAS-SWARM-IMPLEMENTATION.md"
echo "  - Configuration examples: config/vas_swarm.example.exs"
echo ""
echo "To disable VAS-Swarm later, set vas_swarm_enabled: false in config/config.exs"
echo ""
