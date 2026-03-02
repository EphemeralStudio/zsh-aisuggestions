"""Configuration loading for zsh-aisuggestions sidecar."""

import os
import logging
import re
from pathlib import Path
from typing import Any, Dict, Optional

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

# Type coercion map: cast loaded string values to match DEFAULTS types
_TYPE_MAP = {k: type(v) for k, v in DEFAULTS.items()}


def _parse_simple_yaml(text: str) -> Dict[str, Any]:
    """Parse a flat key: value YAML file using only stdlib.

    Handles the subset of YAML used by config.example.yaml:
    scalar keys, scalar values (str, int, float, bool), and comments.
    Does NOT handle nested mappings, lists, or multi-line values.
    """
    result = {}  # type: Dict[str, Any]
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Strip inline comment (but not '#' inside a value that starts
        # after the colon, e.g. urls containing fragments are unusual here)
        m = re.match(r'^([A-Za-z_][\w]*)\s*:\s*(.*?)(?:\s+#.*)?$', line)
        if not m:
            continue
        key = m.group(1)
        val_str = m.group(2).strip()
        # Boolean
        if val_str.lower() in ("true", "yes", "on"):
            result[key] = True
        elif val_str.lower() in ("false", "no", "off"):
            result[key] = False
        # Integer
        elif re.fullmatch(r'-?\d+', val_str):
            result[key] = int(val_str)
        # Float
        elif re.fullmatch(r'-?\d+\.\d+', val_str):
            result[key] = float(val_str)
        else:
            result[key] = val_str
    return result


def find_config_path() -> Optional[Path]:
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


def load_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Load configuration from YAML file with fallback to defaults."""
    config = dict(DEFAULTS)

    path = Path(config_path) if config_path else find_config_path()

    if path and path.exists():
        try:
            text = path.read_text(encoding="utf-8")
        except Exception as e:
            logger.warning("Failed to read config from %s: %s, using defaults", path, e)
            text = ""

        if text:
            # Try PyYAML first (full YAML support); fall back to simple parser
            user_config = None  # type: Optional[Dict[str, Any]]
            try:
                import yaml
                parsed = yaml.safe_load(text)
                if isinstance(parsed, dict):
                    user_config = parsed
                else:
                    logger.warning("Config file %s is not a valid YAML mapping, trying simple parser", path)
            except ImportError:
                pass
            except Exception as e:
                logger.warning("PyYAML failed to parse %s: %s, trying simple parser", path, e)

            if user_config is None:
                try:
                    user_config = _parse_simple_yaml(text)
                except Exception as e:
                    logger.warning("Simple YAML parser failed for %s: %s, using defaults", path, e)

            if user_config:
                # Coerce types to match defaults where possible
                for k, v in user_config.items():
                    expected_type = _TYPE_MAP.get(k)
                    if expected_type is not None and not isinstance(v, expected_type):
                        try:
                            user_config[k] = expected_type(v)
                        except (ValueError, TypeError):
                            pass
                config.update(user_config)
                logger.info("Loaded config from %s", path)
    else:
        logger.info("No config file found, using defaults")

    # Resolve API key from environment variable
    api_key_env = config.get("api_key_env", "OPENAI_API_KEY")
    config["api_key"] = os.environ.get(api_key_env, "")

    if not config["api_key"]:
        logger.warning("API key not found in env var '%s'. AI suggestions will not work.", api_key_env)

    return config
