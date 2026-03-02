# zsh-aisuggestions

LLM-powered command suggestions for Zsh. Type a partial command or a natural-language description, press a hotkey, and get an intelligent suggestion — powered by any OpenAI-compatible API.

No subscription, no telemetry, no intermediary servers. You bring your own API key.

## Features

- **Rewrite mode** (`Ctrl+G`) — Replaces the entire command line. Translates natural language to commands, fixes typos, and rewrites based on context (last error, git state, cwd).
- **Autocomplete mode** (`Ctrl+]`) — Inserts inline ghost text at the cursor position, completing the current token or argument.
- **Any LLM provider** — Works with OpenAI, DeepSeek, Ollama, LM Studio, Groq, Together AI, or any OpenAI-compatible endpoint.
- **Context-aware** — Sends cwd, git branch/dirty status, last exit code, last command, OS, and recent history to the LLM for better suggestions.
- **Git clone resolution** — `git clone <name>` queries the GitHub API to resolve real repository URLs instead of relying on LLM hallucination.
- **In-memory caching** — LRU cache with configurable size and TTL to avoid redundant API calls.
- **Privacy-first** — All API calls go directly to your configured provider. No data collection.

## Requirements

- **Zsh** >= 5.8
- **Python** >= 3.10
- An API key for an OpenAI-compatible LLM provider (or a local model via Ollama/LM Studio)

## Installation

### Quick install

```sh
git clone https://github.com/EphemeralStudio/zsh-aisuggestions.git
cd zsh-aisuggestions
bash install.sh
```

The installer will:

1. Check that Python >= 3.10 is available
2. Copy plugin files to `~/.local/share/zsh-aisuggestions/`
3. Create a Python virtual environment and install dependencies
4. Create a default config at `~/.config/zsh-aisuggestions/config.yaml`
5. Symlink into oh-my-zsh plugins directory (if oh-my-zsh is detected)

### Activate the plugin

Add this line to your `~/.zshrc`:

```sh
source ~/.local/share/zsh-aisuggestions/zsh-aisuggestions.plugin.zsh
```

Or, if using oh-my-zsh, add `zsh-aisuggestions` to your plugins list:

```sh
plugins=(... zsh-aisuggestions)
```

### Set your API key

```sh
export OPENAI_API_KEY="sk-..."
```

Add this to your `~/.zshrc` or `~/.zshenv` to persist it across sessions.

Then restart your shell:

```sh
exec zsh
```

## Usage

### Key Bindings

| Key | Action |
|---|---|
| `Ctrl+G` | **Rewrite mode** — full command replacement, natural language translation |
| `Ctrl+]` | **Autocomplete mode** — inline ghost text completion at cursor |
| `Tab` | Accept suggestion (or normal tab-complete if no suggestion) |
| `Right Arrow` | Accept suggestion |
| `Backspace` | Dismiss suggestion and restore original input |

### Examples

**Translate natural language to a command:**

```
> list all running docker containers    # press Ctrl+G
> docker ps                             # suggestion appears as ghost text, press Tab to accept
```

**Fix a typo:**

```
> dockr bilud -t myapp .                # press Ctrl+G
> docker build -t myapp .               # corrected command appears
```

**Context-aware suggestion after an error:**

```
> npm start                             # exits with error: "port 3000 in use"
> kill the process on port 3000         # press Ctrl+G
> lsof -ti:3000 | xargs kill -9        # AI suggests based on last error context
```

**Inline autocomplete:**

```
> docker run --rm -it -p 3000:30       # cursor at end, press Ctrl+]
> docker run --rm -it -p 3000:3000     # completes the port mapping
```

**Git clone resolution:**

```
> git clone react                       # press Ctrl+G
> git clone https://github.com/facebook/react.git  # resolved via GitHub API
```

## Configuration

The config file lives at `~/.config/zsh-aisuggestions/config.yaml`. A default is created during installation. All settings have sane defaults — only change what you need.

```yaml
# LLM API (OpenAI-compatible endpoint)
api_base_url: https://api.openai.com/v1
api_key_env: OPENAI_API_KEY      # Name of the env var containing your API key
model: gpt-4o-mini

# Behavior
debounce_ms: 300                 # ms to wait after last keystroke before triggering AI
max_context_lines: 50            # max lines of scrollback to include in context
max_history_commands: 10         # recent history commands to include
cache_size: 200                  # max cached suggestions (in-memory LRU)
cache_ttl_seconds: 300           # cache entry time-to-live
request_timeout_seconds: 5       # max time to wait for LLM API response

# Display
ghost_text_color: 8              # ANSI color code for ghost text (8 = gray/dim)

# Safety
block_destructive: true          # instruct LLM to avoid destructive commands
max_tokens: 150                  # max response tokens for suggestions

# Fallback
local_history_fallback: true     # show history match while waiting for AI
```

### Using different LLM providers

Change `api_base_url` and `model` in your config:

| Provider | `api_base_url` | `model` example |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.1-8b-instant` |
| Together AI | `https://api.together.xyz/v1` | `meta-llama/Llama-3-8b-chat-hf` |
| Ollama (local) | `http://localhost:11434/v1` | `codellama` |
| LM Studio (local) | `http://localhost:1234/v1` | `local-model` |

For local providers (Ollama, LM Studio), no API key is needed — just set the `api_base_url` and `model`.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Zsh Shell                                  │
│                                             │
│  zsh-aisuggestions.plugin.zsh               │
│  ├── ZLE widgets (trigger, accept, dismiss) │
│  ├── Ghost text rendering via POSTDISPLAY   │
│  └── Context gathering (cwd, git, history)  │
│           │                                 │
│           │ Unix domain socket              │
│           ▼                                 │
│  sidecar/ (Python daemon)                   │
│  ├── server.py  — async socket server       │
│  ├── llm.py     — OpenAI-compatible client  │
│  ├── context.py — prompt assembly           │
│  ├── cache.py   — LRU suggestion cache      │
│  └── config.py  — config loading            │
└─────────────────────────────────────────────┘
```

The Zsh plugin communicates with a lightweight Python sidecar process over a Unix domain socket. The sidecar handles LLM API calls, caching, and prompt construction. It starts automatically on first use and restarts cleanly on `exec zsh`.

## Uninstalling

```sh
bash uninstall.sh
```

Then remove the `source ...` line from your `~/.zshrc` and optionally delete the config:

```sh
rm -rf ~/.config/zsh-aisuggestions
```

## License

MIT
