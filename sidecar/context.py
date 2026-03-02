"""Context assembly for zsh-aisuggestions sidecar."""

import os
from pathlib import Path

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

ENV_HINT_FILES = [
    ".env", "Dockerfile", "Makefile", "docker-compose.yml",
    "docker-compose.yaml", ".nvmrc", ".node-version",
    ".python-version", ".ruby-version", ".tool-versions",
    "Procfile", "Vagrantfile", "Jenkinsfile", ".travis.yml",
    ".github", ".gitlab-ci.yml", "Taskfile.yml",
]


def detect_project_type(cwd: str) -> str:
    """Detect project type from marker files in the directory."""
    try:
        p = Path(cwd)
        if not p.is_dir():
            return ""
        entries = {e.name for e in p.iterdir()}
        for marker, ptype in PROJECT_MARKERS.items():
            if marker in entries:
                return ptype
    except (OSError, PermissionError):
        pass
    return ""


def detect_env_hints(cwd: str) -> list[str]:
    """Detect environment hint files present in the directory."""
    try:
        p = Path(cwd)
        if not p.is_dir():
            return []
        entries = {e.name for e in p.iterdir()}
        return [f for f in ENV_HINT_FILES if f in entries]
    except (OSError, PermissionError):
        return []


def enrich_context(context: dict) -> dict:
    """Enrich the context dict with server-side detected information."""
    cwd = context.get("cwd", os.getcwd())

    # Fill in project type if not provided
    if not context.get("project_type"):
        context["project_type"] = detect_project_type(cwd)

    # Fill in env hints if not provided
    if not context.get("env_hints"):
        context["env_hints"] = detect_env_hints(cwd)

    return context
