#!/usr/bin/env bash
# =============================================================================
# OSA Desktop — Unix Installer (macOS + Linux)
# Usage: curl -fsSL https://raw.githubusercontent.com/robertohluna/osa-desktop/main/scripts/install.sh | sh
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
APP_NAME="OSA"
REPO_URL="https://github.com/robertohluna/osa-desktop.git"
INSTALL_DIR="${HOME}/.local/osa-desktop"
NODE_VERSION="20"
RUST_MIN_VERSION="1.77.0"

# ANSI colours (disabled in non-interactive shells)
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

log()     { printf "${BLUE}[OSA]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${RESET}   %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
die()     { printf "${RED}[ERR]${RESET}  %s\n" "$*" >&2; exit 1; }
section() { printf "\n${BOLD}▸ %s${RESET}\n" "$*"; }

# --------------------------------------------------------------------------- #
# Detect OS and architecture
# --------------------------------------------------------------------------- #
section "Detecting platform"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)      die "Unsupported OS: $OS. This installer supports macOS and Linux only." ;;
esac

case "$ARCH" in
  arm64 | aarch64) ARCH_LABEL="arm64" ;;
  x86_64 | amd64)  ARCH_LABEL="x86_64" ;;
  *)                die "Unsupported architecture: $ARCH" ;;
esac

ok "Platform: $PLATFORM ($ARCH_LABEL)"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root_or_sudo() {
  if [ "$EUID" -ne 0 ] && ! command_exists sudo; then
    die "This step requires root or sudo. Please run as root or install sudo."
  fi
}

run_sudo() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# --------------------------------------------------------------------------- #
# System dependencies
# --------------------------------------------------------------------------- #
section "Checking system dependencies"

install_macos_deps() {
  # Xcode Command Line Tools
  if ! xcode-select -p >/dev/null 2>&1; then
    log "Installing Xcode Command Line Tools..."
    xcode-select --install
    # Wait for installation to complete
    until xcode-select -p >/dev/null 2>&1; do
      sleep 5
      log "Waiting for Xcode CLT installation to complete..."
    done
    ok "Xcode Command Line Tools installed"
  else
    ok "Xcode Command Line Tools: present"
  fi

  # Homebrew (used for any additional tools)
  if ! command_exists brew; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for the current session
    if [ "$ARCH_LABEL" = "arm64" ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    else
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  else
    ok "Homebrew: present"
  fi
}

install_linux_deps() {
  require_root_or_sudo

  # Detect package manager
  if command_exists apt-get; then
    PKG_MGR="apt-get"
    INSTALL_CMD="apt-get install -y"
    UPDATE_CMD="apt-get update -qq"
  elif command_exists dnf; then
    PKG_MGR="dnf"
    INSTALL_CMD="dnf install -y"
    UPDATE_CMD="dnf check-update || true"
  elif command_exists pacman; then
    PKG_MGR="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    UPDATE_CMD="pacman -Sy"
  else
    die "No supported package manager found (apt-get, dnf, pacman). Install dependencies manually."
  fi

  log "Updating package index..."
  run_sudo $UPDATE_CMD

  # WebKit2GTK and GTK3 (required for Tauri webview)
  if [ "$PKG_MGR" = "apt-get" ]; then
    LINUX_DEPS=(
      libwebkit2gtk-4.1-dev
      libssl-dev
      libgtk-3-dev
      libayatana-appindicator3-dev
      librsvg2-dev
      patchelf
      curl
      wget
      file
      build-essential
    )
  elif [ "$PKG_MGR" = "dnf" ]; then
    LINUX_DEPS=(
      webkit2gtk4.1-devel
      openssl-devel
      gtk3-devel
      libayatana-appindicator-gtk3-devel
      librsvg2-devel
      patchelf
      curl
      wget
      file
      gcc
      make
    )
  else
    # Arch-based — package names differ
    LINUX_DEPS=(
      webkit2gtk-4.1
      openssl
      gtk3
      libayatana-appindicator
      librsvg
      patchelf
      curl
      wget
      file
      base-devel
    )
  fi

  log "Installing Linux system dependencies..."
  run_sudo $INSTALL_CMD "${LINUX_DEPS[@]}"
  ok "Linux system dependencies installed"
}

if [ "$PLATFORM" = "macos" ]; then
  install_macos_deps
else
  install_linux_deps
fi

# --------------------------------------------------------------------------- #
# Rust
# --------------------------------------------------------------------------- #
section "Checking Rust toolchain"

install_rust() {
  log "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  # Source cargo env for current session
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
  ok "Rust installed"
}

if command_exists rustc; then
  CURRENT_RUST="$(rustc --version | awk '{print $2}')"
  log "Rust found: $CURRENT_RUST"
  # shellcheck source=/dev/null
  [ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
else
  install_rust
fi

# Ensure cargo is in PATH
export PATH="${HOME}/.cargo/bin:${PATH}"

if ! command_exists cargo; then
  die "cargo not found after Rust installation. Please restart your shell and re-run this script."
fi
ok "cargo: $(cargo --version)"

# --------------------------------------------------------------------------- #
# Node.js
# --------------------------------------------------------------------------- #
section "Checking Node.js"

install_node_via_fnm() {
  log "Installing fnm (Fast Node Manager)..."
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "${HOME}/.local/fnm" --skip-shell

  export PATH="${HOME}/.local/fnm:${PATH}"
  eval "$(fnm env --use-on-cd)"

  fnm install "$NODE_VERSION"
  fnm use "$NODE_VERSION"
  fnm default "$NODE_VERSION"
  ok "Node.js $NODE_VERSION installed via fnm"
}

if command_exists node; then
  CURRENT_NODE="$(node --version)"
  log "Node.js found: $CURRENT_NODE"
else
  install_node_via_fnm
fi

# Ensure npm is available
if ! command_exists npm; then
  die "npm not found. Node.js installation may be incomplete."
fi
ok "npm: $(npm --version)"

# --------------------------------------------------------------------------- #
# Clone / download repository
# --------------------------------------------------------------------------- #
section "Fetching OSA Desktop source"

if [ -d "$INSTALL_DIR/.git" ]; then
  log "Repository already cloned at $INSTALL_DIR — pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "Cloning $REPO_URL into $INSTALL_DIR..."
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

ok "Source ready at $INSTALL_DIR"

# --------------------------------------------------------------------------- #
# Install JS dependencies
# --------------------------------------------------------------------------- #
section "Installing Node.js dependencies"

cd "$INSTALL_DIR"
npm ci --prefer-offline
ok "npm dependencies installed"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
section "Building OSA Desktop (this may take several minutes)"

npm run tauri:build

# --------------------------------------------------------------------------- #
# Install built application
# --------------------------------------------------------------------------- #
section "Installing OSA"

if [ "$PLATFORM" = "macos" ]; then
  # Find the .app bundle produced by tauri build
  APP_BUNDLE=$(find "$INSTALL_DIR/src-tauri/target/release/bundle/macos" -name "*.app" -maxdepth 1 | head -1)

  if [ -z "$APP_BUNDLE" ]; then
    die "Could not find .app bundle. Check build output in $INSTALL_DIR/src-tauri/target/release/bundle/"
  fi

  DEST="/Applications/$(basename "$APP_BUNDLE")"

  if [ -d "$DEST" ]; then
    log "Removing existing installation at $DEST..."
    rm -rf "$DEST"
  fi

  log "Copying $(basename "$APP_BUNDLE") to /Applications/..."
  cp -r "$APP_BUNDLE" /Applications/
  ok "$APP_NAME installed to $DEST"

elif [ "$PLATFORM" = "linux" ]; then
  # Prefer AppImage for portability
  APPIMAGE=$(find "$INSTALL_DIR/src-tauri/target/release/bundle/appimage" -name "*.AppImage" -maxdepth 1 | head -1)

  if [ -n "$APPIMAGE" ]; then
    DEST_BIN="${HOME}/.local/bin/osa"
    mkdir -p "${HOME}/.local/bin"
    cp "$APPIMAGE" "$DEST_BIN"
    chmod +x "$DEST_BIN"
    ok "$APP_NAME AppImage installed to $DEST_BIN"

    # Create .desktop entry
    DESKTOP_DIR="${HOME}/.local/share/applications"
    ICON_DIR="${HOME}/.local/share/icons/hicolor/128x128/apps"
    mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

    # Copy icon
    if [ -f "$INSTALL_DIR/src-tauri/icons/128x128.png" ]; then
      cp "$INSTALL_DIR/src-tauri/icons/128x128.png" "$ICON_DIR/osa-desktop.png"
    fi

    cat > "$DESKTOP_DIR/osa-desktop.desktop" <<EOF
[Desktop Entry]
Name=OSA
Comment=Optimal System Agent Desktop
Exec=${DEST_BIN}
Icon=osa-desktop
Terminal=false
Type=Application
Categories=Utility;Development;
StartupWMClass=OSA
EOF

    # Refresh desktop database
    if command_exists update-desktop-database; then
      update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi

    ok "Desktop entry created at $DESKTOP_DIR/osa-desktop.desktop"

    # Ensure ~/.local/bin is on PATH
    if ! echo "$PATH" | grep -q "${HOME}/.local/bin"; then
      warn "Add the following to your shell profile to use 'osa' from your terminal:"
      warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

  else
    # Fallback: try .deb
    DEB=$(find "$INSTALL_DIR/src-tauri/target/release/bundle/deb" -name "*.deb" -maxdepth 1 | head -1)
    if [ -n "$DEB" ]; then
      log "Installing .deb package..."
      run_sudo dpkg -i "$DEB"
      ok "$APP_NAME installed via .deb"
    else
      die "No AppImage or .deb found. Check $INSTALL_DIR/src-tauri/target/release/bundle/"
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
printf "\n"
printf "${GREEN}${BOLD}╔══════════════════════════════════════╗${RESET}\n"
printf "${GREEN}${BOLD}║   OSA Desktop installed successfully  ║${RESET}\n"
printf "${GREEN}${BOLD}╚══════════════════════════════════════╝${RESET}\n"
printf "\n"

if [ "$PLATFORM" = "macos" ]; then
  printf "Launch: open -a OSA\n"
  printf "       or find OSA in your Applications folder.\n"
else
  printf "Launch: osa\n"
  printf "       or find OSA in your application menu.\n"
fi

printf "\nSource kept at: %s\n" "$INSTALL_DIR"
printf "To update, re-run this installer.\n\n"
