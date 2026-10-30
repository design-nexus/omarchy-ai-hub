"""Helpers shared by the usage scanners."""
from __future__ import annotations

import datetime as dt
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


def format_hours(hours: float) -> str:
    """45m, 2.5h, 1d 4h."""
    if hours <= 0:
        return "0m"
    if hours < 1.0:
        return f"{max(1, round(hours * 60))}m"
    if hours < 24.0:
        return f"{hours:.1f}h"
    days = int(hours // 24)
    rem_h = int(round(hours % 24))
    if rem_h >= 24:
        days, rem_h = days + 1, 0
    return f"{days}d {rem_h}h" if rem_h > 0 else f"{days}d"


def parse_time(value: str) -> dt.datetime | None:
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def bucket_forecast(remaining_pct: float, burn_per_hour: float, resets_at: str) -> tuple[str, str, str]:
    """(burn text, forecast text, status) for one quota bucket."""
    reset = parse_time(resets_at) if resets_at else None
    if reset is None:
        return "", "", "stable"
    hours_left = (reset - dt.datetime.now(dt.timezone.utc)).total_seconds() / 3600.0
    if hours_left <= 0:
        # The window has rolled over since these numbers were fetched.
        return "", "Reset since last update", "stale"
    burn = f"{burn_per_hour:.1f}%/h" if burn_per_hour > 0 else ""
    if burn_per_hour <= 0.001:
        return burn, "Paced to reset", "stable"
    hours_to_empty = remaining_pct / burn_per_hour
    if hours_to_empty < hours_left:
        return burn, f"Depletes in ~{format_hours(hours_to_empty)} (before reset)", "critical"
    at_reset = max(0.0, remaining_pct - burn_per_hour * hours_left)
    status = "warning" if at_reset < 15.0 else "safe"
    prefix = "Tight pace" if status == "warning" else "On pace"
    return burn, f"{prefix} · ~{at_reset:.0f}% at reset", status


def quota_burn_rates(provider: str, groups: list[dict]) -> dict[str, float]:
    """Each bucket's use in %/hour over the last 6 h, from a snapshot kept per run.

    Only the stretch since the bucket last refilled counts: across a reset the
    remaining share jumps up, which would otherwise cancel the real burn.
    """
    path = CACHE_ROOT / provider / "quota_snapshots.json"
    try:
        snapshots = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(snapshots, dict):
            snapshots = {}
    except (OSError, ValueError):
        snapshots = {}
    now = time.time()
    rates: dict[str, float] = {}
    for group in groups:
        for bucket in group.get("buckets", []):
            bid = bucket.get("id") or bucket.get("name")
            if not bid:
                continue
            pct = float(bucket.get("remainingPercent", bucket.get("remainingFraction", 1.0) * 100))
            points = [p for p in snapshots.get(bid, []) if isinstance(p, list) and len(p) == 2 and now - p[0] < 6 * 3600]
            points.append([now, pct])
            snapshots[bid] = points
            start = len(points) - 1
            while start > 0 and points[start - 1][1] >= points[start][1] - 0.5:
                start -= 1
            span_h = (points[-1][0] - points[start][0]) / 3600.0
            drop = points[start][1] - points[-1][1]
            rates[bid] = drop / span_h if span_h >= 0.05 and drop > 0 else 0.0
    try:
        write_private(path, snapshots)
    except OSError:
        pass
    return rates


def apply_forecasts(provider: str, groups: list[dict]) -> list[dict]:
    """Add burn rate and forecast to every bucket; return the flat `limits` list."""
    rates = quota_burn_rates(provider, groups)
    limits = []
    for group in groups:
        for bucket in group.get("buckets", []):
            rate = rates.get(bucket.get("id") or bucket.get("name"), 0.0)
            burn, forecast, status = bucket_forecast(float(bucket.get("remainingPercent", 100)), rate, bucket.get("resetTime", ""))
            bucket.update({"burnRatePerHour": rate, "burnRateText": burn, "forecastText": forecast, "forecastStatus": status})
            limits.append({
                "label": bucket.get("label", "Limit"),
                "percent": float(bucket.get("usedPercent", 0)) / 100.0,
                "resetsAt": bucket.get("resetTime", ""),
            })
    return limits


def cache_age_iso(path: Path) -> str:
    """When a cache file was written, for showing how old served numbers are."""
    try:
        return dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat()
    except OSError:
        return ""


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
