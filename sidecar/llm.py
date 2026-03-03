"""OpenAI-compatible LLM provider for zsh-aisuggestions."""

import json
import logging
import asyncio
from typing import Any, Dict, List
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

logger = logging.getLogger("zsh-aisuggestions")

SYSTEM_PROMPT_REWRITE = """\
You are a terminal command suggestion engine. The user is typing in their terminal \
and pressing a hotkey to ask for your best command suggestion. Determine which mode \
applies and respond accordingly:

1. TRANSLATE — The input is a natural-language description (e.g. "list all running \
docker containers", "find large files over 100MB", "ps aux to get all proc ids of opencode"). \
Convert the ENTIRE description into the single best shell command that fulfills the \
complete request. Do NOT stop at the first verb — satisfy every part of the description. \
For example "ps aux to get all proc ids of opencode" means: list processes, filter for \
"opencode", and extract only the PIDs — so the answer must include awk/grep to extract PIDs, \
not just "ps aux | grep opencode".
2. COMPLETE — The input is already a valid partial command. Extend it to a useful completion.
3. FIX — The input has typos, wrong flags, or syntax errors. Return the corrected command.
4. REWRITE — Context (last error, exit code, project state) suggests the user needs a \
different command entirely. Return that command.

Rules:
- Return ONLY the full suggested command. No explanation, no commentary, no markdown.
- The user is running zsh. All suggestions MUST use zsh-compatible syntax. \
NEVER wrap commands in "bash -c" or "sh -c", and NEVER suggest switching shells. \
NEVER include shebangs (#!/bin/bash, #!/bin/sh). The command runs directly in the user's zsh.
- For simple commands, return a single line.
- For multi-line constructs (for/while loops, if/else blocks, here-documents), use real \
newlines with proper indentation. Keep it concise — no more than 10 lines.
- Satisfy the user's COMPLETE intent. Read the whole input before deciding what to suggest.
- Use context (cwd, project type, last error, exit code, git state) to infer intent.
- If the last command failed (non-zero exit code), consider suggesting a fix or retry.
- Prefer safe commands. Never suggest destructive commands (rm -rf /, DROP DATABASE, etc.) \
unless the user's input clearly signals that intent.
- If the input is ambiguous, prefer the most common usage.
- The suggested command should be immediately executable — no placeholders like <file>."""

SYSTEM_PROMPT_COMPLETE = """\
You are a terminal inline-completion engine. The user has an existing command in their \
terminal with the cursor at a specific position (marked with ▌). Your job is to complete \
the token or argument at the cursor position while PRESERVING all existing text before \
and after the cursor.

Rules:
- Return the FULL command line with your completion inserted at the cursor position.
- The user is running zsh. All completions MUST use zsh-compatible syntax. \
NEVER wrap commands in "bash -c" or "sh -c", and NEVER suggest switching shells.
- Keep ALL text before the cursor exactly as-is.
- Keep ALL text after the cursor exactly as-is.
- Only insert new text at the cursor position to complete the current token/flag/argument.
- Return exactly one line. No explanation, no commentary, no markdown, no newlines.
- The result must be immediately executable — no placeholders.
- If the cursor is after a partial flag like "--", complete it to a valid flag (e.g. "--recursive").
- If the cursor is after a partial command/path, complete it appropriately.
- If there is nothing useful to insert, return the input unchanged (without the cursor marker)."""


class LLMProvider:
    """OpenAI-compatible chat completions provider.

    Works with: OpenAI, DeepSeek, Ollama, LM Studio, vLLM,
    Together AI, Groq, Anthropic (via OpenAI-compat), etc.
    """

    def __init__(self, base_url: str, api_key: str, model: str,
                 max_tokens: int = 150, timeout: float = 5.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.max_tokens = max_tokens
        self.timeout = timeout

    def _build_messages(self, user_prompt: str,
                        system_prompt: str = SYSTEM_PROMPT_REWRITE) -> List[Dict[str, str]]:
        return [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]

    async def complete(self, user_prompt: str,
                       system_prompt: str = SYSTEM_PROMPT_REWRITE) -> str:
        """Send a streaming completion request and return the suggestion string."""
        messages = self._build_messages(user_prompt, system_prompt)
        url = f"{self.base_url}/chat/completions"
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": self.max_tokens,
            "temperature": 0.3,
            "n": 1,
            "stream": True,
        }

        headers = {
            "Content-Type": "application/json",
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        data = json.dumps(payload).encode("utf-8")

        # Run streaming HTTP call in thread pool
        loop = asyncio.get_event_loop()
        try:
            suggestion = await asyncio.wait_for(
                loop.run_in_executor(None, self._sync_stream_request, url, data, headers),
                timeout=self.timeout,
            )
        except asyncio.TimeoutError:
            logger.warning("LLM API request timed out after %.1fs", self.timeout)
            return ""
        except asyncio.CancelledError:
            logger.debug("LLM API request was cancelled")
            return ""

        if not suggestion:
            return ""

        # Clean up: strip whitespace
        suggestion = suggestion.strip()
        # Strip wrapping backticks (common LLM artifact: ```command``` or `command`)
        # Only strip if they form a matching pair — don't strip quotes since
        # they are valid shell characters needed in complete mode.
        while suggestion.startswith("`") and suggestion.endswith("`") and len(suggestion) > 1:
            suggestion = suggestion[1:-1].strip()
        # Cap multi-line suggestions at 10 lines
        lines = suggestion.split("\n")
        if len(lines) > 10:
            suggestion = "\n".join(lines[:10])
        return suggestion

    def _sync_stream_request(self, url: str, data: bytes, headers: dict) -> str:
        """Perform a streaming HTTP request, collecting tokens (called from thread pool)."""
        try:
            req = Request(url, data=data, headers=headers, method="POST")
            with urlopen(req, timeout=self.timeout) as resp:
                collected = []
                buffer = b""
                for chunk in iter(lambda: resp.read(1024), b""):
                    buffer += chunk
                    # Process complete SSE lines
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        line = line.strip()
                        if not line or line == b"data: [DONE]":
                            continue
                        if line.startswith(b"data: "):
                            try:
                                event = json.loads(line[6:])
                                choices = event.get("choices", [])
                                if choices:
                                    delta = choices[0].get("delta", {})
                                    content = delta.get("content", "")
                                    if content:
                                        collected.append(content)
                            except json.JSONDecodeError:
                                continue
                return "".join(collected)
        except HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8")[:500]
            except Exception:
                pass
            logger.warning("LLM API HTTP error %d: %s", e.code, body)
            # Fall back to non-streaming on error
            return self._sync_request_fallback(url, data, headers)
        except URLError as e:
            logger.warning("LLM API connection error: %s", e.reason)
            return ""
        except Exception as e:
            logger.warning("LLM API request failed: %s", e)
            return ""

    def _sync_request_fallback(self, url: str, data: bytes, headers: dict) -> str:
        """Non-streaming fallback for providers that don't support streaming."""
        try:
            # Rebuild payload with stream=False
            payload = json.loads(data)
            payload["stream"] = False
            data = json.dumps(payload).encode("utf-8")
            req = Request(url, data=data, headers=headers, method="POST")
            with urlopen(req, timeout=self.timeout) as resp:
                response_text = resp.read().decode("utf-8")
            resp_json = json.loads(response_text)
            choices = resp_json.get("choices", [])
            if choices:
                return choices[0].get("message", {}).get("content", "")
        except Exception as e:
            logger.warning("LLM fallback request failed: %s", e)
        return ""


def _looks_like_natural_language(buffer: str) -> bool:
    """Heuristic: does the input look like a natural language request rather than a command?"""
    # Natural-language indicators: contains common English filler words that
    # wouldn't appear in a real shell command, or is a long phrase with spaces
    # and no shell operators.
    words = buffer.strip().split()
    if len(words) < 3:
        return False
    nl_markers = {
        "to", "the", "all", "for", "from", "that", "with", "into",
        "how", "what", "which", "where", "please", "show", "get",
        "find", "list", "give", "make", "create", "delete", "remove",
        "using", "of", "in", "on", "and", "or", "but", "is", "are",
        "do", "does", "can", "every", "each",
    }
    lower_words = {w.lower() for w in words}
    matches = lower_words & nl_markers
    # If >=2 natural-language marker words, or >=1 with 4+ words, likely NL
    has_shell_meta = any(c in buffer for c in "|;&<>$`()")
    if has_shell_meta:
        return False
    return len(matches) >= 2 or (len(matches) >= 1 and len(words) >= 4)


def build_user_prompt(request_data: Dict[str, Any]) -> str:
    """Build the user prompt from the request data and context."""
    buffer = request_data.get("buffer", "")
    cursor_pos = request_data.get("cursor_position", len(buffer))
    trigger_mode = request_data.get("trigger_mode", "rewrite")
    context = request_data.get("context", {})

    parts = []

    # Environment info
    os_name = context.get("os", "unknown")
    shell = context.get("shell", "zsh")
    cwd = context.get("cwd", "~")
    parts.append(f"OS: {os_name} | Shell: {shell} | CWD: {cwd}")

    # Project info
    project_type = context.get("project_type", "")
    env_hints = context.get("env_hints", [])
    if project_type:
        parts.append(f"Project: {project_type} (detected from: {', '.join(env_hints)})")

    # Git info
    git_branch = context.get("git_branch", "")
    if git_branch:
        git_dirty = context.get("git_dirty", False)
        parts.append(f"Git: branch={git_branch}, dirty={git_dirty}")

    # Last command context
    last_cmd = context.get("last_command", "")
    last_exit = context.get("last_exit_code", 0)
    if last_cmd:
        parts.append(f"Last command: {last_cmd} (exit code: {last_exit})")

    last_output = context.get("last_output_tail", "")
    if last_output:
        parts.append(f"Last output (tail):\n{last_output}")

    # Recent history
    recent_history = context.get("recent_history", [])
    if recent_history:
        history_str = "\n".join(f"  {cmd}" for cmd in recent_history[-10:])
        parts.append(f"Recent commands:\n{history_str}")

    # Current input
    if trigger_mode == "rewrite" and _looks_like_natural_language(buffer):
        parts.append(f"\nUser request (natural language — TRANSLATE to a command): {buffer}")
    else:
        # Show cursor position visually so the LLM knows where the user is editing
        cursor_pos = min(cursor_pos, len(buffer))
        annotated = buffer[:cursor_pos] + "▌" + buffer[cursor_pos:]
        parts.append(f"\nCurrent input (▌ = cursor): {annotated}")

    return "\n".join(parts)
