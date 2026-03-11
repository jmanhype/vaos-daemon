#!/bin/bash
# OSA Development Launcher
# Starts both the Elixir backend and the desktop frontend in one command.
#
# Usage:
#   ./dev.sh              Start backend + frontend (browser mode)
#   ./dev.sh --tauri       Start backend + frontend (native Tauri window)
#   ./dev.sh --backend     Start backend only
#   ./dev.sh --frontend    Start frontend only

set -e
cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${BLUE}${BOLD}  OSA${NC}${DIM} — Optimal System Agent${NC}"
  echo -e "${DIM}  ─────────────────────────────${NC}"
  echo ""
}

check_deps() {
  local missing=0

  if ! command -v elixir &>/dev/null; then
    echo -e "${RED}  Missing: elixir${NC} — install from https://elixir-lang.org/install.html"
    missing=1
  fi

  if ! command -v node &>/dev/null; then
    echo -e "${RED}  Missing: node${NC} — install from https://nodejs.org or use nvm"
    missing=1
  fi

  if [ "$missing" -eq 1 ]; then
    echo ""
    exit 1
  fi
}

start_backend() {
  echo -e "${GREEN}  Starting backend...${NC}  ${DIM}(Elixir/OTP on :9089)${NC}"

  # Load env if present
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi

  # Ensure deps are fetched
  if [ ! -d deps ] || [ ! -d _build ]; then
    echo -e "${DIM}  Fetching dependencies...${NC}"
    mix deps.get --quiet
  fi

  mix osa.serve &
  BACKEND_PID=$!
  echo -e "${DIM}  Backend PID: ${BACKEND_PID}${NC}"
}

start_frontend() {
  local mode="${1:-dev}"
  echo -e "${GREEN}  Starting frontend...${NC}  ${DIM}(SvelteKit on :5199)${NC}"

  cd desktop

  # Install npm deps if needed
  if [ ! -d node_modules ]; then
    echo -e "${DIM}  Installing npm dependencies...${NC}"
    npm install --silent
  fi

  if [ "$mode" = "tauri" ]; then
    echo -e "${BLUE}  Mode: Native Tauri window${NC}"
    npm run tauri:dev &
  else
    echo -e "${BLUE}  Mode: Browser — http://localhost:5199${NC}"
    npm run dev &
  fi
  FRONTEND_PID=$!
  echo -e "${DIM}  Frontend PID: ${FRONTEND_PID}${NC}"
  cd ..
}

cleanup() {
  echo ""
  echo -e "${DIM}  Shutting down...${NC}"
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null
  [ -n "$FRONTEND_PID" ] && kill "$FRONTEND_PID" 2>/dev/null
  wait 2>/dev/null
  echo -e "${GREEN}  Done.${NC}"
}

trap cleanup EXIT INT TERM

# ── Main ──────────────────────────────────────────────────────

banner
check_deps

case "${1:-}" in
  --backend)
    start_backend
    echo ""
    echo -e "${GREEN}  Backend running.${NC} Press Ctrl+C to stop."
    wait
    ;;
  --frontend)
    start_frontend "${2:-dev}"
    echo ""
    echo -e "${GREEN}  Frontend running.${NC} Press Ctrl+C to stop."
    wait
    ;;
  --tauri)
    start_backend
    sleep 2
    start_frontend tauri
    echo ""
    echo -e "${GREEN}  Both services running.${NC} Press Ctrl+C to stop."
    wait
    ;;
  *)
    start_backend
    sleep 2
    start_frontend dev
    echo ""
    echo -e "${GREEN}  Both services running.${NC} Press Ctrl+C to stop."
    echo -e "${BLUE}  Open http://localhost:5199${NC}"
    wait
    ;;
esac
