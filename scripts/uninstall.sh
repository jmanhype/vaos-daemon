#!/usr/bin/env bash
# scripts/uninstall.sh — Remove Daemon Agent installation.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/uninstall.sh | bash

set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
Daemon_DIR="${HOME}/.osa"

echo ""
echo "  ◈ Daemon Agent — Uninstall"
echo ""

removed=0

for f in "$INSTALL_DIR/daemon" "$INSTALL_DIR/osa"; do
  if [ -f "$f" ] || [ -L "$f" ]; then
    rm -f "$f"
    echo "  Removed $f"
    removed=$((removed + 1))
  fi
done

# Also check legacy ~/bin location
for f in "$HOME/bin/daemon" "$HOME/bin/osa"; do
  if [ -f "$f" ] || [ -L "$f" ]; then
    rm -f "$f"
    echo "  Removed $f"
    removed=$((removed + 1))
  fi
done

if [ "$removed" -eq 0 ]; then
  echo "  Nothing to remove."
else
  echo ""
  echo "  ✓ Binaries removed."
fi

echo ""
read -rp "  Remove ~/.osa/ config and logs? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  rm -rf "$Daemon_DIR"
  echo "  Removed $Daemon_DIR"
fi

read -rp "  Remove cloned repo at ~/.osa/agent/? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  rm -rf "${Daemon_DIR}/agent"
  echo "  Removed ${Daemon_DIR}/agent"
fi

echo ""
echo "  ✓ Done."
echo ""
