#!/usr/bin/env bash
# =============================================================================
# OSA Desktop — Developer Setup
# Sets up the local development environment for contributors.
# Usage: ./scripts/dev-setup.sh
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Output helpers
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

log()     { printf "${BLUE}[dev]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${RESET}   %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
die()     { printf "${RED}[ERR]${RESET}  %s\n" "$*" >&2; exit 1; }
section() { printf "\n${BOLD}▸ %s${RESET}\n" "$*"; }
hint()    { printf "  ${YELLOW}→${RESET} %s\n" "$*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Resolve the repo root regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --------------------------------------------------------------------------- #
# Header
# --------------------------------------------------------------------------- #
printf "\n${BOLD}OSA Desktop — Developer Setup${RESET}\n"
printf "Repo root: %s\n" "$REPO_ROOT"

# --------------------------------------------------------------------------- #
# Check: Rust
# --------------------------------------------------------------------------- #
section "Rust toolchain"

if ! command_exists rustc; then
  warn "Rust not found."
  hint "Install via: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  die "Rust is required. Install it and re-run this script."
fi

# Activate cargo env if present
# shellcheck source=/dev/null
[ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
export PATH="${HOME}/.cargo/bin:${PATH}"

ok "rustc: $(rustc --version)"
ok "cargo: $(cargo --version)"

# Check that the stable toolchain is active (Tauri requires stable)
if ! rustup toolchain list 2>/dev/null | grep -q 'stable'; then
  log "Installing stable Rust toolchain..."
  rustup toolchain install stable
fi

# Show active targets
log "Active Rust targets:"
rustup target list --installed | sed 's/^/    /'

# --------------------------------------------------------------------------- #
# Check: Node.js + npm
# --------------------------------------------------------------------------- #
section "Node.js"

if ! command_exists node; then
  warn "Node.js not found."
  hint "Install via fnm: curl -fsSL https://fnm.vercel.app/install | bash"
  hint "Or visit: https://nodejs.org"
  die "Node.js is required. Install it and re-run this script."
fi

NODE_VERSION="$(node --version)"
NODE_MAJOR="${NODE_VERSION#v}"
NODE_MAJOR="${NODE_MAJOR%%.*}"

ok "node: $NODE_VERSION"
ok "npm: $(npm --version)"

if [ "$NODE_MAJOR" -lt 18 ]; then
  warn "Node.js >= 18 is recommended. Current: $NODE_VERSION"
  warn "Some SvelteKit features may not work on older Node."
fi

# --------------------------------------------------------------------------- #
# Check: OS-specific system dependencies
# --------------------------------------------------------------------------- #
section "System dependencies"

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not found."
    hint "Run: xcode-select --install"
    die "Xcode CLT required on macOS."
  fi
  ok "Xcode Command Line Tools: present"

elif [ "$OS" = "Linux" ]; then
  MISSING_DEPS=()

  # Check pkg-config as a proxy for having dev headers installed
  if ! command_exists pkg-config; then
    MISSING_DEPS+=(pkg-config)
  fi

  # Check for WebKit2GTK (the most critical Tauri Linux dependency)
  if ! pkg-config --exists webkit2gtk-4.1 2>/dev/null && \
     ! pkg-config --exists webkit2gtk-4.0 2>/dev/null; then
    MISSING_DEPS+=("libwebkit2gtk-4.1-dev (or webkit2gtk4.1-devel)")
  else
    ok "WebKit2GTK: present"
  fi

  # Check for libssl
  if ! pkg-config --exists openssl 2>/dev/null; then
    MISSING_DEPS+=("libssl-dev")
  else
    ok "OpenSSL: present"
  fi

  # Check for GTK3
  if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    MISSING_DEPS+=("libgtk-3-dev")
  else
    ok "GTK3: present"
  fi

  if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    warn "Missing Linux dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
      hint "$dep"
    done
    hint "Install on Debian/Ubuntu: sudo apt-get install libwebkit2gtk-4.1-dev libssl-dev libgtk-3-dev libayatana-appindicator3-dev"
    hint "Install on Fedora: sudo dnf install webkit2gtk4.1-devel openssl-devel gtk3-devel"
    die "Install missing dependencies and re-run this script."
  fi
fi

# --------------------------------------------------------------------------- #
# Check: tauri-cli
# --------------------------------------------------------------------------- #
section "Tauri CLI"

# Prefer the local npm version
if [ -f "$REPO_ROOT/node_modules/.bin/tauri" ]; then
  ok "tauri-cli: available via npm (local)"
elif command_exists cargo-tauri; then
  ok "tauri-cli: $(cargo tauri --version) (global cargo install)"
else
  warn "tauri-cli not found globally. It will be available after npm install."
fi

# --------------------------------------------------------------------------- #
# Install Node.js dependencies
# --------------------------------------------------------------------------- #
section "Installing npm dependencies"

cd "$REPO_ROOT"
log "Running npm ci..."
npm ci --prefer-offline
ok "npm dependencies installed"

# --------------------------------------------------------------------------- #
# Pre-fetch Rust dependencies
# --------------------------------------------------------------------------- #
section "Pre-fetching Rust dependencies"

log "Running cargo fetch (downloads crates, does not compile)..."
cd "$REPO_ROOT/src-tauri"
cargo fetch
ok "Rust crates cached"

# --------------------------------------------------------------------------- #
# Verify svelte-check
# --------------------------------------------------------------------------- #
section "Sanity checks"

cd "$REPO_ROOT"

log "Running svelte-kit sync..."
npm run check -- --help >/dev/null 2>&1 || true   # sync generates .svelte-kit types
npx svelte-kit sync 2>/dev/null || true
ok "svelte-kit sync complete"

log "Running cargo check (compile-checks only, no codegen)..."
cd "$REPO_ROOT/src-tauri"
cargo check --quiet
ok "cargo check passed"

# --------------------------------------------------------------------------- #
# Git hooks (optional)
# --------------------------------------------------------------------------- #
section "Git hooks"

cd "$REPO_ROOT"

if [ -d ".git" ]; then
  HOOKS_DIR=".git/hooks"

  # pre-commit: run svelte-check and cargo check quickly
  cat > "$HOOKS_DIR/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -e
echo "[pre-commit] Running svelte-check..."
npm run check -- --threshold error
echo "[pre-commit] Running cargo clippy..."
cd src-tauri && cargo clippy -- -D warnings
echo "[pre-commit] All checks passed."
HOOK
  chmod +x "$HOOKS_DIR/pre-commit"
  ok "pre-commit hook installed"
else
  warn "Not inside a git repo — skipping git hook setup."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
printf "\n"
printf "${GREEN}${BOLD}Dev environment ready.${RESET}\n\n"
printf "Available commands:\n"
printf "  %-30s %s\n" "npm run tauri:dev"      "Start app in development mode (hot-reload)"
printf "  %-30s %s\n" "npm run check"           "TypeScript + Svelte type-check"
printf "  %-30s %s\n" "npm run lint"            "Prettier + ESLint"
printf "  %-30s %s\n" "npm run format"          "Auto-format all files"
printf "  %-30s %s\n" "npm run tauri:build"     "Production build"
printf "  %-30s %s\n" "make dev"                "Alias for tauri:dev (if make is available)"
printf "\n"
printf "Backend sidecar binaries must be placed in:\n"
printf "  src-tauri/binaries/osagent-<target>\n"
printf "  See tauri.conf.json → bundle.externalBin for the expected name.\n\n"
