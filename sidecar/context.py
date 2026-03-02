"""Context assembly for zsh-aisuggestions sidecar."""

import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

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


# ─── GitHub Repository Resolver ──────────────────────────────────────────────

logger = logging.getLogger("zsh-aisuggestions")

# Cache: repo_name -> (clone_url, timestamp)
_repo_cache: Dict[str, Tuple[str, float]] = {}
_REPO_CACHE_TTL = 300.0  # 5 minutes

# Matches: git clone <name> [optional extra args]
# where <name> is a bare word (no / or :// -- those are already full URLs)
_GIT_CLONE_RE = re.compile(
    r'^git\s+clone\s+(?:--[a-z-]+\s+)*([A-Za-z0-9_][\w.-]*)(\s+.*)?$'
)


def resolve_github_repo(name: str, timeout: float = 3.0) -> Optional[str]:
    """Resolve a short repo name to a GitHub clone URL via the search API.

    Returns the HTTPS clone URL of the top-starred match, or None.
    Results are cached for 5 minutes.
    """
    key = name.lower()
    now = time.monotonic()

    if key in _repo_cache:
        url, ts = _repo_cache[key]
        if now - ts < _REPO_CACHE_TTL:
            return url

    try:
        api_url = (
            f"https://api.github.com/search/repositories"
            f"?q={name}+in:name&per_page=1&sort=stars"
        )
        req = Request(api_url, headers={
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "zsh-aisuggestions",
        })
        with urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())

        items = data.get("items", [])
        if items:
            clone_url = items[0].get("clone_url", "")
            if clone_url:
                _repo_cache[key] = (clone_url, now)
                return clone_url
    except (HTTPError, URLError, OSError, ValueError) as e:
        logger.debug("GitHub repo search failed for '%s': %s", name, e)
    except Exception as e:
        logger.debug("GitHub repo search unexpected error for '%s': %s", name, e)

    return None


def try_resolve_git_clone(buffer: str, timeout: float = 3.0) -> Optional[str]:
    """If buffer is 'git clone <bare-name>', resolve to a full git clone command.

    Returns the completed command string, or None if not applicable.
    """
    m = _GIT_CLONE_RE.match(buffer.strip())
    if not m:
        return None

    repo_name = m.group(1)
    extra_args = (m.group(2) or "").strip()

    url = resolve_github_repo(repo_name, timeout=timeout)
    if not url:
        return None

    cmd = f"git clone {url}"
    if extra_args:
        cmd += f" {extra_args}"
    return cmd
