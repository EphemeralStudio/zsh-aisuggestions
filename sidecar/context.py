"""Context assembly for zsh-aisuggestions sidecar."""

import os
import time
from pathlib import Path
from typing import Dict, List, Tuple

PROJECT_MARKERS = {
    "package.json": "node",
    "pyproject.toml": "python",
    "setup.py": "python",
    "requirements.txt": "python",
    "Cargo.toml": "rust",
    "go.mod": "go",
    "Gemfile": "ruby",
    "Podfile": "ios",
    "CMakeLists.txt": "cmake",
    "docker-compose.yml": "docker",
    "docker-compose.yaml": "docker",
    "Makefile": "make",
    "pom.xml": "java",
    "build.gradle": "java",
    "mix.exs": "elixir",
    "Cargo.lock": "rust",
}

ENV_HINT_FILES = frozenset({
    ".env", "Dockerfile", "Makefile", "docker-compose.yml",
    "docker-compose.yaml", ".nvmrc", ".node-version",
    ".python-version", ".ruby-version", ".tool-versions",
    "Procfile", "Vagrantfile", "Jenkinsfile", ".travis.yml",
    ".github", ".gitlab-ci.yml", "Taskfile.yml",
})

# Cache: cwd -> (project_type, env_hints, timestamp)
_dir_cache: Dict[str, Tuple[str, List[str], float]] = {}
_DIR_CACHE_TTL = 30.0


def detect_project_and_hints(cwd: str) -> Tuple[str, List[str]]:
    """Detect project type and env hints in a single directory scan (cached)."""
    now = time.monotonic()

    if cwd in _dir_cache:
        project_type, env_hints, ts = _dir_cache[cwd]
        if now - ts < _DIR_CACHE_TTL:
            return project_type, env_hints

    try:
        p = Path(cwd)
        if not p.is_dir():
            return "", []
        entries = {e.name for e in p.iterdir()}
    except (OSError, PermissionError):
        return "", []

    project_type = ""
    for marker, ptype in PROJECT_MARKERS.items():
        if marker in entries:
            project_type = ptype
            break

    env_hints = [f for f in ENV_HINT_FILES if f in entries]

    _dir_cache[cwd] = (project_type, env_hints, now)
    return project_type, env_hints


def enrich_context(context: dict) -> dict:
    """Enrich the context dict with server-side detected information."""
    cwd = context.get("cwd", os.getcwd())

    if not context.get("project_type") or not context.get("env_hints"):
        project_type, env_hints = detect_project_and_hints(cwd)
        if not context.get("project_type"):
            context["project_type"] = project_type
        if not context.get("env_hints"):
            context["env_hints"] = env_hints

    return context
