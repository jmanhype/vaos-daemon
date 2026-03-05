@echo off
docker run -it --rm ^
  -e OSA_DEFAULT_PROVIDER=ollama ^
  -e OLLAMA_URL=http://host.docker.internal:11434 ^
  -e OLLAMA_MODEL=gemma:2b ^
  -v osa_data:/root/.osa ^
  --add-host host.docker.internal:host-gateway ^
  osa:latest ^
  bin/osagent chat
