"""LRU cache with TTL for suggestion caching."""

import hashlib
import time
from collections import OrderedDict
from typing import Any


class SuggestionCache:
    """In-memory LRU cache with per-entry TTL for command suggestions."""

    def __init__(self, max_size: int = 200, ttl_seconds: int = 300):
        self.max_size = max_size
        self.ttl_seconds = ttl_seconds
        self._cache: OrderedDict[str, tuple[str, float]] = OrderedDict()

    @staticmethod
    def _make_key(buffer: str, cwd: str, last_exit_code: int, git_branch: str) -> str:
        """Create a cache key from the relevant context fields."""
        raw = f"{buffer}|{cwd}|{last_exit_code}|{git_branch}"
        return hashlib.sha256(raw.encode()).hexdigest()[:32]

    def get(self, buffer: str, cwd: str = "", last_exit_code: int = 0,
            git_branch: str = "") -> str | None:
        """Look up a cached suggestion. Returns None on miss or expiry."""
        key = self._make_key(buffer, cwd, last_exit_code, git_branch)
        if key not in self._cache:
            return None

        suggestion, timestamp = self._cache[key]
        if time.time() - timestamp > self.ttl_seconds:
            del self._cache[key]
            return None

        # Move to end (most recently used)
        self._cache.move_to_end(key)
        return suggestion

    def put(self, buffer: str, suggestion: str, cwd: str = "",
            last_exit_code: int = 0, git_branch: str = "") -> None:
        """Store a suggestion in the cache."""
        if not suggestion:
            return

        key = self._make_key(buffer, cwd, last_exit_code, git_branch)

        if key in self._cache:
            self._cache.move_to_end(key)
        elif len(self._cache) >= self.max_size:
            self._cache.popitem(last=False)  # Evict oldest

        self._cache[key] = (suggestion, time.time())

    def clear(self) -> None:
        """Clear all cached entries."""
        self._cache.clear()

    @property
    def size(self) -> int:
        return len(self._cache)
