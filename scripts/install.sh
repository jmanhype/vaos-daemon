#!/usr/bin/env bash
# scripts/install.sh — One-line installer for OSA Agent.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.sh | bash
#
# What it does:
#   1. Auto-installs prerequisites (Elixir, Erlang, Rust) — no questions asked
#   2. Clones repo to ~/.osa/agent/ (or updates existing)
#   3. Installs Linux build dependencies (libssl, libxcb, libasound, etc.)
#   4. Builds the Rust TUI
#   5. Fetches Elixir dependencies & compiles
#   6. Installs `osa` and `osagent` to ~/.local/bin
#   7. Sets up PATH if needed
#
# After install:
#   osa        — start backend + TUI
#   osagent    — same as osa (alias)
#   osa update — pull latest + recompile

set -euo pipefail

# ── Safe defaults ────────────────────────────────────────────────
HOME="${HOME:-/root}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

# sudo helper: skip sudo when already root
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

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

# ── Helper: check command exists ───────────────────────────────────
check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# ── Setup locale (Linux) ─────────────────────────────────────────
if [ "$OS" = "linux" ] && check_cmd apt-get; then
  # Elixir requires UTF-8 locale — set it up before anything else
  if ! locale 2>/dev/null | grep -qi "utf-8" 2>/dev/null; then
    info "Setting up UTF-8 locale..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq locales 2>/dev/null || true
    $SUDO locale-gen en_US.UTF-8 2>/dev/null || true
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    ok "Locale configured"
  fi
fi

# ── Install git if missing ─────────────────────────────────────────
if ! check_cmd git; then
  if [ "$OS" = "macos" ]; then
    info "Installing Xcode Command Line Tools (includes git)..."
    xcode-select --install 2>/dev/null || true
    # Wait for installation
    until check_cmd git; do sleep 2; done
  elif [ "$OS" = "linux" ]; then
    info "Installing git..."
    if check_cmd apt-get; then
      $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git
    elif check_cmd dnf; then
      $SUDO dnf install -y -q git
    elif check_cmd pacman; then
      $SUDO pacman -Sy --noconfirm git
    else
      fail "Cannot auto-install git. Install it manually and re-run."
    fi
  fi
  check_cmd git || fail "git installation failed."
  ok "git installed"
fi

# ── Install curl if missing ────────────────────────────────────────
if ! check_cmd curl; then
  if [ "$OS" = "linux" ]; then
    info "Installing curl..."
    if check_cmd apt-get; then
      $SUDO apt-get install -y -qq curl
    elif check_cmd dnf; then
      $SUDO dnf install -y -q curl
    elif check_cmd pacman; then
      $SUDO pacman -Sy --noconfirm curl
    fi
  fi
  check_cmd curl || fail "curl is required. Install it manually."
  ok "curl installed"
fi

# ── Install Rust if missing ───────────────────────────────────────
if ! check_cmd cargo; then
  info "Installing Rust (needed for the TUI)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
  . "${HOME}/.cargo/env" 2>/dev/null || true
  export PATH="${HOME}/.cargo/bin:$PATH"
  check_cmd cargo || fail "Rust installation failed. Install manually: https://rustup.rs"
  ok "Rust installed"
else
  ok "Rust found: $(rustc --version 2>/dev/null || echo 'unknown')"
fi

# ── Install Erlang + Elixir if missing ────────────────────────────
if ! check_cmd elixir || ! check_cmd mix; then
  info "Installing Erlang + Elixir..."

  if [ "$OS" = "macos" ]; then
    # Install Homebrew if missing
    if ! check_cmd brew; then
      info "Installing Homebrew first..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to PATH for this session
      if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
    brew install erlang elixir
    ok "Erlang + Elixir installed via Homebrew"

  elif [ "$OS" = "linux" ]; then
    if check_cmd apt-get; then
      info "Adding Erlang Solutions repo..."
      $SUDO apt-get install -y -qq software-properties-common apt-transport-https
      # Try direct package first (works on Ubuntu 22.04+)
      $SUDO apt-get install -y -qq erlang elixir 2>/dev/null || {
        # Fallback: install from Erlang Solutions (use curl, not wget)
        curl -fsSLo /tmp/erlang-solutions.deb https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb 2>/dev/null || true
        if [ -f /tmp/erlang-solutions.deb ]; then
          $SUDO dpkg -i /tmp/erlang-solutions.deb 2>/dev/null || true
          rm -f /tmp/erlang-solutions.deb
          $SUDO apt-get update -qq
          $SUDO apt-get install -y -qq esl-erlang elixir
        else
          fail "Could not download Erlang Solutions package. Install Erlang 27+ and Elixir 1.17+ manually."
        fi
      }
    elif check_cmd dnf; then
      $SUDO dnf install -y -q erlang elixir
    elif check_cmd pacman; then
      $SUDO pacman -Sy --noconfirm erlang elixir
    else
      fail "Cannot auto-install Elixir. Install Erlang 27+ and Elixir 1.17+ manually."
    fi
    ok "Erlang + Elixir installed"
  fi

  # Verify
  if ! check_cmd elixir; then
    fail "Elixir installation failed. Install Erlang 27+ and Elixir 1.17+ manually."
  fi
else
  ok "Elixir found: $(elixir --version 2>/dev/null | tail -1 || echo 'unknown')"
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
SCRIPT_SELF="${BASH_SOURCE[0]:-$0}"
if [ -f "$(dirname "$SCRIPT_SELF")/../mix.exs" ] 2>/dev/null; then
  AGENT_DIR="$(cd "$(dirname "$SCRIPT_SELF")/.." && pwd)"
  info "Running from local checkout: $AGENT_DIR"
fi

# ── Store project root ────────────────────────────────────────────
echo "$AGENT_DIR" > "$OSA_DIR/project_root"

# ── Install Linux build dependencies ─────────────────────────────
# Needed for Rust TUI crates: arboard (libxcb), cpal (libasound),
# syntect (libonig), reqwest (libssl), general (pkg-config, gcc)
if [ "$OS" = "linux" ] && check_cmd apt-get; then
  info "Installing build dependencies..."
  $SUDO apt-get install -y -qq \
    build-essential \
    pkg-config \
    libssl-dev \
    libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
    libasound2-dev \
    libonig-dev \
    2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
  ok "Build dependencies ready"
fi

# ── Build Rust TUI ────────────────────────────────────────────────
TUI_DIR="$AGENT_DIR/priv/rust/tui"
if [ ! -d "$TUI_DIR" ]; then
  fail "TUI source not found at $TUI_DIR"
fi

info "Building TUI (this takes ~60s on first run)..."
(cd "$TUI_DIR" && cargo build --release 2>&1 | grep -E "Compiling|Finished|error" | tail -5) || true
if [ ! -f "$TUI_DIR/target/release/osagent" ]; then
  fail "TUI build failed. Check output above."
fi
ok "TUI built"

# ── Fetch Elixir deps ─────────────────────────────────────────────
info "Fetching Elixir dependencies..."
(cd "$AGENT_DIR" && mix local.hex --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix local.rebar --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix deps.get 2>&1 | tail -3)
(cd "$AGENT_DIR" && mix compile 2>&1 | tail -5)
ok "Dependencies ready"

# ── Install binaries ──────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# Ensure bin/osa is executable (git clone may not preserve +x on some filesystems)
chmod +x "$AGENT_DIR/bin/osa"

# Both `osa` and `osagent` point to the shell launcher which starts
# backend + Rust TUI together.  The raw Rust binary stays internal.
ln -sf "$AGENT_DIR/bin/osa" "$INSTALL_DIR/osa"
ln -sf "$AGENT_DIR/bin/osa" "$INSTALL_DIR/osagent"
ok "Linked osa     → $INSTALL_DIR/osa"
ok "Linked osagent → $INSTALL_DIR/osagent"

# ── Ensure PATH ───────────────────────────────────────────────────
path_updated=false
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
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

  if [ -f "$SHELL_RC" ] && grep -qF '.local/bin' "$SHELL_RC" 2>/dev/null; then
    : # Already present
  else
    echo "" >> "$SHELL_RC"
    echo "# OSA Agent" >> "$SHELL_RC"
    echo "$EXPORT_LINE" >> "$SHELL_RC"
    path_updated=true
    ok "Added ~/.local/bin to PATH in $SHELL_RC"
  fi

  # Also write to .profile for non-interactive sessions (root VPS)
  if [ "$SHELL_NAME" = "bash" ] && [ -f "$HOME/.profile" ]; then
    if ! grep -qF '.local/bin' "$HOME/.profile" 2>/dev/null; then
      echo "" >> "$HOME/.profile"
      echo "# OSA Agent" >> "$HOME/.profile"
      echo "$EXPORT_LINE" >> "$HOME/.profile"
    fi
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

# ── Success ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ◈ OSA Agent installed successfully!${RESET}"
echo ""
echo -e "  ${DIM}Locations:${RESET}"
echo -e "    Agent:    $AGENT_DIR"
echo -e "    Commands: $INSTALL_DIR/osa, $INSTALL_DIR/osagent"
echo -e "    Config:   $OSA_DIR/.env"
echo -e "    Logs:     $OSA_DIR/logs/"
echo ""

if [ "$path_updated" = true ]; then
  echo -e "  ${YELLOW}Reload your shell first:${RESET}"
  echo -e "    ${BOLD}source $SHELL_RC${RESET}"
  echo ""
fi

echo -e "  ${DIM}Quick start:${RESET}"
echo -e "    ${BOLD}osa${RESET}             Start backend + TUI (same as osagent)"
echo -e "    ${BOLD}osa update${RESET}      Pull latest + recompile"
echo -e "    ${BOLD}osa setup${RESET}       Interactive setup wizard"
echo -e "    ${DIM}Default: Ollama (local, no key needed)${RESET}"
echo ""
