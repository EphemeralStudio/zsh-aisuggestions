"""Unix domain socket server for zsh-aisuggestions sidecar."""

import asyncio
import json
import logging
import os
import signal
import sys
from pathlib import Path
from typing import Any, Dict, Optional

from .cache import SuggestionCache
from .config import load_config
from .context import enrich_context, try_resolve_git_clone
from .llm import LLMProvider, build_user_prompt

logger = logging.getLogger("zsh-aisuggestions")


def get_socket_path() -> str:
    """Get the Unix socket path."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime_dir:
        return os.path.join(runtime_dir, "zsh-aisuggestions.sock")
    return f"/tmp/zsh-aisuggestions-{os.getuid()}.sock"


def get_pid_path() -> str:
    """Get the PID file path."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime_dir:
        return os.path.join(runtime_dir, "zsh-aisuggestions.pid")
    return f"/tmp/zsh-aisuggestions-{os.getuid()}.pid"


class SidecarServer:
    """Async Unix domain socket server for handling suggestion requests."""

    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.socket_path = get_socket_path()
        self.pid_path = get_pid_path()
        self.cache = SuggestionCache(
            max_size=config.get("cache_size", 200),
            ttl_seconds=config.get("cache_ttl_seconds", 300),
        )
        self.llm = LLMProvider(
            base_url=config.get("api_base_url", "https://api.openai.com/v1"),
            api_key=config.get("api_key", ""),
            model=config.get("model", "gpt-4o-mini"),
            max_tokens=config.get("max_tokens", 150),
            timeout=config.get("request_timeout_seconds", 5),
        )
        self._current_task: Optional[asyncio.Task] = None
        self._server: Optional[asyncio.Server] = None
        self._running = True

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        """Handle a single client connection."""
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=10.0)
            if not data:
                writer.close()
                await writer.wait_closed()
                return

            request_text = data.decode("utf-8").strip()
            logger.debug("Received request: %s", request_text[:200])

            try:
                request = json.loads(request_text)
            except json.JSONDecodeError as e:
                response = {"error": f"Invalid JSON: {e}"}
                writer.write(json.dumps(response, separators=(',', ':')).encode("utf-8"))
                await writer.drain()
                writer.close()
                await writer.wait_closed()
                return

            req_type = request.get("type", "suggest")

            if req_type == "health":
                response = self._handle_health()
            elif req_type == "shutdown":
                response = {"status": "shutting_down"}
                writer.write(json.dumps(response, separators=(',', ':')).encode("utf-8"))
                await writer.drain()
                writer.close()
                await writer.wait_closed()
                self._running = False
                asyncio.get_event_loop().call_soon(self._shutdown)
                return
            elif req_type == "suggest":
                response = await self._handle_suggest(request)
            else:
                response = {"error": f"Unknown request type: {req_type}"}

            writer.write(json.dumps(response, separators=(',', ':')).encode("utf-8"))
            await writer.drain()

        except asyncio.TimeoutError:
            logger.debug("Client connection timed out")
        except ConnectionResetError:
            logger.debug("Client connection reset")
        except Exception as e:
            logger.error("Error handling client: %s", e)
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    def _handle_health(self) -> dict:
        """Handle health check request."""
        return {
            "status": "ok",
            "model": self.config.get("model", "unknown"),
            "api_base_url": self.config.get("api_base_url", "unknown"),
            "cache_size": self.cache.size,
        }

    async def _handle_suggest(self, request: dict) -> dict:
        """Handle suggestion request with debounce and caching."""
        buffer = request.get("buffer", "").strip()

        if not buffer or len(buffer) < 2:
            return {"suggestion": "", "source": "none", "cached": False}

        # Cancel any in-flight suggestion request
        if self._current_task and not self._current_task.done():
            self._current_task.cancel()
            try:
                await self._current_task
            except (asyncio.CancelledError, Exception):
                pass

        # Enrich context with server-side info
        context = request.get("context", {})
        context = enrich_context(context)

        # Short-circuit: resolve "git clone <name>" to a real URL
        resolved_clone = await asyncio.get_event_loop().run_in_executor(
            None, try_resolve_git_clone, buffer, 3.0
        )
        if resolved_clone:
            logger.debug("Resolved git clone: %s -> %s", buffer, resolved_clone)
            self.cache.put(buffer, resolved_clone, cwd=context.get("cwd", ""),
                           last_exit_code=context.get("last_exit_code", 0),
                           git_branch=context.get("git_branch", ""))
            return {
                "suggestion": resolved_clone,
                "mode": "rewrite",
                "source": "github",
                "cached": False,
            }

        # Check cache
        cwd = context.get("cwd", "")
        last_exit = context.get("last_exit_code", 0)
        git_branch = context.get("git_branch", "")

        cached = self.cache.get(buffer, cwd, last_exit, git_branch)
        if cached:
            logger.debug("Cache hit for buffer: %s", buffer[:50])
            mode = "complete" if cached.startswith(buffer) else "rewrite"
            return {
                "suggestion": cached,
                "mode": mode,
                "source": "cache",
                "cached": True,
            }

        # Check if API key is available
        if not self.config.get("api_key"):
            return {"suggestion": "", "source": "none", "cached": False,
                    "error": "No API key configured"}

        # Make LLM request
        user_prompt = build_user_prompt(request)
        try:
            self._current_task = asyncio.create_task(self.llm.complete(user_prompt))
            suggestion = await self._current_task
        except asyncio.CancelledError:
            return {"suggestion": "", "source": "cancelled", "cached": False}
        except Exception as e:
            logger.error("LLM request failed: %s", e)
            return {"suggestion": "", "source": "error", "cached": False}
        finally:
            self._current_task = None

        if suggestion:
            # Cache the result
            self.cache.put(buffer, suggestion, cwd, last_exit, git_branch)

        # Determine if this is a completion or a rewrite
        mode = "complete" if suggestion.startswith(buffer) else "rewrite"

        return {
            "suggestion": suggestion,
            "mode": mode,
            "source": "llm",
            "cached": False,
        }

    def _shutdown(self) -> None:
        """Initiate server shutdown."""
        if self._server:
            self._server.close()
        loop = asyncio.get_event_loop()
        loop.call_soon(loop.stop)

    def _cleanup(self) -> None:
        """Remove socket and pid files."""
        try:
            if os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
        except OSError:
            pass
        try:
            if os.path.exists(self.pid_path):
                os.unlink(self.pid_path)
        except OSError:
            pass

    def _write_pid(self) -> None:
        """Write current PID to pidfile."""
        with open(self.pid_path, "w") as f:
            f.write(str(os.getpid()))

    async def start(self) -> None:
        """Start the Unix domain socket server."""
        # Clean up stale socket
        if os.path.exists(self.socket_path):
            try:
                os.unlink(self.socket_path)
            except OSError:
                pass

        self._write_pid()

        # Create socket with restricted permissions
        old_umask = os.umask(0o177)  # Creates socket with 0600
        try:
            self._server = await asyncio.start_unix_server(
                self.handle_client, path=self.socket_path
            )
        finally:
            os.umask(old_umask)

        model = self.config.get("model", "unknown")
        base_url = self.config.get("api_base_url", "unknown")
        has_key = bool(self.config.get("api_key"))
        logger.info(
            "zsh-aisuggestions sidecar started | socket=%s | model=%s | api=%s | key=%s",
            self.socket_path, model, base_url, "present" if has_key else "MISSING"
        )

        try:
            async with self._server:
                await self._server.serve_forever()
        except asyncio.CancelledError:
            pass
        finally:
            self._cleanup()
            logger.info("zsh-aisuggestions sidecar stopped")


def run_server(config_path: Optional[str] = None) -> None:
    """Entry point to start the sidecar server."""
    config = load_config(config_path)

    # Set up logging
    log_level = logging.DEBUG if os.environ.get("AISUG_DEBUG") else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    server = SidecarServer(config)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    # Handle signals
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, server._shutdown)

    try:
        loop.run_until_complete(server.start())
    except KeyboardInterrupt:
        pass
    finally:
        server._cleanup()
        loop.close()
