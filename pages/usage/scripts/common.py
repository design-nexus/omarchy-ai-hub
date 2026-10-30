"""Helpers shared by the usage scanners."""
from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Callable

CACHE_ROOT = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "omarchy-ai-hub"


def write_private(path: Path, data) -> None:
    """Write JSON atomically, readable only by you."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)


class FetchGate:
    """When a provider's quota request last failed, so a lapsed sign-in or a
    dead network is retried every few minutes instead of on every refresh.
    A forced refresh (the panel's refresh button) always tries again."""

    RETRY_AFTER_SEC = 300

    def __init__(self, provider: str):
        self.path = CACHE_ROOT / provider / "quota_failure.json"

    def blocked(self, force: bool = False) -> str | None:
        """The last error, while it is recent enough not to retry yet."""
        if force:
            return None
        try:
            state = json.loads(self.path.read_text(encoding="utf-8"))
            if time.time() - float(state.get("at", 0)) < self.RETRY_AFTER_SEC:
                return str(state.get("error") or "Quota request failed")
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        return None

    def failed(self, error: str) -> None:
        try:
            write_private(self.path, {"at": time.time(), "error": error})
        except OSError:
            pass

    def succeeded(self) -> None:
        try:
            self.path.unlink()
        except OSError:
            pass


class LogCache:
    """What a scanner has already read of each append-only log, one cache file per log.

    An entry holds the byte offset parsed so far plus whatever the scanner
    accumulates from the lines before it; each run reads only what was
    appended since. A log that shrank was rewritten and is read again whole.
    """

    def __init__(self, provider: str, version: int):
        self.dir = CACHE_ROOT / provider / "logs"
        self.version = version
        self.live: set[str] = set()

    def _file(self, path: Path) -> Path:
        return self.dir / (hashlib.sha1(str(path).encode()).hexdigest() + ".json")

    def update(self, path: Path, blank: Callable[[], dict],
               parse: Callable[[dict, list[bytes], float], None]) -> dict | None:
        """The entry for `path`, once parse(entry, new_lines, mtime) has seen what was appended."""
        try:
            st = path.stat()
        except OSError:
            return None
        cache_file = self._file(path)
        self.live.add(cache_file.name)
        try:
            entry = json.loads(cache_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            entry = None
        if not isinstance(entry, dict) or entry.get("v") != self.version or st.st_size < entry.get("offset", 0):
            entry = dict(blank(), v=self.version, offset=0)
        if st.st_size > entry["offset"]:
            try:
                with path.open("rb") as handle:
                    handle.seek(entry["offset"])
                    data = handle.read(st.st_size - entry["offset"])
            except OSError:
                return None
            # A half-written last line waits for the next run.
            end = data.rfind(b"\n") + 1
            if end:
                parse(entry, data[:end].splitlines(), st.st_mtime)
                entry["offset"] += end
                try:
                    write_private(cache_file, entry)
                except OSError:
                    pass
        entry["mtime"] = st.st_mtime
        return entry

    def prune(self) -> None:
        """Drop the caches of logs that no longer exist. Call after visiting every log."""
        if not self.dir.exists():
            return
        for stale in self.dir.glob("*.json"):
            if stale.name not in self.live:
                try:
                    stale.unlink()
                except OSError:
                    pass
