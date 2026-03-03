#!/usr/bin/env zsh
# zsh-aisuggestions.plugin.zsh — LLM-powered autosuggestions for Zsh
#
# Usage:
#   Ctrl+G       → trigger AI rewrite (full command replacement in ghost color)
#   Ctrl+]       → trigger AI autocomplete (inline ghost text at cursor)
#   Tab / →      → accept the suggestion
#   Backspace    → dismiss and restore original input

# ─── Guard ────────────────────────────────────────────────────────────────────
# On exec zsh / source reload: tear down the old sidecar so we start fresh
# with a newly-read config.  The guard only prevents double-sourcing within
# the *same* shell session (e.g. two plugins try to source us).
if [[ -n "$_AISUG_LOADED" ]]; then
    if [[ -f "$_AISUG_PIDFILE" ]]; then
        local _old_pid=$(< "$_AISUG_PIDFILE")
        [[ -n "$_old_pid" ]] && kill "$_old_pid" 2>/dev/null
        rm -f "$_AISUG_PIDFILE" "$_AISUG_SOCKET" 2>/dev/null
        sleep 0.1
    fi
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
typeset -g _AISUG_SUGGESTION=""        # Full suggested command
typeset -g _AISUG_MODE=""              # "rewrite" or "complete"
typeset -g _AISUG_TRIGGER_MODE=""      # Which hotkey triggered: "rewrite" or "complete"
typeset -g _AISUG_ORIGINAL_BUFFER=""   # Buffer before suggestion was shown
typeset -g _AISUG_ORIGINAL_CURSOR=0    # Cursor before suggestion was shown
typeset -g _AISUG_ACTIVE=0            # 1 when a suggestion is being displayed
typeset -g _AISUG_GHOST_START=0       # Start position of ghost text in BUFFER (complete mode)
typeset -g _AISUG_GHOST_LEN=0         # Length of ghost text inserted in BUFFER (complete mode)
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

    local python_cmd=""
    local venv_python="${HOME}/.local/share/zsh-aisuggestions/venv/bin/python"
    if [[ -x "$venv_python" ]]; then
        python_cmd="$venv_python"
    else
        local candidates=()
        candidates+=(/opt/homebrew/bin/python3 /usr/local/bin/python3)
        for cmd in python3 python; do
            local p
            p=$(command -v "$cmd" 2>/dev/null) && candidates+=("$p")
        done
        for cmd in "${candidates[@]}"; do
            [[ -x "$cmd" ]] || continue
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
    local buffer="$1" cursor="$2" trigger_mode="$3"
    local eb="${buffer//\\/\\\\}"; eb="${eb//\"/\\\"}"
    local ec="${_AISUG_CTX_CWD//\\/\\\\}"; ec="${ec//\"/\\\"}"
    local el="${_AISUG_LAST_COMMAND//\\/\\\\}"; el="${el//\"/\\\"}"
    echo -n "{\"type\":\"suggest\",\"trigger_mode\":\"${trigger_mode}\",\"buffer\":\"${eb}\",\"cursor_position\":${cursor},\"context\":{\"cwd\":\"${ec}\",\"git_branch\":\"${_AISUG_CTX_GIT_BRANCH}\",\"git_dirty\":${_AISUG_CTX_GIT_DIRTY},\"last_exit_code\":${_AISUG_LAST_EXIT_CODE},\"last_command\":\"${el}\",\"shell\":\"zsh\",\"os\":\"${_AISUG_CTX_OS}\",\"recent_history\":${_AISUG_CTX_HISTORY}}}"
}

# ─── State Management ─────────────────────────────────────────────────────────

_aisug_reset_state() {
    _AISUG_SUGGESTION=""; _AISUG_MODE=""; _AISUG_TRIGGER_MODE=""
    _AISUG_ORIGINAL_BUFFER=""; _AISUG_ORIGINAL_CURSOR=0
    _AISUG_ACTIVE=0; _AISUG_GHOST_START=0; _AISUG_GHOST_LEN=0
}

# ─── ZLE Helpers ──────────────────────────────────────────────────────────────

_aisug_zle_clear_ghost() { POSTDISPLAY=""; region_highlight=(); }

# Show the suggestion as ghost text.
# In rewrite mode: replace BUFFER entirely, highlight all in ghost color.
# In complete mode: insert ghost text at cursor position inside BUFFER,
#   highlight only the inserted portion so surrounding text looks normal.
_aisug_zle_show_ghost() {
    local suggestion="$1" trigger_mode="$2"
    [[ -z "$suggestion" ]] && { _aisug_zle_clear_ghost; return; }
    _AISUG_SUGGESTION="$suggestion"

    if [[ "$trigger_mode" == "complete" ]]; then
        # ── Complete mode: insert ghost text at cursor ────────────────────
        # Compute what the LLM inserted by matching prefix (before cursor)
        # and suffix (after cursor) against the suggestion.
        local prefix="${_AISUG_ORIGINAL_BUFFER:0:$_AISUG_ORIGINAL_CURSOR}"
        local suffix="${_AISUG_ORIGINAL_BUFFER:$_AISUG_ORIGINAL_CURSOR}"

        # Find the insertion: suggestion = prefix + insertion + suffix
        # First verify suggestion starts with prefix
        local insertion=""
        if [[ "$suggestion" == "${prefix}"* ]]; then
            local after_prefix="${suggestion#$prefix}"
            if [[ -n "$suffix" && "$after_prefix" == *"${suffix}" ]]; then
                insertion="${after_prefix%$suffix}"
            else
                # Suffix not found — the LLM changed the tail too.
                # Treat everything after prefix as the insertion,
                # but only show the part that differs from suffix.
                insertion="$after_prefix"
                suffix=""
            fi
        fi

        if [[ -n "$insertion" ]]; then
            _AISUG_MODE="complete"
            _AISUG_GHOST_START=${#prefix}
            _AISUG_GHOST_LEN=${#insertion}
            # Insert ghost text into BUFFER at cursor
            BUFFER="${prefix}${insertion}${suffix}"
            CURSOR=$(( ${#prefix} + ${#insertion} ))
            POSTDISPLAY=""
            # Highlight only the inserted portion
            local ghost_end=$(( _AISUG_GHOST_START + _AISUG_GHOST_LEN ))
            region_highlight=("${_AISUG_GHOST_START} ${ghost_end} fg=${_AISUG_GHOST_COLOR}")
        else
            # No insertion computed — nothing to show
            _aisug_zle_clear_ghost
            _AISUG_ACTIVE=0
            return
        fi
    else
        # ── Rewrite mode ──────────────────────────────────────────────────
        if [[ "$suggestion" == "$BUFFER"* && "$suggestion" != "$BUFFER" ]]; then
            # Suggestion extends the buffer — show suffix as ghost POSTDISPLAY
            _AISUG_MODE="rewrite"
            _AISUG_GHOST_START=0; _AISUG_GHOST_LEN=0
            local suf="${suggestion#$BUFFER}"
            POSTDISPLAY="${suf}"
            region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
        else
            # Full replacement — show entire line in ghost color
            _AISUG_MODE="rewrite"
            _AISUG_GHOST_START=0; _AISUG_GHOST_LEN=0
            BUFFER="$suggestion"
            CURSOR=${#BUFFER}
            POSTDISPLAY=""
            region_highlight=("0 ${#BUFFER} fg=${_AISUG_GHOST_COLOR}")
        fi
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

_aisug_do_query() {
    local buffer="$1" cursor="$2" trigger_mode="$3"

    # Show loading indicator and flush display
    POSTDISPLAY="  ... thinking"
    region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
    zle -R

    # Build request and query sidecar (this blocks for LLM response time)
    local request=$(_aisug_build_request "$buffer" "$cursor" "$trigger_mode")
    local response=$(_aisug_query_socket "$request")

    # Parse response — extract "suggestion" value (handles escaped quotes)
    local suggestion="" tmp
    if [[ -n "$response" && "$response" == *'"suggestion"'* ]]; then
        tmp="${response#*\"suggestion\"}"
        tmp="${tmp#*\"}"
        # Walk the string char-by-char to find the real closing "
        # (the naive %%\"* approach breaks on escaped \" inside the value)
        local _i=0 _ch
        suggestion=""
        while (( _i < ${#tmp} )); do
            _ch="${tmp:_i:1}"
            if [[ "$_ch" == '\' ]]; then
                # Escaped character — peek at next char and unescape
                (( _i++ ))
                case "${tmp:_i:1}" in
                    '"')  suggestion+='"' ;;
                    '\') suggestion+='\' ;;
                    'n')  suggestion+=$'\n' ;;
                    't')  suggestion+=$'\t' ;;
                    '/')  suggestion+='/' ;;
                    *)    suggestion+="\\${tmp:_i:1}" ;;
                esac
            elif [[ "$_ch" == '"' ]]; then
                break
            else
                suggestion+="$_ch"
            fi
            (( _i++ ))
        done
        # In complete mode, force single-line (multi-line only for rewrite)
        if [[ "$trigger_mode" == "complete" ]]; then
            suggestion="${suggestion%%$'\n'*}"
        fi
    fi

    # Show result (still in ZLE context)
    if [[ -n "$suggestion" ]]; then
        _aisug_zle_show_ghost "$suggestion" "$trigger_mode"
    else
        _aisug_zle_clear_ghost
        _AISUG_ACTIVE=0
    fi
    zle -R
}

# ─── ZLE Widgets ──────────────────────────────────────────────────────────────

# Ctrl+G — Rewrite mode: full command replacement
_aisug_trigger_rewrite() {
    local buffer="$BUFFER" cursor="$CURSOR"
    [[ -z "$buffer" ]] && { zle -M "zsh-aisuggestions: type something first"; return; }

    _aisug_ensure_sidecar
    (( _AISUG_SIDECAR_FAILED )) && { zle -M "zsh-aisuggestions: sidecar not available"; return; }

    _AISUG_ACTIVE=1
    _AISUG_TRIGGER_MODE="rewrite"
    _AISUG_ORIGINAL_BUFFER="$BUFFER"
    _AISUG_ORIGINAL_CURSOR="$CURSOR"

    _aisug_do_query "$buffer" "$cursor" "rewrite"
}
zle -N _aisug_trigger_rewrite

# Ctrl+] — Complete mode: inline completion at cursor
_aisug_trigger_complete() {
    local buffer="$BUFFER" cursor="$CURSOR"
    [[ -z "$buffer" ]] && { zle -M "zsh-aisuggestions: type something first"; return; }

    _aisug_ensure_sidecar
    (( _AISUG_SIDECAR_FAILED )) && { zle -M "zsh-aisuggestions: sidecar not available"; return; }

    _AISUG_ACTIVE=1
    _AISUG_TRIGGER_MODE="complete"
    _AISUG_ORIGINAL_BUFFER="$BUFFER"
    _AISUG_ORIGINAL_CURSOR="$CURSOR"

    _aisug_do_query "$buffer" "$cursor" "complete"
}
zle -N _aisug_trigger_complete

_aisug_accept() {
    if [[ -n "$_AISUG_SUGGESTION" ]] && (( _AISUG_ACTIVE )); then
        # In both modes the buffer already contains the suggestion text
        # (rewrite: full replacement; complete: insertion at cursor).
        # Just clear ghost highlighting and accept.
        BUFFER="$_AISUG_SUGGESTION"
        CURSOR=${#BUFFER}
        _aisug_zle_clear_ghost; _aisug_reset_state
    else
        zle forward-char
    fi
}
zle -N _aisug_accept

_aisug_dismiss() {
    if (( _AISUG_ACTIVE )); then
        _aisug_zle_restore_and_clear
    else
        zle .backward-delete-char
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

# ─── Redraw Hook ──────────────────────────────────────────────────────────────
# zle clears region_highlight on every redraw cycle. We must re-apply it
# while a ghost suggestion is being displayed; otherwise the highlight
# "flashes" and disappears immediately after the triggering widget returns.

_aisug_line_pre_redraw() {
    (( _AISUG_ACTIVE )) || return

    if [[ "$_AISUG_MODE" == "complete" && _AISUG_GHOST_LEN -gt 0 ]]; then
        local ghost_end=$(( _AISUG_GHOST_START + _AISUG_GHOST_LEN ))
        region_highlight=("${_AISUG_GHOST_START} ${ghost_end} fg=${_AISUG_GHOST_COLOR}")
    elif [[ "$_AISUG_MODE" == "rewrite" ]]; then
        if [[ -n "$POSTDISPLAY" ]]; then
            # Extension mode — ghost is in POSTDISPLAY
            region_highlight=("$(( ${#BUFFER} )) $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=${_AISUG_GHOST_COLOR}")
        else
            # Full replacement — entire BUFFER is ghost
            region_highlight=("0 ${#BUFFER} fg=${_AISUG_GHOST_COLOR}")
        fi
    fi
}
zle -N zle-line-pre-redraw _aisug_line_pre_redraw

# ─── Keybindings ──────────────────────────────────────────────────────────────

bindkey '^G' _aisug_trigger_rewrite        # Ctrl+G — rewrite/translate
bindkey '^]' _aisug_trigger_complete       # Ctrl+] — inline autocomplete
bindkey '^[[C' _aisug_accept               # Right Arrow
bindkey '\t' _aisug_tab                    # Tab
bindkey '^?' _aisug_dismiss                # Backspace — dismiss or normal delete

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
if [[ -f "$_AISUG_PIDFILE" ]]; then
    local _old_pid=$(< "$_AISUG_PIDFILE")
    if [[ -n "$_old_pid" ]] && kill -0 "$_old_pid" 2>/dev/null; then
        kill "$_old_pid" 2>/dev/null
    fi
    rm -f "$_AISUG_PIDFILE" "$_AISUG_SOCKET" 2>/dev/null
fi
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
