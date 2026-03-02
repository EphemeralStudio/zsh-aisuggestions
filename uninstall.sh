#!/usr/bin/env bash
# uninstall.sh — Remove zsh-aisuggestions
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/zsh-aisuggestions"
CONFIG_DIR="${HOME}/.config/zsh-aisuggestions"
SOCKET="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-$(id -u).sock"
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-$(id -u).pid"
TMPDIR_PATH="${TMPDIR:-/tmp}/zsh-aisuggestions-$(id -u)"

echo "Uninstalling zsh-aisuggestions..."

# Stop sidecar if running
if [[ -f "$PIDFILE" ]]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "[..] Stopping sidecar (PID $pid)"
        kill "$pid" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$PIDFILE"
fi

# Remove socket
rm -f "$SOCKET" 2>/dev/null

# Remove temp files
rm -rf "$TMPDIR_PATH" 2>/dev/null

# Remove oh-my-zsh symlink
ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
OMZ_LINK="${ZSH_CUSTOM}/plugins/zsh-aisuggestions"
if [[ -L "$OMZ_LINK" ]]; then
    echo "[..] Removing oh-my-zsh symlink"
    rm -f "$OMZ_LINK"
fi

# Remove install directory
if [[ -d "$INSTALL_DIR" ]]; then
    echo "[..] Removing ${INSTALL_DIR}"
    rm -rf "$INSTALL_DIR"
fi

echo ""
echo "Done! Remember to also:"
echo "  1. Remove the 'source ...' line from your ~/.zshrc"
echo "  2. Optionally remove config: rm -rf ${CONFIG_DIR}"
