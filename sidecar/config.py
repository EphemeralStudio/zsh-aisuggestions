"""Configuration loading for zsh-aisuggestions sidecar."""

import os
import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger("zsh-aisuggestions")

DEFAULTS = {
    "api_base_url": "https://api.openai.com/v1",
    "api_key_env": "OPENAI_API_KEY",
    "model": "gpt-4o-mini",
    "debounce_ms": 300,
    "max_context_lines": 50,
    "max_history_commands": 10,
    "cache_size": 200,
    "cache_ttl_seconds": 300,
    "max_tokens": 150,
    "block_destructive": True,
    "local_history_fallback": True,
    "ghost_text_color": 8,
    "request_timeout_seconds": 5,
}


def find_config_path() -> Path | None:
    """Find the config file in standard locations."""
    candidates = [
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        / "zsh-aisuggestions"
        / "config.yaml",
        Path.home() / ".zsh-aisuggestions.yaml",
    ]
    for p in candidates:
        if p.exists():
            return p
    return None


def load_config(config_path: str | None = None) -> dict[str, Any]:
    """Load configuration from YAML file with fallback to defaults."""
    config = dict(DEFAULTS)

    path = Path(config_path) if config_path else find_config_path()

    if path and path.exists():
        try:
            import yaml

            with open(path) as f:
                user_config = yaml.safe_load(f)
            if isinstance(user_config, dict):
                config.update(user_config)
                logger.info("Loaded config from %s", path)
            else:
                logger.warning("Config file %s is not a valid YAML mapping, using defaults", path)
        except ImportError:
            logger.warning("PyYAML not installed, using defaults")
        except Exception as e:
            logger.warning("Failed to load config from %s: %s, using defaults", path, e)
    else:
        logger.info("No config file found, using defaults")

    # Resolve API key from environment variable
    api_key_env = config.get("api_key_env", "OPENAI_API_KEY")
    config["api_key"] = os.environ.get(api_key_env, "")

    if not config["api_key"]:
        logger.warning("API key not found in env var '%s'. AI suggestions will not work.", api_key_env)

    return config
