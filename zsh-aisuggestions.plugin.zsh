#!/usr/bin/env zsh
# zsh-aisuggestions.plugin.zsh — LLM-powered autosuggestions for Zsh
#
# Source this file in your .zshrc:
#   source /path/to/zsh-aisuggestions/zsh-aisuggestions.plugin.zsh
#
# Usage:
#   Ctrl+G   → trigger AI suggestion (shown as ghost text)
#   → / Tab  → accept the suggestion (replaces your input)
#   Ctrl+→   → accept next word only
#   Ctrl+C   → dismiss suggestion and restore original input
#   any key  → dismiss suggestion, restore original input, continue typing

# ─── Guard ────────────────────────────────────────────────────────────────────
[[ -n "$_AISUG_LOADED" ]] && return
typeset -g _AISUG_LOADED=1

# ─── Configuration ────────────────────────────────────────────────────────────
typeset -g _AISUG_PLUGIN_DIR="${0:A:h}"
typeset -g _AISUG_SIDECAR_DIR="${_AISUG_PLUGIN_DIR}/sidecar"
typeset -g _AISUG_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-${UID}.sock"
typeset -g _AISUG_PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-${UID}.pid"
typeset -g _AISUG_TMPDIR="${TMPDIR:-/tmp}/zsh-aisuggestions-${UID}"
typeset -g _AISUG_GHOST_COLOR="${AISUG_GHOST_COLOR:-8}"

# ─── State (global, not ZLE-specific) ─────────────────────────────────────────
typeset -g _AISUG_SUGGESTION=""        # The full AI-suggested command
typeset -g _AISUG_MODE=""              # "complete" or "rewrite"
typeset -g _AISUG_ORIGINAL_BUFFER=""   # Buffer at the moment Ctrl+G was pressed
typeset -g _AISUG_ORIGINAL_CURSOR=0    # Cursor at the moment Ctrl+G was pressed
typeset -g _AISUG_LAST_BUFFER=""       # Buffer at time of last async request
typeset -g _AISUG_LAST_EXIT_CODE=0
typeset -g _AISUG_LAST_COMMAND=""
typeset -g _AISUG_ASYNC_PID=0
typeset -g _AISUG_SIDECAR_FAILED=0
typeset -g _AISUG_ACTIVE=0             # 1 when suggestion or loading indicator is showing
typeset -g _AISUG_PENDING_SUGGESTION="" # Written by TRAPUSR1, consumed by ZLE widget
typeset -g _AISUG_PENDING_MODE=""       # Written by TRAPUSR1, consumed by ZLE widget

mkdir -p "$_AISUG_TMPDIR" 2>/dev/null

# ─── Sidecar Management ──────────────────────────────────────────────────────

_aisug_sidecar_running() {
    if [[ -f "$_AISUG_PIDFILE" ]]; then
        local pid=$(< "$_AISUG_PIDFILE")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

_aisug_start_sidecar() {
    if (( _AISUG_SIDECAR_FAILED )); then
        return 1
    fi
    if _aisug_sidecar_running; then
        return 0
    fi

    local python_cmd=""
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            python_cmd="$cmd"
            break
        fi
    done
    if [[ -z "$python_cmd" ]]; then
        echo "zsh-aisuggestions: Python 3 not found. AI suggestions disabled." >&2
        _AISUG_SIDECAR_FAILED=1
        return 1
    fi

    local venv_python="${HOME}/.local/share/zsh-aisuggestions/venv/bin/python"
    [[ -x "$venv_python" ]] && python_cmd="$venv_python"

    local log_file="${_AISUG_TMPDIR}/sidecar.log"
    ( cd "$_AISUG_PLUGIN_DIR" && "$python_cmd" -m sidecar >> "$log_file" 2>&1 & )

    local retries=0
    while (( retries < 20 )); do
        [[ -S "$_AISUG_SOCKET" ]] && return 0
        sleep 0.05
        (( retries++ ))
    done

    echo "zsh-aisuggestions: Failed to start sidecar. Check ${log_file}" >&2
    _AISUG_SIDECAR_FAILED=1
    return 1
}

_aisug_ensure_sidecar() {
    _aisug_sidecar_running || _aisug_start_sidecar
}

# ─── Socket Communication ────────────────────────────────────────────────────

_aisug_query_socket() {
    local json_payload="$1"
    local python_cmd="python3"
    local venv_python="${HOME}/.local/share/zsh-aisuggestions/venv/bin/python"
    [[ -x "$venv_python" ]] && python_cmd="$venv_python"

    "$python_cmd" -c "
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.settimeout(8)
    sock.connect('${_AISUG_SOCKET}')
    sock.sendall(sys.stdin.buffer.read())
    sock.shutdown(socket.SHUT_WR)
    data = b''
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    print(data.decode(), end='')
finally:
    sock.close()
" <<< "$json_payload" 2>/dev/null
}

# ─── Context Gathering ────────────────────────────────────────────────────────

_aisug_git_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

_aisug_git_dirty() {
    if [[ -n "$(git status --porcelain 2>/dev/null | head -1)" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

_aisug_detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac
}

_aisug_recent_history() {
    local cmds=()
    local line
    while IFS= read -r line; do
        line="${line//\\/\\\\}"
        line="${line//\"/\\\"}"
        cmds+=("\"${line}\"")
    done < <(fc -ln -10 -1 2>/dev/null | sed 's/^[[:space:]]*//')
    local result="["
    local first=1
    for cmd in "${cmds[@]}"; do
        (( first )) && first=0 || result+=","
        result+="$cmd"
    done
    result+="]"
    echo "$result"
}

_aisug_build_request() {
    local buffer="$1"
    local cursor="$2"
    local cwd="$(pwd)"
    local git_branch="$(_aisug_git_branch)"
    local git_dirty="$(_aisug_git_dirty)"
    local os_name="$(_aisug_detect_os)"
    local recent_history="$(_aisug_recent_history)"

    local esc_buffer="${buffer//\\/\\\\}"
    esc_buffer="${esc_buffer//\"/\\\"}"
    local esc_cwd="${cwd//\\/\\\\}"
    esc_cwd="${esc_cwd//\"/\\\"}"
    local esc_last_cmd="${_AISUG_LAST_COMMAND//\\/\\\\}"
    esc_last_cmd="${esc_last_cmd//\"/\\\"}"

    cat <<EOF
{"type":"suggest","buffer":"${esc_buffer}","cursor_position":${cursor},"context":{"cwd":"${esc_cwd}","git_branch":"${git_branch}","git_dirty":${git_dirty},"last_exit_code":${_AISUG_LAST_EXIT_CODE},"last_command":"${esc_last_cmd}","shell":"zsh","os":"${os_name}","recent_history":${recent_history}}}
EOF
}

# ─── State Management (safe to call from any context) ─────────────────────────

_aisug_reset_state() {
    # Reset all state variables. Does NOT touch ZLE variables (BUFFER, POSTDISPLAY, etc.)
    _AISUG_SUGGESTION=""
    _AISUG_MODE=""
    _AISUG_ORIGINAL_BUFFER=""
    _AISUG_ORIGINAL_CURSOR=0
    _AISUG_ACTIVE=0
    _AISUG_PENDING_SUGGESTION=""
    _AISUG_PENDING_MODE=""
}

_aisug_kill_async() {
    if (( _AISUG_ASYNC_PID > 0 )); then
        kill "$_AISUG_ASYNC_PID" 2>/dev/null
        _AISUG_ASYNC_PID=0
    fi
}

# ─── ZLE Helpers (MUST only be called from within ZLE widgets) ────────────────

_aisug_zle_clear_ghost() {
    # Clear ghost text — safe only in ZLE context
    POSTDISPLAY=""
    region_highlight=()
}

_aisug_zle_show_ghost() {
    local suggestion="$1"
    local mode="$2"

    if [[ -z "$suggestion" ]]; then
        _aisug_zle_clear_ghost
        return
    fi

    _AISUG_SUGGESTION="$suggestion"
    _AISUG_MODE="$mode"

    if [[ "$mode" == "complete" ]]; then
        local suffix="${suggestion#$BUFFER}"
        if [[ -n "$suffix" ]]; then
            POSTDISPLAY="${suffix}"
        else
            POSTDISPLAY=""
        fi
    else
        # Rewrite: show the full replacement as a preview
        POSTDISPLAY="  [AI: ${suggestion}]"
    fi

    if [[ -n "$POSTDISPLAY" ]]; then
        region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
    else
        region_highlight=()
    fi
}

_aisug_zle_restore_and_clear() {
    # Restore original buffer and clear ghost — safe only in ZLE context
    if (( _AISUG_ACTIVE )); then
        BUFFER="$_AISUG_ORIGINAL_BUFFER"
        CURSOR="$_AISUG_ORIGINAL_CURSOR"
    fi
    _aisug_zle_clear_ghost
    _aisug_reset_state
}

# ─── Async Query ──────────────────────────────────────────────────────────────

_aisug_async_query() {
    local buffer="$1"
    local cursor="$2"

    _aisug_kill_async
    _AISUG_LAST_BUFFER="$buffer"

    local request=$(_aisug_build_request "$buffer" "$cursor")
    local result_file="${_AISUG_TMPDIR}/result.$$"
    local mode_file="${_AISUG_TMPDIR}/mode.$$"

    # Show loading indicator (we are in ZLE context here, called from _aisug_trigger)
    POSTDISPLAY="  ... thinking"
    region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
    zle -R

    # Run query in background, signal parent when done
    (
        local response
        response=$(_aisug_query_socket "$request")
        if [[ -n "$response" ]]; then
            echo "$response" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    s = r.get('suggestion', '')
    m = r.get('mode', 'complete')
    print(s, end='')
    print(m, end='', file=sys.stderr)
except:
    pass
" > "$result_file" 2> "$mode_file"
        else
            echo -n "" > "$result_file"
            echo -n "complete" > "$mode_file"
        fi
        kill -USR1 $$ 2>/dev/null
    ) &!
    _AISUG_ASYNC_PID=$!
}

# ── TRAPUSR1: Signal handler — NOT in ZLE context ────────────────────────────
# We cannot touch POSTDISPLAY/BUFFER/region_highlight here.
# Instead, stash the result in global vars and call `zle` to invoke a widget.
TRAPUSR1() {
    local result_file="${_AISUG_TMPDIR}/result.$$"
    local mode_file="${_AISUG_TMPDIR}/mode.$$"

    if [[ -f "$result_file" ]]; then
        _AISUG_PENDING_SUGGESTION=$(< "$result_file")
        _AISUG_PENDING_MODE="complete"
        [[ -f "$mode_file" ]] && _AISUG_PENDING_MODE=$(< "$mode_file")
        rm -f "$result_file" "$mode_file" 2>/dev/null
    fi

    _AISUG_ASYNC_PID=0

    # Schedule the ZLE widget to apply the result
    zle && zle _aisug_apply_result
}

# ── ZLE widget that applies the async result ──────────────────────────────────
# This runs in proper ZLE context, so POSTDISPLAY/BUFFER/region_highlight are writable.
_aisug_apply_result() {
    local suggestion="$_AISUG_PENDING_SUGGESTION"
    local mode="$_AISUG_PENDING_MODE"
    _AISUG_PENDING_SUGGESTION=""
    _AISUG_PENDING_MODE=""

    # Only update if buffer hasn't changed since the request
    if [[ "$BUFFER" == "$_AISUG_LAST_BUFFER" ]]; then
        if [[ -n "$suggestion" ]]; then
            _aisug_zle_show_ghost "$suggestion" "$mode"
        else
            # Empty response — clear loading indicator
            _aisug_zle_clear_ghost
            _AISUG_ACTIVE=0
        fi
    else
        # Buffer changed while we were waiting — discard result
        _aisug_zle_clear_ghost
        _aisug_reset_state
    fi

    zle -R
}
zle -N _aisug_apply_result

# ─── ZLE Widgets ──────────────────────────────────────────────────────────────

# ── Ctrl+G: Trigger AI suggestion ────────────────────────────────────────────
_aisug_trigger() {
    local buffer="$BUFFER"
    local cursor="$CURSOR"

    if [[ -z "$buffer" ]]; then
        zle -M "zsh-aisuggestions: type something first"
        return
    fi

    _aisug_ensure_sidecar
    if (( _AISUG_SIDECAR_FAILED )); then
        zle -M "zsh-aisuggestions: sidecar not available"
        return
    fi

    # Save original buffer state before entering suggestion mode
    _AISUG_ACTIVE=1
    _AISUG_ORIGINAL_BUFFER="$BUFFER"
    _AISUG_ORIGINAL_CURSOR="$CURSOR"

    # Fire async query
    _aisug_async_query "$buffer" "$cursor"
}
zle -N _aisug_trigger

# ── Accept: Replace BUFFER with the AI suggestion ────────────────────────────
_aisug_accept() {
    if [[ -n "$_AISUG_SUGGESTION" && (( _AISUG_ACTIVE )) ]]; then
        BUFFER="$_AISUG_SUGGESTION"
        CURSOR=${#BUFFER}
        _aisug_zle_clear_ghost
        _aisug_reset_state
    else
        zle forward-char
    fi
}
zle -N _aisug_accept

# ── Accept word: Progressively take words from the suggestion ─────────────────
_aisug_accept_word() {
    if [[ -n "$_AISUG_SUGGESTION" && (( _AISUG_ACTIVE )) ]]; then
        local suggestion="$_AISUG_SUGGESTION"

        if [[ "$_AISUG_MODE" == "complete" && "$suggestion" == "$BUFFER"* ]]; then
            local remaining="${suggestion#$BUFFER}"
            local next_chunk
            if [[ "$remaining" == " "* ]]; then
                local after_space="${remaining# }"
                local word="${after_space%% *}"
                next_chunk=" ${word}"
            else
                next_chunk="${remaining%% *}"
            fi
            if [[ "${BUFFER}${next_chunk}" == "$suggestion" || -z "${suggestion#${BUFFER}${next_chunk}}" ]]; then
                next_chunk="$remaining"
            fi
            BUFFER="${BUFFER}${next_chunk}"
        else
            if [[ "$suggestion" == "$BUFFER"* ]]; then
                local remaining="${suggestion#$BUFFER}"
                local next_chunk
                if [[ "$remaining" == " "* ]]; then
                    local after_space="${remaining# }"
                    local word="${after_space%% *}"
                    next_chunk=" ${word}"
                else
                    next_chunk="${remaining%% *}"
                fi
                if [[ "${BUFFER}${next_chunk}" == "$suggestion" || -z "${suggestion#${BUFFER}${next_chunk}}" ]]; then
                    next_chunk="$remaining"
                fi
                BUFFER="${BUFFER}${next_chunk}"
            else
                local first_word="${suggestion%% *}"
                BUFFER="${first_word}"
                _AISUG_MODE="complete"
            fi
        fi

        CURSOR=${#BUFFER}

        if [[ "$BUFFER" == "$suggestion" ]]; then
            _aisug_zle_clear_ghost
            _aisug_reset_state
        else
            _aisug_zle_show_ghost "$suggestion" "complete"
            zle -R
        fi
    else
        zle forward-word
    fi
}
zle -N _aisug_accept_word

# ── Dismiss/Reject: Restore original buffer ──────────────────────────────────
_aisug_dismiss() {
    if (( _AISUG_ACTIVE )); then
        _aisug_kill_async
        _aisug_zle_restore_and_clear
        zle -R
    else
        zle send-break
    fi
}
zle -N _aisug_dismiss

# ── Tab: Accept suggestion or fall through to normal completion ───────────────
_aisug_tab() {
    if [[ -n "$_AISUG_SUGGESTION" && (( _AISUG_ACTIVE )) ]]; then
        _aisug_accept
    else
        zle expand-or-complete
    fi
}
zle -N _aisug_tab

# ─── Auto-Dismiss on Normal Typing ───────────────────────────────────────────
# When the user types normally while a suggestion is showing:
#   1. Restore the original buffer (reject the suggestion)
#   2. Clear ghost text
#   3. Then perform the keystroke on the restored buffer

_aisug_self_insert_wrapper() {
    if (( _AISUG_ACTIVE )); then
        _aisug_kill_async
        _aisug_zle_restore_and_clear
    fi
    zle .self-insert
}
zle -N self-insert _aisug_self_insert_wrapper

_aisug_backward_delete_wrapper() {
    if (( _AISUG_ACTIVE )); then
        _aisug_kill_async
        _aisug_zle_restore_and_clear
    fi
    zle .backward-delete-char
}
zle -N backward-delete-char _aisug_backward_delete_wrapper

_aisug_kill_line_wrapper() {
    if (( _AISUG_ACTIVE )); then
        _aisug_kill_async
        _aisug_zle_restore_and_clear
    fi
    zle .kill-whole-line
}
zle -N kill-whole-line _aisug_kill_line_wrapper

_aisug_backward_kill_word_wrapper() {
    if (( _AISUG_ACTIVE )); then
        _aisug_kill_async
        _aisug_zle_restore_and_clear
    fi
    zle .backward-kill-word
}
zle -N backward-kill-word _aisug_backward_kill_word_wrapper

# ─── Keybindings ──────────────────────────────────────────────────────────────
#
# Ctrl+G  — trigger AI suggestion (works in every terminal)
# Ctrl+C  — dismiss/reject suggestion and restore original input

bindkey '^G' _aisug_trigger            # Ctrl+G — trigger AI suggestion
bindkey '^C' _aisug_dismiss            # Ctrl+C — dismiss / reject

# Accept full suggestion
bindkey '^[[C' _aisug_accept           # Right Arrow
bindkey '^[[F' _aisug_accept           # End key

# Accept next word
bindkey '^[[1;5C' _aisug_accept_word   # Ctrl+Right Arrow

# Tab: accept or complete
bindkey '\t' _aisug_tab

# ─── Lifecycle Hooks ──────────────────────────────────────────────────────────
# precmd/preexec run OUTSIDE ZLE context — never touch POSTDISPLAY here.
# Only reset our state variables; ghost text is cleaned up by the next ZLE widget call.

_aisug_precmd() {
    _AISUG_LAST_EXIT_CODE=$?
    _aisug_kill_async
    _aisug_reset_state
}

_aisug_preexec() {
    _AISUG_LAST_COMMAND="$1"
    _aisug_kill_async
    _aisug_reset_state
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _aisug_precmd
add-zsh-hook preexec _aisug_preexec

# ─── Startup ──────────────────────────────────────────────────────────────────
( _aisug_start_sidecar ) &>/dev/null &!

# ─── Cleanup on Exit ─────────────────────────────────────────────────────────
_aisug_cleanup() {
    _aisug_kill_async
    rm -rf "$_AISUG_TMPDIR" 2>/dev/null
}
add-zsh-hook zshexit _aisug_cleanup
