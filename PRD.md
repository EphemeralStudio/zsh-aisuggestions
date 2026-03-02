# PRD: zsh-aisuggestions — LLM-Powered Zsh Autosuggestion Plugin

## 1. Overview

**zsh-aisuggestions** is a Zsh plugin that provides intelligent, context-aware command autosuggestions powered by any OpenAI-compatible LLM API. It is a spiritual successor to `zsh-autosuggestions`, replacing naive history prefix matching with real AI understanding of intent, project context, and terminal state.

The user brings their own API key. There is no subscription, no account, no telemetry.

### 1.1 Design Principles

- **Composable**: A single Zsh plugin + a lightweight Python sidecar. No custom terminal required.
- **Fast**: Hybrid approach — instant local suggestions first, async AI suggestions overlay when ready.
- **Portable**: Works on macOS and Linux, in any terminal emulator, with or without oh-my-zsh.
- **Minimal**: Complexity is opt-in via configuration.
- **Private**: All API calls go directly to the provider. No intermediary servers. No data collection.
- **OpenAI-compatible first**: Any provider that speaks the OpenAI chat completions API works out of the box (OpenAI, Anthropic via proxy, Ollama, LM Studio, vLLM, Together AI, Groq, DeepSeek, etc.).

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────┐
│ User's Terminal (WezTerm / Kitty / iTerm / any)     │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ Zsh Shell                                     │  │
│  │                                               │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │ zsh-aisuggestions.plugin.zsh            │  │  │
│  │  │                                         │  │  │
│  │  │ • Registers Zsh Line Editor (ZLE)       │  │  │
│  │  │   widgets                               │  │  │
│  │  │ • Captures $BUFFER (current input)      │  │  │
│  │  │ • Renders ghost text via $POSTDISPLAY   │  │  │
│  │  │ • Handles accept/reject keybindings     │  │  │
│  │  │ • Hooks precmd/preexec for context      │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │                 │ async (background subshell)  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │ sidecar (Python daemon)                 │  │  │
│  │  │                                         │  │  │
│  │  │ • Listens on Unix domain socket         │  │  │
│  │  │ • Receives: buffer, context, config     │  │  │
│  │  │ • Calls any OpenAI-compatible API       │  │  │
│  │  │ • Returns: suggested completion string  │  │  │
│  │  │ • Manages debounce, cache, rate limits  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │                                               │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 2.1 Component Responsibilities

| Component | Language | Responsibility |
|---|---|---|
| `zsh-aisuggestions.plugin.zsh` | Zsh | ZLE widget registration, input capture, ghost text rendering, keybindings, lifecycle hooks |
| `sidecar/` | Python 3.10+ | LLM API communication, context assembly, caching, debounce logic, socket server |
| `config.yaml` | YAML | User configuration — API endpoint, model selection, behavior tuning |

### 2.2 Communication Protocol

The Zsh plugin communicates with the Python sidecar via a **Unix domain socket** at `$XDG_RUNTIME_DIR/zsh-aisuggestions.sock` (fallback: `/tmp/zsh-aisuggestions-$UID.sock`).

**Request** (JSON, sent from Zsh to sidecar):

```json
{
  "type": "suggest",
  "buffer": "docker run --",
  "cursor_position": 14,
  "context": {
    "cwd": "/home/user/myproject",
    "git_branch": "main",
    "git_dirty": true,
    "last_exit_code": 1,
    "last_command": "docker build -t myapp .",
    "last_output_tail": "ERROR: failed to solve ...",
    "shell": "zsh",
    "os": "linux",
    "project_type": "node",
    "env_hints": ["Dockerfile", "package.json", ".nvmrc"]
  }
}
```

**Response** (JSON, sent from sidecar to Zsh):

```json
{
  "suggestion": "docker run --rm -it -p 3000:3000 myapp",
  "mode": "complete",
  "source": "llm",
  "cached": false
}
```

The `mode` field indicates the LLM's intent:
- `"complete"` — the suggestion extends/completes the user's input (suggestion starts with buffer)
- `"rewrite"` — the suggestion replaces the user's input entirely (typo fix, different command, etc.)

### 2.3 Trigger & Accept/Reject Flow

```
User types "dockr bilud" → presses Alt+Up
    │
    ├─ Plugin saves original buffer: "dockr bilud"
    │
    └─ ASYNC: send to sidecar → sidecar calls LLM
        → LLM returns "docker build -t myapp ." (mode: rewrite)
        → Ghost text: "dockr bilud  [AI: docker build -t myapp .]"
            │
            ├─ User presses → or Tab:
            │   → BUFFER = "docker build -t myapp ."  (ACCEPTED)
            │
            ├─ User presses Ctrl+→:
            │   → BUFFER = "docker"  (first word accepted)
            │   → Ghost updates with remaining words
            │
            ├─ User presses Esc:
            │   → BUFFER = "dockr bilud"  (RESTORED to original)
            │
            └─ User types any character:
                → BUFFER = "dockr bilud"  (RESTORED)
                → Character is appended: "dockr biludx"
```

---

## 3. File Structure

```
zsh-aisuggestions/
├── zsh-aisuggestions.plugin.zsh   # Main Zsh plugin (ZLE widgets + hooks)
├── sidecar/
│   ├── __init__.py
│   ├── server.py                   # Unix socket server, request handling
│   ├── llm.py                      # OpenAI-compatible LLM provider
│   ├── context.py                  # Context assembly (git, project, scrollback)
│   ├── cache.py                    # LRU suggestion cache
│   └── config.py                   # Config loading and validation
├── config.example.yaml             # Example configuration
├── install.sh                      # One-line installer
├── uninstall.sh                    # Clean removal
├── PRD.md
├── README.md
└── tests/
    ├── test_llm.py
    ├── test_context.py
    ├── test_cache.py
    └── test_server.py
```

---

## 4. Detailed Component Specs

### 4.1 `zsh-aisuggestions.plugin.zsh`

#### 4.1.1 Trigger Strategy

**Explicit trigger only.** AI suggestions are NOT auto-triggered on every keystroke. The user presses **Alt+Up** to explicitly ask for an AI suggestion. This avoids:

- Unnecessary API calls and cost on every character typed
- Latency-related UX jank from constant async updates
- Interference with normal shell editing and tab completion

The AI suggestion appears as **ghost text** (dim `$POSTDISPLAY`). The suggestion can either:

1. **Complete** the current input (ghost text shows the suffix after the cursor)
2. **Rewrite** the entire input (ghost text shows `← new command` after the buffer)

Accepting the suggestion **replaces `$BUFFER` entirely** with the suggested command, regardless of whether it's a completion or a rewrite. This is a key difference from `zsh-autosuggestions` which only appends.

#### 4.1.2 Widget Registration

Register the following ZLE widgets:

- `_aisug_trigger` — triggered by **Alt+Up**. Sends `$BUFFER` + context to sidecar, renders response as ghost text in `$POSTDISPLAY`. Shows `⟳ thinking...` while waiting.
- `_aisug_accept` — accepts the suggestion by **replacing** `$BUFFER` with the AI-suggested command. Bound to `→` (right arrow), End, and `Tab`.
- `_aisug_accept_word` — accepts only the next word from the suggestion. Bound to `Ctrl+→`.
- `_aisug_dismiss` — clears ghost text and cancels any in-flight request. Bound to `Esc`.
- Auto-clear wrappers on `self-insert` and `backward-delete-char` — any normal typing clears active ghost text without triggering AI.

#### 4.1.3 Lifecycle Hooks

- **precmd**: After each command completes, capture `$?` (last exit code), clear ghost state.
- **preexec**: Record the command about to execute (for context in the next cycle), kill async.

#### 4.1.4 Async Execution

Use a background subshell (`&!`) with a temp file and `SIGUSR1` to avoid blocking the prompt while waiting for the sidecar response.

```zsh
# Pseudocode
_aisug_trigger() {                     # Bound to Alt+Up
    _aisug_ensure_sidecar
    POSTDISPLAY="  ⟳ thinking..."       # Loading indicator
    _aisug_async_query "$BUFFER" "$CURSOR"
}

TRAPUSR1() {                           # Fired when async result is ready
    suggestion=$(< "$result_file")
    if [[ "$BUFFER" == "$_AISUG_LAST_BUFFER" ]]; then
        _aisug_show_ghost "$suggestion" "$BUFFER"
        zle -R
    fi
}

_aisug_accept() {                      # Bound to Right Arrow / Tab
    BUFFER="$_AISUG_SUGGESTION"         # Full BUFFER replacement!
    CURSOR=${#BUFFER}
    _aisug_clear_ghost
}
```

#### 4.1.5 Ghost Text Rendering

- Use `$POSTDISPLAY` for ghost text (dimmed, appears after cursor).
- Ghost text color: configurable, default is `fg=8` (gray) via `region_highlight`.
- Clear `$POSTDISPLAY` whenever `$BUFFER` changes (user keeps typing).
- Two display modes:
  - **Completion mode**: suggestion starts with buffer → ghost shows only the suffix
  - **Rewrite mode**: suggestion differs from buffer → ghost shows `← full_suggestion`

#### 4.1.6 Keybindings (Defaults)

| Key | Sequences | Action |
|---|---|---|
| **Alt+Up** | `\e[1;3A`, `\e\e[A`, `\e\eOA` | Trigger AI suggestion |
| `→` (Right Arrow) | `^[[C` | Accept full suggestion |
| `End` | `^[[F` | Accept full suggestion |
| `Tab` | `\t` | Accept suggestion (or tab-complete if none) |
| `Ctrl+→` | `^[[1;5C` | Accept next word |
| `Esc` | `\e` | Dismiss suggestion |

Alt+Up binds three escape sequences to cover all terminal variants:
- `\e[1;3A` — xterm/modern terminals (CSI with Alt modifier parameter)
- `\e\e[A` — macOS Terminal.app default (Alt as Esc prefix + CSI Up)
- `\e\eOA` — Terminals in SS3/application mode (Esc prefix + SS3 Up)

---

### 4.2 `sidecar/server.py`

#### 4.2.1 Socket Server

- Listen on Unix domain socket.
- Accept JSON-encoded requests, respond with JSON.
- Single-threaded async (use `asyncio`) — one request at a time, cancel previous in-flight request if new one arrives.
- Auto-start: the Zsh plugin starts the sidecar on first invocation if not already running.
- Pidfile at `$XDG_RUNTIME_DIR/zsh-aisuggestions.pid` (fallback: `/tmp/zsh-aisuggestions-$UID.pid`).
- Graceful shutdown on `SIGTERM` / `SIGINT`.

#### 4.2.2 Request Types

| Type | Description |
|---|---|
| `suggest` | Autocomplete the current buffer. Returns a completion string. |
| `health` | Health check. Returns `{"status": "ok", "model": "...", "provider": "..."}`. |
| `shutdown` | Gracefully stop the sidecar. |

#### 4.2.3 Debounce Logic

- Server-side debounce: if a new `suggest` request arrives while a previous one is in-flight, cancel the previous API call and process the new one.
- Default debounce window: 300ms (configurable).
- The Zsh plugin also debounces on its side to avoid unnecessary socket writes.

---

### 4.3 `sidecar/llm.py`

#### 4.3.1 OpenAI-Compatible Provider

A single provider class that works with **any** OpenAI-compatible API:

```python
class OpenAICompatibleProvider:
    """
    Works with: OpenAI, Anthropic (via OpenAI-compat endpoint),
    Ollama, LM Studio, vLLM, Together AI, Groq, DeepSeek, etc.
    """
    def __init__(self, base_url: str, api_key: str, model: str):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model

    async def complete(self, messages: list[dict]) -> str:
        # POST to {base_url}/chat/completions
        # Standard OpenAI chat completions API format
        ...
```

**No SDK dependencies.** Uses only `aiohttp` (or stdlib `urllib` as fallback) to make HTTP requests. This eliminates the need for `openai`, `anthropic`, or any provider-specific packages.

#### 4.3.2 System Prompt for Suggestions

```
You are a terminal command suggestion engine. The user has typed a partial or complete
command in their terminal and is asking for your best suggestion. You may:

1. COMPLETE the command — extend what they've typed so far.
2. REWRITE the command — replace their input entirely with a better command,
   if context (last error, project state, git state) suggests they need something different.
3. FIX the command — correct typos, wrong flags, or syntax errors in what they typed.

Rules:
- Return ONLY the full suggested command. No explanation, no commentary, no markdown.
- Return exactly one line. No newlines.
- Use context (cwd, project type, last error, exit code, git state) to infer intent.
- If the last command failed (non-zero exit code), consider suggesting a fix or retry.
- Prefer safe commands. Never suggest destructive commands (rm -rf /, DROP DATABASE, etc.)
  unless the user's input clearly signals that intent.
- If the input is ambiguous, prefer the most common usage.
- The suggested command should be immediately executable — no placeholders like <file>.
```

The sidecar determines the `mode` by comparing the suggestion to the original buffer:
- If `suggestion.startswith(buffer)` → `mode = "complete"`
- Otherwise → `mode = "rewrite"`

#### 4.3.3 Context Window Construction

Assemble the prompt sent to the LLM:

```
OS: {os} | Shell: {shell} | CWD: {cwd}
Project: {project_type} (detected from: {env_hints})
Git: branch={git_branch}, dirty={git_dirty}
Last command: {last_command} (exit code: {last_exit_code})
Last output (tail):
{last_output_tail}

Recent commands:
{last 10 commands from history}

Current input: {buffer}
Cursor position: {cursor_position}
```

---

### 4.4 `sidecar/context.py`

#### 4.4.1 Context Gathering Functions

| Function | What it collects | How |
|---|---|---|
| `get_cwd()` | Current working directory | Passed from Zsh via request |
| `get_git_info()` | Branch name, dirty status | `git rev-parse --abbrev-ref HEAD`, `git status --porcelain` |
| `get_project_type()` | Node/Python/Rust/Go/etc. | Check for `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc. in cwd |
| `get_env_hints()` | Relevant config files present | Scan cwd for known config files (`.env`, `Dockerfile`, `Makefile`, etc.) |
| `get_recent_history()` | Last N commands | Read `~/.zsh_history` or receive from Zsh plugin |

#### 4.4.2 Project Type Detection

```python
PROJECT_MARKERS = {
    "package.json": "node",
    "pyproject.toml": "python",
    "setup.py": "python",
    "Cargo.toml": "rust",
    "go.mod": "go",
    "Gemfile": "ruby",
    "Podfile": "ios",
    "CMakeLists.txt": "cmake",
    "docker-compose.yml": "docker",
    "Makefile": "make",
}
```

---

### 4.5 `sidecar/cache.py`

#### 4.5.1 Cache Strategy

- **Key**: hash of `(buffer, cwd, last_exit_code, git_branch)`.
- **Eviction**: LRU, max 200 entries (configurable).
- **TTL**: 5 minutes (configurable). Suggestions go stale as context changes.
- **Scope**: per-session (in-memory only, no disk persistence).

---

### 4.6 `config.yaml`

```yaml
# ~/.config/zsh-aisuggestions/config.yaml

# LLM API (OpenAI-compatible endpoint)
api_base_url: https://api.openai.com/v1     # Any OpenAI-compatible endpoint
api_key_env: OPENAI_API_KEY                  # Env var name containing the API key
model: gpt-4o-mini                           # Model identifier

# Common provider examples:
# OpenAI:      api_base_url: https://api.openai.com/v1,       model: gpt-4o-mini
# DeepSeek:    api_base_url: https://api.deepseek.com/v1,     model: deepseek-chat
# Ollama:      api_base_url: http://localhost:11434/v1,        model: codellama
# LM Studio:   api_base_url: http://localhost:1234/v1,         model: local-model
# Groq:        api_base_url: https://api.groq.com/openai/v1,  model: llama-3.1-8b-instant
# Together AI: api_base_url: https://api.together.xyz/v1,      model: meta-llama/...

# Behavior
debounce_ms: 300             # milliseconds to wait before triggering AI
max_context_lines: 50        # max lines of scrollback to include
max_history_commands: 10     # recent history commands to include
cache_size: 200              # max cached suggestions
cache_ttl_seconds: 300       # cache entry TTL

# Keybindings (Zsh key notation)
key_accept: "^[[C"           # Right arrow
key_accept_word: "^[[1;5C"   # Ctrl+Right arrow
key_force_suggest: "^G"      # Ctrl+G

# Display
ghost_text_color: 8          # ANSI color code for ghost text (8 = gray)

# Safety
block_destructive: true      # Ask LLM to avoid destructive commands
max_tokens: 150              # Max response tokens for suggestions

# Fallback
local_history_fallback: true # Show history match while waiting for AI
```

---

## 5. Installation

### 5.1 `install.sh`

The installer should:

1. Check Python >= 3.10 is available.
2. Create a virtual environment at `~/.local/share/zsh-aisuggestions/venv`.
3. Install Python dependencies: `aiohttp`, `pyyaml` (minimal set — no provider SDKs needed).
4. Copy plugin files to `~/.local/share/zsh-aisuggestions/`.
5. Create default config at `~/.config/zsh-aisuggestions/config.yaml` if not exists.
6. Print instructions to add `source ~/.local/share/zsh-aisuggestions/zsh-aisuggestions.plugin.zsh` to `~/.zshrc`.
7. If oh-my-zsh is detected, optionally symlink into `$ZSH_CUSTOM/plugins/zsh-aisuggestions/`.

### 5.2 Dependencies

**Python** (sidecar):
- `aiohttp>=3.9.0` (async HTTP client for LLM API calls)
- `pyyaml>=6.0` (config file parsing)
- No provider-specific SDKs. Everything goes through the OpenAI-compatible HTTP API.

**Zsh** (plugin):
- Zsh >= 5.8
- `socat` OR Python (for socket communication from Zsh — we use a tiny Python one-liner as fallback)

---

## 6. Implementation Plan — Ship Tonight

This is an aggressive, single-session implementation plan. Every phase builds on the last. No throwaway scaffolding — every line of code written stays in the final product.

### Phase A: Sidecar Core (≈30 min)

Build the Python sidecar as a fully working daemon:

1. **`sidecar/config.py`** — Load `~/.config/zsh-aisuggestions/config.yaml` with sane defaults. No validation complexity — just `dict.get()` with fallbacks.
2. **`sidecar/llm.py`** — Single `OpenAICompatibleProvider` class. Uses `aiohttp` to POST to `{base_url}/chat/completions`. Constructs messages from buffer + context. Parses response. ~80 lines.
3. **`sidecar/context.py`** — Pure functions: `build_prompt(request_data) -> messages`. Assembles system prompt + user context into OpenAI messages format. ~50 lines.
4. **`sidecar/cache.py`** — `OrderedDict`-based LRU cache with TTL. ~40 lines.
5. **`sidecar/server.py`** — `asyncio` Unix domain socket server. Handles `suggest`, `health`, `shutdown` request types. Cancels in-flight requests on new input. ~120 lines.
6. **`sidecar/__init__.py`** — Empty.
7. **`sidecar/__main__.py`** — Entry point: parse args, start server. So the sidecar runs via `python -m sidecar`.

**Exit criteria**: `echo '{"type":"suggest","buffer":"git reb","cursor_position":7,"context":{"cwd":"/tmp"}}' | socat - UNIX-CONNECT:/tmp/zsh-aisuggestions-$(id -u).sock` returns a valid suggestion.

### Phase B: Zsh Plugin (≈45 min)

Build the Zsh plugin with full async support:

1. **Sidecar lifecycle** — `_aisug_ensure_sidecar()`: check pidfile, start sidecar if not running, verify health via socket.
2. **Socket communication** — `_aisug_query()`: send JSON to socket, read response. Use `python3 -c` one-liner for reliable socket I/O (no `socat` dependency).
3. **Context gathering** — `_aisug_gather_context()`: collect cwd, git info, last exit code, last command, env hints. All in Zsh.
4. **Ghost text rendering** — Set `$POSTDISPLAY` with dimmed color via `zle_highlight`.
5. **Async trigger** — Background subshell writes suggestion to temp file, sends `SIGUSR1` to parent shell. `TRAPUSR1` reads temp file and updates `$POSTDISPLAY`.
6. **Debounce** — `sched` or timer-based: only fire async query after 300ms of no keystrokes.
7. **Keybindings** — Right arrow / Tab to accept, Ctrl+→ for word accept, Ctrl+G for force trigger.
8. **History fallback** — Immediate prefix match from `fc -l` while AI loads.
9. **ZLE hooks** — Wrap `self-insert` and other editing widgets to auto-trigger and auto-dismiss.

**Exit criteria**: Source the plugin, type a partial command, see ghost text appear, press Right to accept.

### Phase C: Config + Install (≈15 min)

1. **`config.example.yaml`** — Copy from spec above, well-commented.
2. **`install.sh`** — Create venv, install deps, copy files, print instructions.
3. **`uninstall.sh`** — Remove installed files, kill sidecar, print cleanup instructions.

**Exit criteria**: `bash install.sh` on a clean machine → `source ~/.zshrc` → working suggestions.

### Phase D: Test + Harden (≈15 min)

1. Smoke test the full loop manually.
2. Fix any edge cases: empty buffer, sidecar crash recovery, API timeout handling.
3. Ensure clean startup/shutdown cycle.

**Total estimated time: ~2 hours.**

---

## 7. Error Handling

| Scenario | Behavior |
|---|---|
| Sidecar not running | Zsh plugin auto-starts it. If start fails, fall back to local history only. Log warning once. |
| API key missing | Sidecar logs error on startup, refuses `suggest` requests, returns empty. Zsh plugin falls back to local history. |
| API timeout (>3s) | Cancel request, show nothing (or keep local history suggestion). Do not block prompt. |
| API rate limit | Back off exponentially. Switch to local-only mode temporarily. Log warning. |
| Invalid API response | Ignore, show nothing. Log error. |
| Socket connection refused | Attempt to restart sidecar once. If still failing, disable AI suggestions for this session with a one-time warning. |
| Malformed config | Fall back to defaults. Log which fields were invalid. |

---

## 8. Security Considerations

- API keys are NEVER stored in config files. Always read from environment variables.
- The Unix socket is created with `0600` permissions (owner-only).
- The sidecar never logs prompt content or API responses to disk by default.
- Destructive command detection: if the suggestion contains patterns like `rm -rf /`, `DROP DATABASE`, `mkfs` — suppress entirely (configurable via `block_destructive`).
- No telemetry, no analytics, no external calls except to the configured LLM provider.

---

## 9. Performance Targets

| Metric | Target |
|---|---|
| Local history suggestion latency | < 10ms |
| AI suggestion latency (API) | < 1000ms (p90) |
| Socket round-trip overhead | < 5ms |
| Memory usage (sidecar) | < 50MB |
| CPU usage (sidecar, idle) | ~0% |
| Cache hit rate (steady state) | > 30% |

---

## 10. Non-Goals (Explicit Scope Exclusions)

- **Custom terminal emulator**: We use existing terminals.
- **Provider-specific SDKs**: Everything goes through OpenAI-compatible HTTP API.
- **Rich text editor input**: We use standard Zsh line editing.
- **Team/collaboration features**: This is a personal tool.
- **GUI/Electron/Tauri overlay**: The entire UX lives inside the terminal via ZLE.
- **Bash/Fish support in v1**: Zsh only for now.

---

## 11. Future Enhancements (Post-v1)

- Error explanation mode (`Ctrl+X` sends last error to LLM for diagnosis)
- Multi-line command suggestion support
- Streaming API responses (show suggestion character by character)
- Multiple suggestion selection via `fzf` integration
- Fish shell support
- Native Anthropic/provider-specific API support for features beyond chat completions
