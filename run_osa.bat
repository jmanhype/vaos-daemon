@echo off
title OSA Agent

echo Starting OSA backend...

:: Stop any old backend
docker stop osa-backend 2>nul
docker rm osa-backend 2>nul

:: Start backend in background
docker run -d --name osa-backend ^
  -p 8089:8089 ^
  -e OSA_DEFAULT_PROVIDER=ollama ^
  -e OLLAMA_URL=http://host.docker.internal:11434 ^
  -e OLLAMA_MODEL=gemma:2b ^
  -e OSA_REQUIRE_AUTH=false ^
  -v osa_data:/root/.osa ^
  --add-host host.docker.internal:host-gateway ^
  osa:latest ^
  bin/osagent serve

echo Waiting for backend...
timeout /t 5 /nobreak > nul

:: Launch TUI (Rust TUI — Go TUI is retired)
echo Launching OSA TUI...
"%~dp0priv\rust\tui\target\release\osagent.exe"
