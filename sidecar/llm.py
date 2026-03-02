"""OpenAI-compatible LLM provider for zsh-aisuggestions."""

import json
import logging
import asyncio
from typing import Any, Dict, List
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

logger = logging.getLogger("zsh-aisuggestions")

SYSTEM_PROMPT = """\
You are a terminal command suggestion engine. The user has typed a partial or complete \
command in their terminal and is asking for your best suggestion. You may:

1. COMPLETE the command — extend what they've typed so far.
2. REWRITE the command — replace their input entirely with a better command, \
if context (last error, project state, git state) suggests they need something different.
3. FIX the command — correct typos, wrong flags, or syntax errors in what they typed.

Rules:
- Return ONLY the full suggested command. No explanation, no commentary, no markdown.
- Return exactly one line. No newlines.
- Use context (cwd, project type, last error, exit code, git state) to infer intent.
- If the last command failed (non-zero exit code), consider suggesting a fix or retry.
- Prefer safe commands. Never suggest destructive commands (rm -rf /, DROP DATABASE, etc.) \
unless the user's input clearly signals that intent.
- If the input is ambiguous, prefer the most common usage.
- The suggested command should be immediately executable — no placeholders like <file>."""


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

    def _build_messages(self, user_prompt: str) -> List[Dict[str, str]]:
        return [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ]

    async def complete(self, user_prompt: str) -> str:
        """Send a streaming completion request and return the suggestion string."""
        messages = self._build_messages(user_prompt)
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

        # Clean up: strip whitespace, backticks, quotes
        suggestion = suggestion.strip().strip("`").strip('"').strip("'")
        # Only return single-line suggestions
        if "\n" in suggestion:
            suggestion = suggestion.split("\n")[0].strip()
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


def build_user_prompt(request_data: Dict[str, Any]) -> str:
    """Build the user prompt from the request data and context."""
    buffer = request_data.get("buffer", "")
    cursor_pos = request_data.get("cursor_position", len(buffer))
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
    parts.append(f"\nCurrent input: {buffer}")
    parts.append(f"Cursor position: {cursor_pos}")

    return "\n".join(parts)
