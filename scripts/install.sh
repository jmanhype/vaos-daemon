#!/usr/bin/env bash
# scripts/install.sh — One-line installer for OSA Agent.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.sh | bash
#
# What it does:
#   1. Checks prerequisites (Elixir, Rust, curl)
#   2. Clones repo to ~/.osa/agent/ (or uses existing)
#   3. Builds the Rust TUI
#   4. Fetches Elixir dependencies
#   5. Installs `osa` and `osagent` to ~/.local/bin
#   6. Sets up PATH if needed
#
# After install:
#   osa      — start backend + TUI (recommended)
#   osagent  — TUI only (auto-starts backend)

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

info()  { echo -e "${CYAN}→${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
fail()  { echo -e "${RED}✗${RESET} $*"; exit 1; }

# ── Config ─────────────────────────────────────────────────────────
OSA_DIR="${HOME}/.osa"
INSTALL_DIR="${HOME}/.local/bin"
REPO_URL="${OSA_REPO_URL:-https://github.com/Miosa-osa/OptimalSystemAgent.git}"
BRANCH="${OSA_BRANCH:-main}"
AGENT_DIR="${OSA_DIR}/agent"

# ── Banner ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  ◈ OSA Agent — Installer${RESET}"
echo -e "${DIM}  Your OS, Supercharged${RESET}"
echo ""

# ── Detect OS ──────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) fail "Unsupported OS: $(uname -s)" ;;
  esac
}
detect_os

if [ "$OS" = "windows" ]; then
  warn "Windows detected. Native Windows support is experimental."
  warn "Consider using WSL2 for the best experience."
fi

# ── Check prerequisites ───────────────────────────────────────────
check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

missing=()

if ! check_cmd git; then
  missing+=("git")
fi

if ! check_cmd curl; then
  missing+=("curl")
fi

# Check Elixir/Erlang
has_elixir=false
if check_cmd elixir && check_cmd mix; then
  has_elixir=true
fi

# Check Rust
has_rust=false
if check_cmd cargo; then
  has_rust=true
fi

if [ ${#missing[@]} -gt 0 ]; then
  fail "Missing required tools: ${missing[*]}. Install them first."
fi

# ── Install Rust if needed ─────────────────────────────────────────
if [ "$has_rust" = false ]; then
  info "Rust not found. Installing via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env" 2>/dev/null || true
  if ! check_cmd cargo; then
    fail "Rust installation failed. Install manually: https://rustup.rs"
  fi
  ok "Rust installed"
fi

# ── Install Elixir if needed ──────────────────────────────────────
if [ "$has_elixir" = false ]; then
  echo ""
  warn "Elixir/Erlang not found."
  echo ""
  if [ "$OS" = "macos" ]; then
    echo "  Install with Homebrew:"
    echo -e "    ${BOLD}brew install elixir${RESET}"
  elif [ "$OS" = "linux" ]; then
    echo "  Install with your package manager, e.g.:"
    echo -e "    ${BOLD}sudo apt install elixir erlang${RESET}"
    echo "  Or use asdf:"
    echo -e "    ${BOLD}asdf plugin add erlang && asdf install erlang latest${RESET}"
    echo -e "    ${BOLD}asdf plugin add elixir && asdf install elixir latest${RESET}"
  fi
  echo ""

  # Try brew on macOS automatically
  if [ "$OS" = "macos" ] && check_cmd brew; then
    read -rp "Install Elixir via Homebrew now? [Y/n] " yn
    yn="${yn:-Y}"
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      info "Installing Elixir..."
      brew install elixir
      if check_cmd elixir; then
        ok "Elixir installed"
        has_elixir=true
      fi
    fi
  fi

  if [ "$has_elixir" = false ]; then
    fail "Elixir is required. Install it and re-run this script."
  fi
fi

# ── Clone or update repo ──────────────────────────────────────────
mkdir -p "$OSA_DIR"

if [ -d "$AGENT_DIR/.git" ]; then
  info "Updating existing installation..."
  (cd "$AGENT_DIR" && git pull --ff-only origin "$BRANCH" 2>&1) || true
  ok "Updated"
elif [ -d "$AGENT_DIR" ]; then
  # Directory exists but isn't a git repo — use as-is (local dev)
  info "Using existing directory: $AGENT_DIR"
else
  info "Cloning OSA Agent..."
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$AGENT_DIR" 2>&1 | tail -2
  ok "Cloned to $AGENT_DIR"
fi

# Also support running from a local checkout (e.g. during development)
# If this script is run from inside a repo, use that instead
SCRIPT_SELF="${BASH_SOURCE[0]:-$0}"
if [ -f "$(dirname "$SCRIPT_SELF")/../mix.exs" ] 2>/dev/null; then
  AGENT_DIR="$(cd "$(dirname "$SCRIPT_SELF")/.." && pwd)"
  info "Running from local checkout: $AGENT_DIR"
fi

# ── Store project root ────────────────────────────────────────────
echo "$AGENT_DIR" > "$OSA_DIR/project_root"

# ── Build Rust TUI ────────────────────────────────────────────────
TUI_DIR="$AGENT_DIR/priv/rust/tui"
if [ ! -d "$TUI_DIR" ]; then
  fail "TUI source not found at $TUI_DIR"
fi

info "Building TUI (this takes ~60s on first run)..."
(cd "$TUI_DIR" && cargo build --release 2>&1 | grep -E "Compiling|Finished|error" | tail -5)
if [ ! -f "$TUI_DIR/target/release/osagent" ]; then
  fail "TUI build failed. Check output above."
fi
ok "TUI built"

# ── Fetch Elixir deps ─────────────────────────────────────────────
info "Fetching Elixir dependencies..."
(cd "$AGENT_DIR" && mix local.hex --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix local.rebar --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix deps.get 2>&1 | tail -3)
(cd "$AGENT_DIR" && mix compile 2>&1 | tail -3)
ok "Dependencies ready"

# ── Install binaries ──────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# Copy TUI binary
cp "$TUI_DIR/target/release/osagent" "$INSTALL_DIR/osagent"
chmod +x "$INSTALL_DIR/osagent"

# Ad-hoc sign on macOS (Gatekeeper kills unsigned copied binaries)
if [ "$OS" = "macos" ]; then
  codesign -s - "$INSTALL_DIR/osagent" 2>/dev/null || true
fi

ok "Installed osagent → $INSTALL_DIR/osagent"

# Symlink launcher
ln -sf "$AGENT_DIR/bin/osa" "$INSTALL_DIR/osa"
ok "Linked osa → $INSTALL_DIR/osa"

# ── Ensure PATH ───────────────────────────────────────────────────
path_updated=false
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  # Detect shell config file
  SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
  case "$SHELL_NAME" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac

  EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
  if [ "$SHELL_NAME" = "fish" ]; then
    EXPORT_LINE='set -gx PATH $HOME/.local/bin $PATH'
  fi

  # Add to shell config if not already there
  if [ -f "$SHELL_RC" ] && grep -qF '.local/bin' "$SHELL_RC" 2>/dev/null; then
    : # Already present
  else
    echo "" >> "$SHELL_RC"
    echo "# OSA Agent" >> "$SHELL_RC"
    echo "$EXPORT_LINE" >> "$SHELL_RC"
    path_updated=true
    ok "Added ~/.local/bin to PATH in $SHELL_RC"
  fi
fi

# ── Create default config if needed ───────────────────────────────
mkdir -p "$OSA_DIR/logs"

if [ ! -f "$OSA_DIR/.env" ]; then
  cat > "$OSA_DIR/.env" <<'ENVEOF'
# OSA Agent Configuration
# Uncomment and set your API key for cloud providers:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# GROQ_API_KEY=gsk_...

# Default: Ollama (local, no API key needed)
# OSA_DEFAULT_PROVIDER=ollama
# OSA_PORT=8089
ENVEOF
  ok "Created config template → $OSA_DIR/.env"
fi

# ── Create logs dir ───────────────────────────────────────────────
mkdir -p "$OSA_DIR/logs"

# ── Success ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ◈ OSA Agent installed successfully!${RESET}"
echo ""
echo -e "  ${DIM}Locations:${RESET}"
echo -e "    Agent:   $AGENT_DIR"
echo -e "    Binary:  $INSTALL_DIR/osagent"
echo -e "    Config:  $OSA_DIR/.env"
echo -e "    Logs:    $OSA_DIR/logs/"
echo ""

if [ "$path_updated" = true ]; then
  echo -e "  ${YELLOW}Reload your shell first:${RESET}"
  echo -e "    ${BOLD}source $SHELL_RC${RESET}"
  echo ""
fi

echo -e "  ${DIM}Quick start:${RESET}"
echo -e "    ${BOLD}osa${RESET}             Start backend + TUI"
echo -e "    ${BOLD}osagent${RESET}         TUI only (auto-starts backend)"
echo ""
echo -e "  ${DIM}Configure:${RESET}"
echo -e "    ${BOLD}nano ~/.osa/.env${RESET} Set API keys for cloud providers"
echo -e "    ${DIM}Default: Ollama (local, no key needed)${RESET}"
echo ""
