#!/bin/bash
# Generate Elixir gRPC stubs from proto files

set -e

echo "Installing protoc-gen-grpc-elixir..."
go install github.com/elixir-grpc/protoc-gen-grpc-elixir@latest

echo "Generating gRPC stubs for VAS-Swarm..."
protoc --elixir_out=./lib --grpc_out=./lib protos/kernel.proto

echo "Generated gRPC stubs successfully!"
echo ""
echo "Generated files:"
echo "  - lib/vaos/kernel.pb.ex"
echo "  - lib/vaos/kernel/grpc.pb.ex"
