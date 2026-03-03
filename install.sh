#!/usr/bin/env bash
# install.sh — Install zsh-aisuggestions
#
# This script can be run via curl:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/EphemeralStudio/zsh-aisuggestions/main/install.sh)"
# or via wget:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/EphemeralStudio/zsh-aisuggestions/main/install.sh)"
# or from a local clone:
#   git clone https://github.com/EphemeralStudio/zsh-aisuggestions.git
#   cd zsh-aisuggestions && bash install.sh
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/zsh-aisuggestions"
CONFIG_DIR="${HOME}/.config/zsh-aisuggestions"
VENV_DIR="${INSTALL_DIR}/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd 2>/dev/null || echo "")"

# ─── Remote mode: download source if not running from a local clone ───────
if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/zsh-aisuggestions.plugin.zsh" ]]; then
    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT
    REPO_URL="https://github.com/EphemeralStudio/zsh-aisuggestions/archive/refs/heads/main.tar.gz"
    echo "[..] Downloading zsh-aisuggestions..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$REPO_URL" | tar -xz -C "$TMPDIR_DL"
    elif command -v wget &>/dev/null; then
        wget -qO- "$REPO_URL" | tar -xz -C "$TMPDIR_DL"
    else
        echo "[ERROR] curl or wget is required for remote install."
        exit 1
    fi
    SCRIPT_DIR="$TMPDIR_DL/zsh-aisuggestions-main"
    if [[ ! -f "$SCRIPT_DIR/zsh-aisuggestions.plugin.zsh" ]]; then
        echo "[ERROR] Download failed or archive structure unexpected."
        exit 1
    fi
    echo "[OK] Downloaded"
fi

echo "╔══════════════════════════════════════════╗"
echo "║   zsh-aisuggestions installer            ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Check Python ──────────────────────────────────────────────────────────
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then
        version=$("$cmd" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
            PYTHON_CMD="$cmd"
            echo "[OK] Found $cmd ($version)"
            break
        fi
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    echo "[ERROR] Python >= 3.10 is required but not found."
    echo "        Install Python 3.10+ and try again."
    exit 1
fi

# ─── Create install directory ──────────────────────────────────────────────
echo ""
echo "[..] Installing to ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"

# Copy plugin and sidecar
cp "$SCRIPT_DIR/zsh-aisuggestions.plugin.zsh" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/sidecar" "$INSTALL_DIR/"

# ─── Create virtual environment ───────────────────────────────────────────
echo "[..] Creating Python virtual environment"
"$PYTHON_CMD" -m venv "$VENV_DIR" 2>/dev/null || {
    echo "[WARN] Could not create venv, will use system Python"
}

if [[ -f "$VENV_DIR/bin/pip" ]]; then
    echo "[..] Installing Python dependencies"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    "$VENV_DIR/bin/pip" install --quiet pyyaml 2>/dev/null || true
    echo "[OK] Dependencies installed"
else
    echo "[WARN] No venv pip found, ensure pyyaml is installed: pip install pyyaml"
fi

# ─── Create default config ────────────────────────────────────────────────
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    echo "[..] Creating default config at ${CONFIG_DIR}/config.yaml"
    mkdir -p "$CONFIG_DIR"
    cp "$SCRIPT_DIR/config.example.yaml" "$CONFIG_DIR/config.yaml"
else
    echo "[OK] Config already exists at ${CONFIG_DIR}/config.yaml"
fi

# ─── Shell integration ────────────────────────────────────────────────────
ZSHRC="${HOME}/.zshrc"
PLUGIN_ACTIVATED=0

if [[ -n "${ZSH_CUSTOM:-}" || -d "${HOME}/.oh-my-zsh" ]]; then
    # ── oh-my-zsh: symlink + auto-inject into plugins=(...) ───────────
    ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
    OMZ_PLUGIN_DIR="${ZSH_CUSTOM}/plugins/zsh-aisuggestions"
    echo ""
    echo "[..] oh-my-zsh detected!"
    if [[ ! -d "$OMZ_PLUGIN_DIR" ]]; then
        mkdir -p "$(dirname "$OMZ_PLUGIN_DIR")"
        ln -sf "$INSTALL_DIR" "$OMZ_PLUGIN_DIR"
        echo "[OK] Symlinked to ${OMZ_PLUGIN_DIR}"
    else
        echo "[OK] oh-my-zsh plugin dir already exists"
    fi

    # Auto-add zsh-aisuggestions to the plugins=(...) list in .zshrc
    if [[ -f "$ZSHRC" ]]; then
        if grep -q 'plugins=.*zsh-aisuggestions' "$ZSHRC" 2>/dev/null; then
            echo "[OK] 'zsh-aisuggestions' already in plugins=(...)"
        elif grep -q '^plugins=(' "$ZSHRC" 2>/dev/null; then
            # Insert zsh-aisuggestions before the closing paren
            sed -i 's/^plugins=(\(.*\))/plugins=(\1 zsh-aisuggestions)/' "$ZSHRC"
            # Clean up double spaces that may result from empty plugins=()
            sed -i 's/^plugins=( /plugins=(/' "$ZSHRC"
            echo "[OK] Added 'zsh-aisuggestions' to plugins=(...) in ${ZSHRC}"
        else
            echo "[WARN] Could not find plugins=(...) in ${ZSHRC}"
            echo "       Please add 'zsh-aisuggestions' to your plugins list manually"
        fi
    fi
    PLUGIN_ACTIVATED=1
else
    # ── Non-oh-my-zsh: auto-append source line to .zshrc ─────────────
    SOURCE_LINE="source ${INSTALL_DIR}/zsh-aisuggestions.plugin.zsh"
    if [[ -f "$ZSHRC" ]] && grep -qF "zsh-aisuggestions.plugin.zsh" "$ZSHRC" 2>/dev/null; then
        echo "[OK] source line already present in ${ZSHRC}"
    else
        echo "" >> "$ZSHRC"
        echo "# zsh-aisuggestions — LLM-powered autosuggestions" >> "$ZSHRC"
        echo "$SOURCE_LINE" >> "$ZSHRC"
        echo "[OK] Added source line to ${ZSHRC}"
    fi
    PLUGIN_ACTIVATED=1
fi

# ─── Done ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Installation complete!                                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Set your API key (if not already set):                      ║"
echo "║                                                              ║"
echo "║    export OPENAI_API_KEY=\"sk-...\"                          ║"
echo "║                                                              ║"
echo "║  Then restart your shell or run: exec zsh                    ║"
echo "║                                                              ║"
echo "║  Keybindings:                                                ║"
echo "║    Ctrl+G      → AI rewrite (translate / fix / complete)     ║"
echo "║    Ctrl+]      → AI inline autocomplete at cursor            ║"
echo "║    Tab / →     → Accept suggestion                           ║"
echo "║    Backspace   → Dismiss suggestion                          ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
