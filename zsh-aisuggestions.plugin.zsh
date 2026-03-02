#!/usr/bin/env zsh
# zsh-aisuggestions.plugin.zsh — LLM-powered autosuggestions for Zsh
#
# Usage:
#   Ctrl+G   → trigger AI suggestion (shown as ghost text)
#   → / Tab  → accept the suggestion
#   Ctrl+→   → accept next word
#   Ctrl+C   → dismiss and restore original input
#   any key  → dismiss, restore, continue typing

# ─── Guard ────────────────────────────────────────────────────────────────────
# On exec zsh / source reload: tear down the old sidecar so we start fresh
# with a newly-read config.  The guard only prevents double-sourcing within
# the *same* shell session (e.g. two plugins try to source us).
if [[ -n "$_AISUG_LOADED" ]]; then
    # Already loaded in this shell instance — kill old sidecar so the
    # rest of the file can restart it with a fresh config.
    if [[ -f "$_AISUG_PIDFILE" ]]; then
        local _old_pid=$(< "$_AISUG_PIDFILE")
        [[ -n "$_old_pid" ]] && kill "$_old_pid" 2>/dev/null
        rm -f "$_AISUG_PIDFILE" "$_AISUG_SOCKET" 2>/dev/null
        sleep 0.1
    fi
    # Reset failure flag so the new attempt can succeed
    _AISUG_SIDECAR_FAILED=0
    _AISUG_SIDECAR_CHECKED=0
fi
typeset -g _AISUG_LOADED=1

# ─── Configuration ────────────────────────────────────────────────────────────
typeset -g _AISUG_PLUGIN_DIR="${0:A:h}"
typeset -g _AISUG_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-${UID}.sock"
typeset -g _AISUG_PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/zsh-aisuggestions-${UID}.pid"
typeset -g _AISUG_TMPDIR="${TMPDIR:-/tmp}/zsh-aisuggestions-${UID}"
typeset -g _AISUG_GHOST_COLOR="${AISUG_GHOST_COLOR:-8}"

# ─── State ────────────────────────────────────────────────────────────────────
typeset -g _AISUG_SUGGESTION=""
typeset -g _AISUG_MODE=""
typeset -g _AISUG_ORIGINAL_BUFFER=""
typeset -g _AISUG_ORIGINAL_CURSOR=0
typeset -g _AISUG_ACTIVE=0
typeset -g _AISUG_LAST_EXIT_CODE=0
typeset -g _AISUG_LAST_COMMAND=""
typeset -g _AISUG_SIDECAR_FAILED=0
typeset -g _AISUG_SIDECAR_CHECKED=0

# ─── Cached context ──────────────────────────────────────────────────────────
typeset -g _AISUG_CTX_CWD=""
typeset -g _AISUG_CTX_GIT_BRANCH=""
typeset -g _AISUG_CTX_GIT_DIRTY="false"
typeset -g _AISUG_CTX_OS=""
typeset -g _AISUG_CTX_HISTORY="[]"

mkdir -p "$_AISUG_TMPDIR" 2>/dev/null

# ─── Sidecar Management ──────────────────────────────────────────────────────

_aisug_sidecar_running() {
    [[ -f "$_AISUG_PIDFILE" ]] || return 1
    local pid=$(< "$_AISUG_PIDFILE")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_aisug_start_sidecar() {
    (( _AISUG_SIDECAR_FAILED )) && return 1
    _aisug_sidecar_running && return 0

    # Prefer the plugin venv, then Homebrew, then generic python3/python
    local python_cmd=""
    local venv_python="${HOME}/.local/share/zsh-aisuggestions/venv/bin/python"
    if [[ -x "$venv_python" ]]; then
        python_cmd="$venv_python"
    else
        local candidates=()
        # Homebrew paths (Apple Silicon and Intel)
        candidates+=(/opt/homebrew/bin/python3 /usr/local/bin/python3)
        # Generic PATH lookup
        for cmd in python3 python; do
            local p
            p=$(command -v "$cmd" 2>/dev/null) && candidates+=("$p")
        done
        for cmd in "${candidates[@]}"; do
            [[ -x "$cmd" ]] || continue
            # Accept Python >= 3.8
            "$cmd" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null \
                && { python_cmd="$cmd"; break; }
        done
    fi
    [[ -z "$python_cmd" ]] && { _AISUG_SIDECAR_FAILED=1; return 1; }

    local log_file="${_AISUG_TMPDIR}/sidecar.log"
    ( cd "$_AISUG_PLUGIN_DIR" && "$python_cmd" -m sidecar >> "$log_file" 2>&1 & )

    local i=0
    while (( i < 30 )); do
        [[ -S "$_AISUG_SOCKET" ]] && return 0
        sleep 0.05; (( i++ ))
    done
    _AISUG_SIDECAR_FAILED=1; return 1
}

_aisug_ensure_sidecar() {
    local now=$SECONDS
    (( now - _AISUG_SIDECAR_CHECKED < 10 )) && return 0
    _AISUG_SIDECAR_CHECKED=$now
    _aisug_sidecar_running || _aisug_start_sidecar
}

# ─── Socket Communication ────────────────────────────────────────────────────

_aisug_query_socket() {
    local json_payload="$1"
    if command -v socat &>/dev/null; then
        echo -n "$json_payload" | socat -t8 - UNIX-CONNECT:"${_AISUG_SOCKET}" 2>/dev/null
    else
        python3 -S -c "
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
try:
 s.settimeout(8);s.connect('${_AISUG_SOCKET}')
 s.sendall(sys.stdin.buffer.read());s.shutdown(1)
 d=b''
 while 1:
  c=s.recv(4096)
  if not c:break
  d+=c
 sys.stdout.write(d.decode())
finally:s.close()
" <<< "$json_payload" 2>/dev/null
    fi
}

# ─── Context ──────────────────────────────────────────────────────────────────

_aisug_update_context_cache() {
    _AISUG_CTX_CWD="$(pwd)"
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        _AISUG_CTX_GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null | head -1)" ]] \
            && _AISUG_CTX_GIT_DIRTY="true" || _AISUG_CTX_GIT_DIRTY="false"
    else
        _AISUG_CTX_GIT_BRANCH=""; _AISUG_CTX_GIT_DIRTY="false"
    fi
    [[ -z "$_AISUG_CTX_OS" ]] && {
        case "$(uname -s)" in
            Darwin) _AISUG_CTX_OS="macos" ;; Linux) _AISUG_CTX_OS="linux" ;; *) _AISUG_CTX_OS="unknown" ;;
        esac
    }
    local cmds=() line
    while IFS= read -r line; do
        line="${line//\\/\\\\}"; line="${line//\"/\\\"}"
        cmds+=("\"${line}\"")
    done < <(fc -ln -10 -1 2>/dev/null | sed 's/^[[:space:]]*//')
    local result="[" first=1
    for cmd in "${cmds[@]}"; do (( first )) && first=0 || result+=","; result+="$cmd"; done
    _AISUG_CTX_HISTORY="${result}]"
}

_aisug_build_request() {
    local buffer="$1" cursor="$2"
    local eb="${buffer//\\/\\\\}"; eb="${eb//\"/\\\"}"
    local ec="${_AISUG_CTX_CWD//\\/\\\\}"; ec="${ec//\"/\\\"}"
    local el="${_AISUG_LAST_COMMAND//\\/\\\\}"; el="${el//\"/\\\"}"
    echo -n "{\"type\":\"suggest\",\"buffer\":\"${eb}\",\"cursor_position\":${cursor},\"context\":{\"cwd\":\"${ec}\",\"git_branch\":\"${_AISUG_CTX_GIT_BRANCH}\",\"git_dirty\":${_AISUG_CTX_GIT_DIRTY},\"last_exit_code\":${_AISUG_LAST_EXIT_CODE},\"last_command\":\"${el}\",\"shell\":\"zsh\",\"os\":\"${_AISUG_CTX_OS}\",\"recent_history\":${_AISUG_CTX_HISTORY}}}"
}

# ─── State Management ─────────────────────────────────────────────────────────

_aisug_reset_state() {
    _AISUG_SUGGESTION=""; _AISUG_MODE=""
    _AISUG_ORIGINAL_BUFFER=""; _AISUG_ORIGINAL_CURSOR=0; _AISUG_ACTIVE=0
}

# ─── ZLE Helpers ──────────────────────────────────────────────────────────────

_aisug_zle_clear_ghost() { POSTDISPLAY=""; region_highlight=(); }

_aisug_zle_show_ghost() {
    local suggestion="$1"
    [[ -z "$suggestion" ]] && { _aisug_zle_clear_ghost; return; }
    _AISUG_SUGGESTION="$suggestion"

    # Decide mode client-side: if the suggestion starts with the current
    # BUFFER it is a completion (show suffix as ghost text); otherwise it
    # is a rewrite (replace BUFFER entirely, show in ghost colour).
    if [[ "$suggestion" == "$BUFFER"* && "$suggestion" != "$BUFFER" ]]; then
        _AISUG_MODE="complete"
        local suffix="${suggestion#$BUFFER}"
        POSTDISPLAY="${suffix}"
        region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
    else
        _AISUG_MODE="rewrite"
        BUFFER="$suggestion"
        CURSOR=${#BUFFER}
        POSTDISPLAY=""
        region_highlight=("0 ${#BUFFER} fg=${_AISUG_GHOST_COLOR}")
    fi
}

_aisug_zle_restore_and_clear() {
    if (( _AISUG_ACTIVE )); then
        BUFFER="$_AISUG_ORIGINAL_BUFFER"
        CURSOR="$_AISUG_ORIGINAL_CURSOR"
    fi
    _aisug_zle_clear_ghost
    _aisug_reset_state
    zle -R
}

# ─── Core: Synchronous Query with Loading Indicator ──────────────────────────
# The query blocks for 1-3s (LLM API time). We show "thinking..." first
# via zle -R, then do the query, then show the result. All in ZLE context.
# This is simple, reliable, and avoids all async signal/fd complexity.

_aisug_do_query() {
    local buffer="$1" cursor="$2"

    # Show loading indicator and flush display
    POSTDISPLAY="  ... thinking"
    region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
    zle -R

    # Build request and query sidecar (this blocks for LLM response time)
    local request=$(_aisug_build_request "$buffer" "$cursor")
    local response=$(_aisug_query_socket "$request")

    # Parse response
    local suggestion="" mode="complete" tmp
    if [[ -n "$response" && "$response" == *'"suggestion"'* ]]; then
        tmp="${response#*\"suggestion\"}"
        tmp="${tmp#*\"}"
        suggestion="${tmp%%\"*}"
        suggestion="${suggestion//\\\\/\\}"
        suggestion="${suggestion//\\\"/\"}"
    fi
    if [[ -n "$response" && "$response" == *'"mode"'* ]]; then
        tmp="${response#*\"mode\"}"
        tmp="${tmp#*\"}"
        mode="${tmp%%\"*}"
    fi

    # Show result (still in ZLE context — POSTDISPLAY is writable)
    if [[ -n "$suggestion" ]]; then
        _aisug_zle_show_ghost "$suggestion"
    else
        _aisug_zle_clear_ghost
        _AISUG_ACTIVE=0
    fi
    zle -R
}

# ─── ZLE Widgets ──────────────────────────────────────────────────────────────

_aisug_trigger() {
    local buffer="$BUFFER" cursor="$CURSOR"
    [[ -z "$buffer" ]] && { zle -M "zsh-aisuggestions: type something first"; return; }

    _aisug_ensure_sidecar
    (( _AISUG_SIDECAR_FAILED )) && { zle -M "zsh-aisuggestions: sidecar not available"; return; }

    _AISUG_ACTIVE=1
    _AISUG_ORIGINAL_BUFFER="$BUFFER"
    _AISUG_ORIGINAL_CURSOR="$CURSOR"

    _aisug_do_query "$buffer" "$cursor"
}
zle -N _aisug_trigger

_aisug_accept() {
    if [[ -n "$_AISUG_SUGGESTION" ]] && (( _AISUG_ACTIVE )); then
        BUFFER="$_AISUG_SUGGESTION"; CURSOR=${#BUFFER}
        _aisug_zle_clear_ghost; _aisug_reset_state
    else
        zle forward-char
    fi
}
zle -N _aisug_accept

_aisug_accept_word() {
    if [[ -n "$_AISUG_SUGGESTION" ]] && (( _AISUG_ACTIVE )); then
        local suggestion="$_AISUG_SUGGESTION"
        if [[ "$suggestion" == "$BUFFER"* ]]; then
            local remaining="${suggestion#$BUFFER}" next_chunk
            if [[ "$remaining" == " "* ]]; then
                next_chunk=" ${${remaining# }%% *}"
            else
                next_chunk="${remaining%% *}"
            fi
            [[ "${BUFFER}${next_chunk}" == "$suggestion" ]] && next_chunk="$remaining"
            BUFFER="${BUFFER}${next_chunk}"
        else
            BUFFER="${suggestion%% *}"; _AISUG_MODE="complete"
        fi
        CURSOR=${#BUFFER}
        [[ "$BUFFER" == "$suggestion" ]] \
            && { _aisug_zle_clear_ghost; _aisug_reset_state; } \
            || { _aisug_zle_show_ghost "$suggestion"; zle -R; }
    else
        zle forward-word
    fi
}
zle -N _aisug_accept_word

_aisug_dismiss() {
    if (( _AISUG_ACTIVE )); then
        _aisug_zle_restore_and_clear; zle -R
    else
        zle send-break
    fi
}
zle -N _aisug_dismiss

_aisug_tab() {
    if [[ -n "$_AISUG_SUGGESTION" ]] && (( _AISUG_ACTIVE )); then
        _aisug_accept
    else
        zle expand-or-complete
    fi
}
zle -N _aisug_tab

# ─── Auto-Dismiss on Typing ──────────────────────────────────────────────────

_aisug_self_insert_wrapper() {
    (( _AISUG_ACTIVE )) && _aisug_zle_restore_and_clear
    zle .self-insert
}
zle -N self-insert _aisug_self_insert_wrapper

_aisug_backward_delete_wrapper() {
    (( _AISUG_ACTIVE )) && _aisug_zle_restore_and_clear
    zle .backward-delete-char
}
zle -N backward-delete-char _aisug_backward_delete_wrapper

_aisug_kill_line_wrapper() {
    (( _AISUG_ACTIVE )) && _aisug_zle_restore_and_clear
    zle .kill-whole-line
}
zle -N kill-whole-line _aisug_kill_line_wrapper

_aisug_backward_kill_word_wrapper() {
    (( _AISUG_ACTIVE )) && _aisug_zle_restore_and_clear
    zle .backward-kill-word
}
zle -N backward-kill-word _aisug_backward_kill_word_wrapper

# ─── Keybindings ──────────────────────────────────────────────────────────────

bindkey '^G' _aisug_trigger
bindkey '^C' _aisug_dismiss
bindkey '^[[C' _aisug_accept          # Right Arrow
bindkey '^[[F' _aisug_accept          # End
bindkey '^[[1;5C' _aisug_accept_word  # Ctrl+Right
bindkey '\t' _aisug_tab

# ─── Lifecycle Hooks ──────────────────────────────────────────────────────────

_aisug_precmd() {
    _AISUG_LAST_EXIT_CODE=$?
    _aisug_reset_state
    _aisug_update_context_cache
}

_aisug_preexec() {
    _AISUG_LAST_COMMAND="$1"
    _aisug_reset_state
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _aisug_precmd
add-zsh-hook preexec _aisug_preexec

# ─── Startup ──────────────────────────────────────────────────────────────────
# Kill any previous sidecar (by PID file, then by process scan) so we always
# start fresh with the latest config.yaml.
if [[ -f "$_AISUG_PIDFILE" ]]; then
    local _old_pid=$(< "$_AISUG_PIDFILE")
    if [[ -n "$_old_pid" ]] && kill -0 "$_old_pid" 2>/dev/null; then
        kill "$_old_pid" 2>/dev/null
    fi
    rm -f "$_AISUG_PIDFILE" "$_AISUG_SOCKET" 2>/dev/null
fi
# Also kill any orphaned sidecar processes (e.g. stale PID file was deleted
# but the process survived a previous exec zsh).
local _orphan_pids
_orphan_pids=($(command pgrep -f "python.*-m sidecar" 2>/dev/null))
for _p in "${_orphan_pids[@]}"; do
    kill "$_p" 2>/dev/null
done
unset _orphan_pids _p
rm -f "$_AISUG_SOCKET" 2>/dev/null
sleep 0.15
_AISUG_SIDECAR_FAILED=0
_AISUG_SIDECAR_CHECKED=0
( _aisug_start_sidecar ) &>/dev/null &!
_aisug_update_context_cache

# ─── Cleanup ──────────────────────────────────────────────────────────────────
_aisug_cleanup() { rm -rf "$_AISUG_TMPDIR" 2>/dev/null; }
add-zsh-hook zshexit _aisug_cleanup
