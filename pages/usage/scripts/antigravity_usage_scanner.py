#!/usr/bin/env python3
"""Query Antigravity CLI/IDE state, sqlite database, history, and transcripts to emit usage stats."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any


def default_base_dir() -> Path:
    return Path(os.environ.get("ANTIGRAVITY_DATA_DIR") or os.path.expanduser("~/.gemini/antigravity-cli"))


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def date_string(value: dt.date) -> str:
    return value.strftime("%Y-%m-%d")


def sanitize_plain_text(val: Any, max_len: int = 250) -> str:
    """Sanitize arbitrary strings to safe plain-text by stripping control chars and truncating."""
    if val is None:
        return ""
    text = str(val)
    # Remove null bytes and non-printable control characters
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", "", text)
    # Collapse whitespace and newlines to a single space
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_len]


def recent_date_strings() -> list[str]:
    today = dt.datetime.now().date()
    return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


_MS_EPOCH_THRESHOLD = 10_000_000_000  # Timestamps above this are assumed milliseconds


def normalize_timestamp_seconds(value: Any) -> float:
    """Normalize a timestamp value (epoch seconds or ms) to epoch seconds."""
    if value is None:
        return 0.0
    try:
        v = float(value)
        return v / 1000.0 if v > _MS_EPOCH_THRESHOLD else v
    except (TypeError, ValueError):
        return 0.0


def local_date_from_timestamp(value: Any) -> str:
    if value is None:
        return date_string(dt.datetime.now().date())
    if isinstance(value, (int, float)):
        try:
            seconds = normalize_timestamp_seconds(value)
            return date_string(dt.datetime.fromtimestamp(seconds).date())
        except Exception:
            return date_string(dt.datetime.now().date())
    raw = str(value).strip()
    if not raw:
        return date_string(dt.datetime.now().date())
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone()
        return date_string(parsed.date())
    except Exception:
        pass
    try:
        clean = raw.split(".")[0]
        parsed = dt.datetime.fromisoformat(clean)
        return date_string(parsed.date())
    except Exception:
        return date_string(dt.datetime.now().date())


def read_configured_model(base_dir: Path | None = None) -> str:
    """Read the user's default configured model from settings.json if available."""
    if base_dir:
        settings_file = base_dir / "settings.json"
        if settings_file.exists():
            try:
                with open(settings_file, "r", encoding="utf-8", errors="replace") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        m = data.get("model")
                        if m and isinstance(m, str) and m.strip():
                            return sanitize_plain_text(m.strip(), 80)
            except Exception:
                pass
    return "Gemini 3.8 Flash (High)"


def empty_result(base_dir: Path | None = None) -> dict[str, Any]:
    recent_dates = recent_date_strings()
    current_model = read_configured_model(base_dir)
    return {
        "schemaVersion": 1,
        "id": "antigravity",
        "name": "Antigravity",
        "ready": False,
        "active": False,
        "activeStatus": "Idle",
        "hasActiveSession": False,
        "hasLocalStats": False,
        "tierLabel": "Google DeepMind",
        "currentModel": current_model,
        "todayPrompts": 0,
        "todaySessions": 0,
        "todaySteps": 0,
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": [{"date": day, "messageCount": 0, "prompts": 0, "steps": 0} for day in recent_dates],
        "totalPrompts": 0,
        "totalSessions": 0,
        "totalSteps": 0,
        "activeSessions": [],
        "recentSessions": [],
        "toolUsage": {},
        "modelUsage": {},
        "modelList": [],
        "quotaGroups": [],
        "limits": [],
        "recentWorkspaces": [],
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": "",
        "quotaUpdatedMs": 0,
        "lastFullRefreshMs": 0,
        "usageStatusText": "No Antigravity data found",
        "authHelpText": "Run `agy` to start a session."
    }



def parse_history_file(history_path: Path, recent_dates: list[str]) -> tuple[dict[str, int], int, list[dict[str, Any]], Counter]:
    daily_prompts = {day: 0 for day in recent_dates}
    total_prompts = 0
    recent_prompts: list[dict[str, Any]] = []
    workspace_counter: Counter = Counter()

    if not history_path.exists():
        return daily_prompts, total_prompts, recent_prompts, workspace_counter

    try:
        with open(history_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    total_prompts += 1
                    ts = entry.get("timestamp")
                    day = local_date_from_timestamp(ts)
                    if day in daily_prompts:
                        daily_prompts[day] += 1
                    
                    ws = sanitize_plain_text(entry.get("workspace") or "", 300)
                    if ws:
                        workspace_counter[ws] += 1

                    recent_prompts.append({
                        "display": sanitize_plain_text(entry.get("display", ""), 200),
                        "workspace": ws,
                        "conversationId": sanitize_plain_text(entry.get("conversationId", ""), 100),
                        "type": sanitize_plain_text(entry.get("type", "prompt"), 50),
                        "timestamp": ts or 0,
                        "date": day
                    })
                except Exception:
                    continue
    except Exception:
        pass

    return daily_prompts, total_prompts, recent_prompts, workspace_counter


def get_flocked_inodes() -> set[int] | None:
    """Return set of inodes that have active FLOCK advisory write locks in /proc/locks."""
    try:
        locked = set()
        with open("/proc/locks", "r") as f:
            for line in f:
                parts = line.split()
                # Format: 24: FLOCK ADVISORY WRITE <pid> 00:1e:<inode> 0 EOF
                if len(parts) >= 6 and parts[1] == "FLOCK" and parts[3] == "WRITE":
                    dev_ino = parts[5].split(":")
                    if len(dev_ino) == 3:
                        locked.add(int(dev_ino[2]))
        return locked
    except Exception:
        return None


_STALE_LOCK_THRESHOLD_SECS = 48 * 3600  # 48 hours


def prune_stale_locks(presence_dir: Path) -> None:
    """Remove lock files older than 48h that are not held by any process (housekeeping)."""
    if not presence_dir.exists():
        return
    now = time.time()
    for p in presence_dir.glob("*.lock"):
        try:
            if now - p.stat().st_mtime < _STALE_LOCK_THRESHOLD_SECS:
                continue
            with open(p, "rb") as f:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    p.unlink(missing_ok=True)
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                except (BlockingIOError, OSError):
                    pass  # Still held — skip
        except (FileNotFoundError, OSError):
            pass


def parse_presence(presence_dir: Path) -> set[str]:
    """Return set of conversation IDs whose presence locks are actively held by running processes."""
    active_ids = set()
    if not presence_dir.exists():
        return active_ids

    flocked_inodes = get_flocked_inodes()
    for p in presence_dir.glob("*.lock"):
        cid = sanitize_plain_text(p.stem, 100)
        if not cid:
            continue
        try:
            with open(p, "rb") as f:
                try:
                    # Test lock using non-blocking shared lock (LOCK_SH).
                    # Running agy processes hold an exclusive write lock (LOCK_EX),
                    # so LOCK_SH will fail with BlockingIOError if and only if agy holds it.
                    # Multiple concurrent scanner processes (e.g. across multiple monitors)
                    # can acquire LOCK_SH simultaneously without blocking each other.
                    fcntl.flock(f.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                    # Succeeded in acquiring shared lock: no active process holds it (stale file)
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                except (BlockingIOError, PermissionError, OSError):
                    # An exclusive lock is held! Verify against /proc/locks if available
                    # to guard against any transient contention.
                    if flocked_inodes is not None:
                        try:
                            if p.stat().st_ino in flocked_inodes:
                                active_ids.add(cid)
                        except Exception:
                            active_ids.add(cid)
                    else:
                        active_ids.add(cid)
        except Exception:
            pass
    return active_ids


def kill_session(cid: str, base_dir: Path) -> bool:
    """Find process holding lock for conversationId and terminate it cleanly."""
    import signal
    pids = set()
    lock_file = base_dir / "presence" / f"{cid}.lock"

    # 1. Fast O(1) PID resolution from /proc/locks by inode
    if lock_file.exists():
        try:
            target_ino = lock_file.stat().st_ino
            with open("/proc/locks", "r") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 6 and parts[1] == "FLOCK":
                        dev_ino = parts[5].split(":")
                        if len(dev_ino) == 3 and int(dev_ino[2]) == target_ino:
                            p = int(parts[4])
                            if p != os.getpid():
                                pids.add(p)
        except Exception:
            pass

    # 2. Fallback to /proc/*/fd/* scan if /proc/locks did not yield PIDs
    if not pids:
        target_lock = f"presence/{cid}.lock"
        for fd_path in glob.glob("/proc/[0-9]*/fd/*"):
            try:
                target = os.readlink(fd_path)
                if target_lock in target:
                    p = int(fd_path.split("/")[2])
                    if p != os.getpid():
                        pids.add(p)
            except Exception:
                pass

    killed_any = False
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
            killed_any = True
        except Exception:
            pass

    # Clean up lock file if now released
    lock_file = base_dir / "presence" / f"{cid}.lock"
    if lock_file.exists():
        try:
            with open(lock_file, "rb") as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            lock_file.unlink(missing_ok=True)
        except Exception:
            pass

    return killed_any


def check_session_working(cid: str, base_dir: Path) -> bool:
    """Check whether a session is actively executing/thinking or waiting for user input."""
    # 1. Check sqlite database steps status
    db_path = base_dir / "conversations" / f"{cid}.db"
    if db_path.exists():
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.3) as conn:
                cur = conn.cursor()
                cur.execute("SELECT status FROM steps ORDER BY idx DESC LIMIT 1")
                row = cur.fetchone()
                if row and row[0] == 2:  # Status 2 = in progress / running
                    return True
        except Exception:
            pass

    # 2. Check transcript.jsonl tail
    tpath = base_dir / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
    if tpath.exists():
        try:
            with open(tpath, "rb") as f:
                f.seek(max(0, tpath.stat().st_size - 4096))
                lines = f.readlines()
                if lines:
                    last_line = lines[-1].decode("utf-8", errors="replace").strip()
                    if not last_line and len(lines) > 1:
                        last_line = lines[-2].decode("utf-8", errors="replace").strip()
                    if last_line:
                        data = json.loads(last_line)
                        step_type = data.get("type", "")
                        if step_type in ("USER_INPUT", "GENERIC"):
                            return True
                        if step_type == "PLANNER_RESPONSE" and data.get("tool_calls"):
                            return True
        except Exception:
            pass

    return False


def parse_transcripts(
    brain_dir: Path,
    today_str: str = "",
    recent_dates: list[str] | None = None,
    default_model: str = "Gemini 3.8 Flash (High)",
    base_dir: Path | None = None
) -> tuple[Counter, dict[str, dict[str, Any]], list[dict[str, Any]], str]:
    tool_counter: Counter = Counter()
    models_stats: dict[str, dict[str, Any]] = {}
    latest_model = default_model

    if not brain_dir.exists():
        return tool_counter, models_stats, [], latest_model

    recent_dates_set = set(recent_dates) if recent_dates else set()

    # Load incremental transcript stats cache
    cache_file = (base_dir / "cache" / "transcript_stats_cache.json") if base_dir else None
    cache: dict[str, Any] = {}
    if cache_file and cache_file.exists():
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    cache = loaded
        except Exception:
            cache = {}

    cache_dirty = False

    try:
        transcript_files = list(brain_dir.glob("*/.system_generated/logs/transcript.jsonl"))
        transcript_files.sort(key=lambda x: x.stat().st_mtime, reverse=True)

        found_latest_model = False

        for p in transcript_files:
            conv_id = sanitize_plain_text(p.parent.parent.parent.name, 100)
            file_key = str(p)
            try:
                st = p.stat()
                mtime = st.st_mtime
                size = st.st_size
            except Exception:
                continue

            cached_entry = cache.get(file_key)
            if (
                cached_entry
                and cached_entry.get("mtime") == mtime
                and cached_entry.get("size") == size
            ):
                entry_tools = cached_entry.get("tools", {})
                entry_model = cached_entry.get("model", default_model)
                steps_by_date = cached_entry.get("steps_by_date", {})
                prompts_by_date = cached_entry.get("prompts_by_date", {})
                total_steps = cached_entry.get("total_steps", 0)
                total_prompts = cached_entry.get("total_prompts", 0)
            else:
                entry_tools = Counter()
                entry_model = default_model
                steps_by_date = Counter()
                prompts_by_date = Counter()
                total_steps = 0
                total_prompts = 0

                try:
                    with open(p, "r", encoding="utf-8", errors="replace") as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                step = json.loads(line)
                            except Exception:
                                continue

                            content = step.get("content") or ""
                            created_at = step.get("created_at") or ""
                            step_day = local_date_from_timestamp(created_at)

                            # Model detection
                            if "Model Selection" in content:
                                match = re.search(r"Model Selection` from .*? to (.+?)\.\s*(?:No need|$)", content)
                                if match:
                                    m = sanitize_plain_text(match.group(1).strip().replace("`", ""), 80)
                                    if m and len(m) < 60 and not m.lower().startswith("comment"):
                                        entry_model = m

                            total_steps += 1
                            steps_by_date[step_day] += 1

                            if step.get("type") == "USER_INPUT":
                                total_prompts += 1
                                prompts_by_date[step_day] += 1

                            # Tool call detection
                            for tc in step.get("tool_calls", []):
                                fn_name = ""
                                if isinstance(tc, dict):
                                    fn_name = tc.get("function", {}).get("name") or tc.get("name") or ""
                                fn_name = sanitize_plain_text(fn_name, 80)
                                if fn_name:
                                    entry_tools[fn_name] += 1
                except Exception:
                    continue

                cache[file_key] = {
                    "mtime": mtime,
                    "size": size,
                    "model": entry_model,
                    "tools": dict(entry_tools),
                    "steps_by_date": dict(steps_by_date),
                    "prompts_by_date": dict(prompts_by_date),
                    "total_steps": total_steps,
                    "total_prompts": total_prompts
                }
                cache_dirty = True

            # Track latest model from most recently modified file
            if not found_latest_model and entry_model:
                latest_model = entry_model
                found_latest_model = True

            # Aggregate tool counts
            for fn_name, cnt in entry_tools.items():
                tool_counter[fn_name] += cnt

            # Aggregate model stats
            if entry_model not in models_stats:
                models_stats[entry_model] = {
                    "name": entry_model,
                    "prompts": 0,
                    "steps": 0,
                    "todayPrompts": 0,
                    "todaySteps": 0,
                    "weekPrompts": 0,
                    "weekSteps": 0,
                    "sessions": set(),
                    "todaySessions": set(),
                    "weekSessions": set()
                }

            models_stats[entry_model]["steps"] += total_steps
            today_s = steps_by_date.get(today_str, 0)
            models_stats[entry_model]["todaySteps"] += today_s
            week_s = sum(steps_by_date.get(d, 0) for d in recent_dates_set)
            models_stats[entry_model]["weekSteps"] += week_s

            models_stats[entry_model]["prompts"] += total_prompts
            today_p = prompts_by_date.get(today_str, 0)
            models_stats[entry_model]["todayPrompts"] += today_p
            week_p = sum(prompts_by_date.get(d, 0) for d in recent_dates_set)
            models_stats[entry_model]["weekPrompts"] += week_p

            models_stats[entry_model]["sessions"].add(conv_id)
            if today_s > 0 or today_p > 0:
                models_stats[entry_model]["todaySessions"].add(conv_id)
            if week_s > 0 or week_p > 0:
                models_stats[entry_model]["weekSessions"].add(conv_id)

    except Exception:
        pass

    # Save cache if updated
    if cache_dirty and cache_file:
        try:
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            tmp_c = cache_file.with_suffix(".tmp")
            with open(tmp_c, "w", encoding="utf-8") as f:
                json.dump(cache, f)
            tmp_c.replace(cache_file)
        except Exception:
            pass

    # Convert sets to counts and sort models
    formatted_models: dict[str, dict[str, Any]] = {}
    model_list: list[dict[str, Any]] = []
    total_model_prompts = sum(d["prompts"] for d in models_stats.values()) or 1

    for m, data in sorted(models_stats.items(), key=lambda item: item[1]["prompts"] + item[1]["steps"], reverse=True):
        clean_model_name = sanitize_plain_text(m, 80)
        p_count = data["prompts"]
        s_count = data["steps"]
        share_frac = round(p_count / max(1, total_model_prompts), 4)
        share_pct = round(share_frac * 100, 1)

        m_lower = clean_model_name.lower()
        if "claude" in m_lower:
            m_color = "#D97757"
        elif "gpt" in m_lower:
            m_color = "#10A37F"
        elif "pro" in m_lower or "high" in m_lower:
            m_color = "#A855F7"
        else:
            m_color = "#38BDF8"

        entry = {
            "name": clean_model_name,
            "prompts": p_count,
            "steps": s_count,
            "todayPrompts": data.get("todayPrompts", 0),
            "todaySteps": data.get("todaySteps", 0),
            "todaySessions": len(data.get("todaySessions", set())),
            "weekPrompts": data.get("weekPrompts", 0),
            "weekSteps": data.get("weekSteps", 0),
            "weekSessions": len(data.get("weekSessions", set())),
            "sessions": len(data["sessions"]),
            "shareFraction": share_frac,
            "sharePercent": share_pct,
            "color": m_color,
            "inputTokens": 0,
            "outputTokens": 0
        }
        formatted_models[clean_model_name] = entry
        model_list.append(entry)

    return tool_counter, formatted_models, model_list, latest_model


def format_hours_duration(hours: float) -> str:
    """Format duration in hours to compact human readable string (e.g. 45m, 2.5h, 1d 4h)."""
    if hours <= 0:
        return "0m"
    if hours < 1.0:
        return f"{max(1, round(hours * 60))}m"
    if hours < 24.0:
        return f"{hours:.1f}h"
    days = int(hours // 24)
    rem_h = int(round(hours % 24))
    if rem_h >= 24:
        days += 1
        rem_h = 0
    return f"{days}d {rem_h}h" if rem_h > 0 else f"{days}d"


def compute_bucket_forecast(rem_pct: float, burn_rate: float, reset_time_str: str) -> tuple[str, str, str]:
    """Compute (burn_rate_text, forecast_text, forecast_status) for a quota bucket.

    forecast_status: 'stable', 'safe', 'warning', 'critical'
    """
    burn_text = f"{burn_rate:.1f}%/h" if burn_rate >= 0.1 else ""

    hours_until_reset = None
    if reset_time_str:
        try:
            reset_dt = dt.datetime.fromisoformat(reset_time_str.replace("Z", "+00:00"))
            now_dt = dt.datetime.now(dt.timezone.utc)
            hours_until_reset = max(0.0, (reset_dt - now_dt).total_seconds() / 3600.0)
        except Exception:
            hours_until_reset = None

    # If quota consumption is negligible (< 0.1%/hour)
    if burn_rate < 0.1:
        return "", "Paced to reset", "stable"

    hours_to_depletion = rem_pct / max(0.01, burn_rate)

    if hours_until_reset is not None:
        projected_at_reset = rem_pct - (burn_rate * hours_until_reset)
        if projected_at_reset >= 15.0:
            forecast_text = f"On pace · ~{round(projected_at_reset)}% at reset"
            status = "safe"
        elif projected_at_reset > 0.0:
            forecast_text = f"Tight pace · ~{round(projected_at_reset)}% at reset"
            status = "warning"
        else:
            forecast_text = f"Depletes in ~{format_hours_duration(hours_to_depletion)} (before reset)"
            status = "critical"
    else:
        if hours_to_depletion > 12.0:
            forecast_text = f"~{format_hours_duration(hours_to_depletion)} quota left"
            status = "safe"
        elif hours_to_depletion > 3.0:
            forecast_text = f"~{format_hours_duration(hours_to_depletion)} quota left"
            status = "warning"
        else:
            forecast_text = f"Depletes in ~{format_hours_duration(hours_to_depletion)}"
            status = "critical"

    return burn_text, forecast_text, status


def update_quota_snapshots(base_dir: Path, raw_groups: list[dict[str, Any]]) -> dict[str, float]:
    """Record timestamped snapshot of quota fractions and calculate hourly burn rates per bucket."""
    now = time.time()
    snapshots_path = base_dir / "cache" / "quota_snapshots.json"
    snapshots_path.parent.mkdir(parents=True, exist_ok=True)

    current_snapshot = {}
    for g in raw_groups:
        for b in g.get("buckets", []):
            b_id = sanitize_plain_text(b.get("id", ""), 50)
            if b_id:
                rem_frac = float(b.get("remaining_fraction", 1.0))
                current_snapshot[b_id] = round(min(1.0, max(0.0, rem_frac)), 4)

    if not current_snapshot:
        return {}

    snapshots = []
    if snapshots_path.exists():
        try:
            with open(snapshots_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    # Retain snapshots from the last 48 hours
                    cutoff = now - 48 * 3600
                    snapshots = [s for s in data if isinstance(s, dict) and s.get("timestamp", 0) > cutoff]
        except Exception:
            snapshots = []

    # If the last snapshot is very recent (< 60s), update it in place; otherwise append
    if snapshots and (now - snapshots[-1].get("timestamp", 0) < 60):
        snapshots[-1]["buckets"] = current_snapshot
    else:
        snapshots.append({"timestamp": now, "buckets": current_snapshot})

    # Save snapshots (capped at 120 items)
    try:
        tmp_snap = snapshots_path.with_suffix(".tmp")
        with open(tmp_snap, "w", encoding="utf-8") as f:
            json.dump(snapshots[-120:], f)
        tmp_snap.replace(snapshots_path)
    except Exception:
        pass

    # Compute burn rate per bucket (% used per hour)
    burn_rates: dict[str, float] = {}
    for b_id, current_frac in current_snapshot.items():
        baseline_snap = None
        best_delta_t = 0.0

        for s in reversed(snapshots[:-1]):
            t_diff = now - s.get("timestamp", 0)
            if t_diff < 180:  # less than 3 minutes, too noisy
                continue
            prev_frac = s.get("buckets", {}).get(b_id)
            if prev_frac is None:
                continue
            # If a reset occurred (previous remaining was noticeably lower than current), stop traversing back
            if prev_frac < current_frac - 0.05:
                break
            baseline_snap = s
            best_delta_t = t_diff
            if 3600 <= t_diff <= 7200:  # ideal ~1 hour baseline
                break

        burn_rate = 0.0
        if baseline_snap and best_delta_t >= 300:  # minimum 5 minutes of separation
            prev_frac = baseline_snap.get("buckets", {}).get(b_id, current_frac)
            frac_used = max(0.0, prev_frac - current_frac)
            hours = best_delta_t / 3600.0
            if hours > 0:
                burn_rate = round((frac_used * 100.0) / hours, 2)

        burn_rates[b_id] = burn_rate

    return burn_rates


def trigger_bg_quota_refresh(base_dir: Path, agy_bin: str) -> None:
    """Launch detached background process to refresh quota cache without stalling scans."""
    flag_file = base_dir / "cache" / "quota_refresh.flag"
    now = time.time()
    if flag_file.exists():
        try:
            if now - flag_file.stat().st_mtime < 30:
                return
        except Exception:
            pass

    try:
        flag_file.parent.mkdir(parents=True, exist_ok=True)
        flag_file.touch()
        script_path = str(Path(__file__).resolve())
        subprocess.Popen(
            [sys.executable, script_path, "--refresh-quota-bg", str(base_dir)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
    except Exception:
        pass


def bg_refresh_quota(base_dir: Path) -> None:
    """Worker function executed in background to fetch quota and update snapshots."""
    cache_path = base_dir / "cache" / "quota_usage_cache.json"
    flag_file = base_dir / "cache" / "quota_refresh.flag"
    agy_bin = shutil.which("agy") or str(Path.home() / ".local/bin/agy")
    try:
        res = subprocess.run(
            [agy_bin, "-p", "/usage", "--output-format", "json"],
            capture_output=True,
            text=True,
            timeout=15
        )
        if res.returncode == 0 and res.stdout.strip():
            payload = json.loads(res.stdout)
            cmd_data = payload.get("command", {}).get("data", {})
            if isinstance(cmd_data, dict) and "groups" in cmd_data and len(cmd_data["groups"]) > 0:
                tmp_cache = cache_path.with_suffix(".tmp")
                with open(tmp_cache, "w", encoding="utf-8") as f:
                    json.dump(cmd_data, f)
                tmp_cache.replace(cache_path)
                update_quota_snapshots(base_dir, cmd_data.get("groups", []))
    except Exception:
        pass
    finally:
        try:
            flag_file.unlink(missing_ok=True)
        except Exception:
            pass


def fetch_agy_usage_quota(base_dir: Path, force: bool = False) -> dict[str, Any]:
    """Fetch real-time quota information via `agy -p /usage --output-format json` with caching."""
    cache_path = base_dir / "cache" / "quota_usage_cache.json"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    agy_bin = shutil.which("agy") or str(Path.home() / ".local/bin/agy")

    # 1. Read from cache if not forcing refresh
    if not force and cache_path.exists():
        try:
            mtime = cache_path.stat().st_mtime
            age = time.time() - mtime
            with open(cache_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "groups" in data and len(data["groups"]) > 0:
                    # If cache is older than 180s, trigger detached background refresh
                    if age > 180:
                        trigger_bg_quota_refresh(base_dir, agy_bin)
                    return data
        except Exception:
            pass

    # 2. Synchronous query (when user explicitly requests force refresh or no cache exists)
    try:
        res = subprocess.run(
            [agy_bin, "-p", "/usage", "--output-format", "json"],
            capture_output=True,
            text=True,
            timeout=12
        )
        if res.returncode == 0 and res.stdout.strip():
            payload = json.loads(res.stdout)
            cmd_data = payload.get("command", {}).get("data", {})
            if isinstance(cmd_data, dict) and "groups" in cmd_data and len(cmd_data["groups"]) > 0:
                try:
                    tmp_cache = cache_path.with_suffix(".tmp")
                    with open(tmp_cache, "w", encoding="utf-8") as f:
                        json.dump(cmd_data, f)
                    tmp_cache.replace(cache_path)
                except Exception:
                    pass
                return cmd_data
    except Exception:
        pass

    # 3. Fallback to stale cache if present
    if cache_path.exists():
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "groups" in data:
                    return data
        except Exception:
            pass

    return {}


def bucket_order(bucket: dict[str, Any]) -> int:
    """5-hour window before weekly, matching the other agents."""
    return 1 if bucket.get("label") == "Weekly Limit" else 0


def format_quota_groups(raw_data: dict[str, Any], base_dir: Path | None = None) -> list[dict[str, Any]]:
    """Format agy /usage group and bucket metrics for QML consumption with burn rate and forecast."""
    groups = raw_data.get("groups", [])
    burn_rates = {}
    if base_dir and groups:
        burn_rates = update_quota_snapshots(base_dir, groups)

    if not groups:
        # Graceful default structure when offline / before first query
        defaults = [
            {
                "name": "Gemini Models",
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "color": "#38BDF8",
                "buckets": [
                    {
                        "id": "gemini-weekly",
                        "name": "Weekly Limit Remaining",
                        "label": "Weekly Limit",
                        "window": "weekly",
                        "remainingFraction": 1.0,
                        "remainingPercent": 100,
                        "usedPercent": 0,
                        "resetTime": "",
                        "description": "Weekly rolling quota",
                        "color": "#38BDF8",
                        "burnRatePerHour": 0.0,
                        "burnRateText": "",
                        "forecastText": "Paced to reset",
                        "forecastStatus": "stable"
                    },
                    {
                        "id": "gemini-5h",
                        "name": "Five Hour Limit Remaining",
                        "label": "5-Hour Limit",
                        "window": "5h",
                        "remainingFraction": 1.0,
                        "remainingPercent": 100,
                        "usedPercent": 0,
                        "resetTime": "",
                        "description": "5-hour burst window",
                        "color": "#38BDF8",
                        "burnRatePerHour": 0.0,
                        "burnRateText": "",
                        "forecastText": "Paced to reset",
                        "forecastStatus": "stable"
                    }
                ]
            },
            {
                "name": "Claude and GPT models",
                "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                "color": "#D97757",
                "buckets": [
                    {
                        "id": "3p-weekly",
                        "name": "Weekly Limit Remaining",
                        "label": "Weekly Limit",
                        "window": "weekly",
                        "remainingFraction": 1.0,
                        "remainingPercent": 100,
                        "usedPercent": 0,
                        "resetTime": "",
                        "description": "Weekly rolling quota",
                        "color": "#D97757",
                        "burnRatePerHour": 0.0,
                        "burnRateText": "",
                        "forecastText": "Paced to reset",
                        "forecastStatus": "stable"
                    },
                    {
                        "id": "3p-5h",
                        "name": "Five Hour Limit Remaining",
                        "label": "5-Hour Limit",
                        "window": "5h",
                        "remainingFraction": 1.0,
                        "remainingPercent": 100,
                        "usedPercent": 0,
                        "resetTime": "",
                        "description": "5-hour burst window",
                        "color": "#D97757",
                        "burnRatePerHour": 0.0,
                        "burnRateText": "",
                        "forecastText": "Paced to reset",
                        "forecastStatus": "stable"
                    }
                ]
            }
        ]
        for g in defaults:
            g["buckets"].sort(key=bucket_order)
        return defaults

    formatted = []
    for g in groups:
        g_name = sanitize_plain_text(g.get("name", "Model Group"), 80)
        is_claude = "claude" in g_name.lower() or "gpt" in g_name.lower()
        g_color = "#D97757" if is_claude else "#38BDF8"

        buckets = []
        for b in g.get("buckets", []):
            b_id = sanitize_plain_text(b.get("id", ""), 50)
            b_name = sanitize_plain_text(b.get("name", "Limit"), 100)
            b_win = sanitize_plain_text(b.get("window", ""), 20)
            rem_frac = float(b.get("remaining_fraction", 1.0))
            rem_frac = min(1.0, max(0.0, rem_frac))
            rem_pct = min(100, max(0, round(rem_frac * 100)))
            used_pct = 100 - rem_pct
            reset_time = sanitize_plain_text(b.get("reset_time", ""), 60)

            label = "Weekly Limit" if "weekly" in b_win.lower() or "weekly" in b_name.lower() else "5-Hour Limit"

            burn_rate = burn_rates.get(b_id, 0.0)
            burn_text, forecast_text, forecast_status = compute_bucket_forecast(rem_pct, burn_rate, reset_time)

            buckets.append({
                "id": b_id,
                "name": b_name,
                "label": label,
                "window": b_win,
                "remainingFraction": round(rem_frac, 4),
                "remainingPercent": rem_pct,
                "usedPercent": used_pct,
                "resetTime": reset_time,
                "description": sanitize_plain_text(b.get("description", ""), 250),
                "color": g_color,
                "burnRatePerHour": burn_rate,
                "burnRateText": burn_text,
                "forecastText": forecast_text,
                "forecastStatus": forecast_status
            })

        buckets.sort(key=bucket_order)
        formatted.append({
            "name": g_name,
            "description": sanitize_plain_text(g.get("description", ""), 250),
            "color": g_color,
            "buckets": buckets
        })
    return formatted


def check_and_send_quota_notifications(
    base_dir: Path,
    quota_groups: list[dict[str, Any]],
    threshold_pct: int = 15,
) -> None:
    """Send unified desktop notification when model quota drops below threshold.

    Guarantees:
    1. Concurrency-safe: Uses non-blocking flock on a dedicated lock file so only ONE
       monitor process can check or send at a time; concurrent monitor bars exit immediately.
    2. No recurring spam: Tracks quota state on disk. Once notified for a low-quota event,
       does NOT re-notify every 2 hours while quota sits at 0%. Only re-notifies if:
       - Quota replenished above threshold and drops again, OR
       - Quota escalates from warning (>5%) to critical (<=5%) with at least 1h separation.
    3. Multi-bucket consolidation: Consolidates all low buckets in the same model group
       into a single notification.
    """
    if not quota_groups:
        return

    cache_dir = base_dir / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    lock_path = cache_dir / "quota_notification.lock"
    state_path = cache_dir / "quota_notification_state.json"

    # Non-blocking lock: if another monitor process is currently in this critical section, exit immediately
    lock_fd = None
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError):
        if lock_fd:
            try:
                lock_fd.close()
            except Exception:
                pass
        return

    try:
        now = time.time()
        state_data: dict[str, dict[str, Any]] = {}
        if state_path.exists():
            try:
                with open(state_path, "r", encoding="utf-8") as f:
                    d = json.load(f)
                    if isinstance(d, dict):
                        state_data = d
            except Exception:
                state_data = {}

        modified = False

        for group in quota_groups:
            g_name = group.get("name") or "Model Group"
            buckets = group.get("buckets") or []
            if not buckets:
                continue

            low_buckets = []
            min_pct = 100
            for b in buckets:
                rem_pct = b.get("remainingPercent")
                if rem_pct is None:
                    rem_frac = b.get("remainingFraction", 1.0)
                    rem_pct = round(rem_frac * 100)
                if rem_pct <= threshold_pct:
                    label = b.get("label") or b.get("name") or "Limit"
                    low_buckets.append(f"{label} ({rem_pct}%)")
                    min_pct = min(min_pct, rem_pct)

            group_state = state_data.get(g_name, {})
            was_low = bool(group_state.get("alert_active", False))
            last_notified_pct = group_state.get("last_notified_pct", 100)
            last_notified_time = float(group_state.get("last_notified_time", 0.0))

            if not low_buckets:
                # Quota is healthy (above threshold)
                if was_low:
                    # Quota replenished! Reset state so future drops trigger an alert
                    group_state["alert_active"] = False
                    group_state["last_notified_pct"] = 100
                    state_data[g_name] = group_state
                    modified = True
                continue

            # Quota is currently low
            should_notify = False
            if not was_low:
                # First time dropping below threshold
                should_notify = True
            elif min_pct <= 5 and last_notified_pct > 5 and (now - last_notified_time > 3600):
                # Escalation from warning (>5%) to critical (<=5%)
                should_notify = True

            if should_notify:
                headline = f"Antigravity Quota Low ({min_pct}% remaining)"
                details = f"{g_name}: {', '.join(low_buckets)} remaining."
                urgency = "critical" if min_pct <= 5 else "normal"

                cmd = [
                    "omarchy-notification-send",
                    "--app-name", "antigravity-usage",
                    "-u", urgency,
                    "-g", "󰢌",
                    headline,
                    details
                ]

                try:
                    subprocess.run(cmd, capture_output=True, timeout=4)
                    group_state["alert_active"] = True
                    group_state["last_notified_pct"] = min_pct
                    group_state["last_notified_time"] = now
                    state_data[g_name] = group_state
                    modified = True
                except Exception:
                    pass
            elif not was_low:
                # In case notification delivery failed, mark active to avoid tight retry loop
                group_state["alert_active"] = True
                state_data[g_name] = group_state
                modified = True

        if modified:
            try:
                tmp_state = state_path.with_suffix(".tmp")
                with open(tmp_state, "w", encoding="utf-8") as f:
                    json.dump(state_data, f, indent=2)
                tmp_state.replace(state_path)
            except Exception:
                pass
    finally:
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            lock_fd.close()
        except Exception:
            pass


def pb_fields(buf: bytes):
    """Yield (field, value) for one protobuf message; nested messages stay bytes."""
    i, n = 0, len(buf)
    def varint():
        nonlocal i
        shift = result = 0
        while True:
            b = buf[i]
            i += 1
            result |= (b & 0x7F) << shift
            if not b & 0x80:
                return result
            shift += 7
    while i < n:
        key = varint()
        field, wire = key >> 3, key & 7
        if wire == 0:
            yield field, varint()
        elif wire == 2:
            size = varint()
            yield field, buf[i:i + size]
            i += size
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        else:
            return  # groups/unknown: stop rather than misparse


def today_token_usage(conversations_dir: Path, today: dt.date) -> int:
    """Tokens used today, from each conversation's step metadata.

    A model-response step's metadata records when it ran (field 1, seconds)
    and a usage block (field 9): 2 = uncached input, 5 = cached input,
    3 = output (thinking + response). Only databases written today are read.
    """
    if not conversations_dir.exists():
        return 0
    start = dt.datetime.combine(today, dt.time()).timestamp()
    total = 0
    for db in conversations_dir.glob("*.db"):
        try:
            wal = db.with_name(db.name + "-wal")
            mtime = max(db.stat().st_mtime, wal.stat().st_mtime if wal.exists() else 0)
            if mtime < start:
                continue
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
            try:
                rows = conn.execute("SELECT metadata FROM steps WHERE metadata IS NOT NULL").fetchall()
            finally:
                conn.close()
        except (OSError, sqlite3.Error):
            continue
        for (meta,) in rows:
            try:
                fields = dict(pb_fields(meta))
                when, usage = fields.get(1), fields.get(9)
                if not isinstance(when, bytes) or not isinstance(usage, bytes):
                    continue
                if dict(pb_fields(when)).get(1, 0) < start:
                    continue
                u = dict(pb_fields(usage))
                total += sum(v for k, v in u.items() if k in (2, 3, 5) and isinstance(v, int))
            except (IndexError, TypeError):
                continue
    return total


def scan(base_dir: Path, force: bool = False, alert_threshold: int | None = None) -> dict[str, Any]:
    if not base_dir.exists():
        return empty_result(base_dir)

    # Deduplicate concurrent scans across multi-monitor setups (TTL: 1.5s)
    scan_cache_path = base_dir / "cache" / "scanner_cache.json"
    if not force and scan_cache_path.exists():
        try:
            mtime = scan_cache_path.stat().st_mtime
            if time.time() - mtime < 1.5:
                with open(scan_cache_path, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                    if isinstance(cached, dict) and cached.get("ready"):
                        if alert_threshold is not None:
                            check_and_send_quota_notifications(base_dir, cached.get("quotaGroups", []), threshold_pct=alert_threshold)
                        return cached
        except Exception:
            pass

    db_path = base_dir / "conversation_summaries.db"
    history_path = base_dir / "history.jsonl"
    presence_dir = base_dir / "presence"
    brain_dir = base_dir / "brain"

    today_date = dt.datetime.now().date()
    today_str = date_string(today_date)
    recent_dates = recent_date_strings()

    # 0. Read user configured default model from settings.json
    configured_model = read_configured_model(base_dir)

    # 1. Parse Presence Locks (prune stale ones first as housekeeping)
    prune_stale_locks(presence_dir)
    active_lock_ids = parse_presence(presence_dir)

    # 2. Parse History JSONL
    daily_prompts, total_prompts_hist, recent_prompts, ws_counter = parse_history_file(history_path, recent_dates)

    # 3. Parse Transcripts for Tool Calls, Models & Model List (cached & incremental)
    tool_counter, model_usage_dict, model_list, latest_model = parse_transcripts(
        brain_dir, today_str, recent_dates, default_model=configured_model, base_dir=base_dir
    )

    # 4. Fetch real quota data from agy CLI /usage
    raw_quota = fetch_agy_usage_quota(base_dir, force=force)
    quota_groups = format_quota_groups(raw_quota, base_dir=base_dir)

    if alert_threshold is not None:
        check_and_send_quota_notifications(base_dir, quota_groups, threshold_pct=alert_threshold)

    # 5. Build Unified Session Registry
    conv_map: dict[str, dict[str, Any]] = {}

    # (a) Build conv_map from already-parsed history prompts (avoids re-reading history.jsonl)
    for prompt in recent_prompts:
        cid = prompt.get("conversationId", "")
        if not cid:
            continue
        # Normalize all timestamps to epoch seconds for consistent comparisons
        ts_sec = normalize_timestamp_seconds(prompt.get("timestamp", 0))
        display = prompt.get("display", "")
        ws = prompt.get("workspace", "")
        if cid not in conv_map:
            conv_map[cid] = {
                "conversationId": cid,
                "firstPrompt": display,
                "lastPrompt": display,
                "workspace": ws,
                "timestamp": ts_sec,
                "stepCount": 0,
                "agentName": "Antigravity"
            }
        else:
            if display:
                conv_map[cid]["lastPrompt"] = display
                if not conv_map[cid].get("firstPrompt"):
                    conv_map[cid]["firstPrompt"] = display
            conv_map[cid]["timestamp"] = max(conv_map[cid]["timestamp"], ts_sec)
            if ws:
                conv_map[cid]["workspace"] = ws

    # (b) Inspect conversations/*.db for step counts and file modification time
    conv_dir = base_dir / "conversations"
    if conv_dir.exists():
        try:
            for db_file in conv_dir.glob("*.db"):
                cid = sanitize_plain_text(db_file.stem, 100)
                if not cid:
                    continue
                mtime = db_file.stat().st_mtime
                step_count = 0
                try:
                    with sqlite3.connect(f"file:{db_file}?mode=ro", uri=True, timeout=0.2) as conn:
                        cur = conn.cursor()
                        cur.execute("SELECT count(*) FROM steps")
                        row = cur.fetchone()
                        if row:
                            step_count = int(row[0] or 0)
                except Exception:
                    pass

                if cid not in conv_map:
                    conv_map[cid] = {
                        "conversationId": cid,
                        "firstPrompt": f"Session {cid[:8]}",
                        "lastPrompt": "Session",
                        "workspace": "",
                        "timestamp": mtime,
                        "stepCount": step_count,
                        "agentName": "Antigravity"
                    }
                else:
                    conv_map[cid]["stepCount"] = max(conv_map[cid].get("stepCount", 0), step_count)
                # All timestamps are now epoch seconds — compare directly
                conv_map[cid]["mtime"] = max(conv_map[cid].get("timestamp", 0), mtime)
        except Exception:
            pass

    # (c) Check legacy conversation_summaries.db if it has entries
    if db_path.exists():
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True, timeout=1) as conn:
                conn.row_factory = sqlite3.Row
                cursor = conn.cursor()
                cursor.execute("""
                    SELECT conversation_id, title, preview, step_count, last_modified_time,
                           workspace_uris, agent_name
                    FROM conversation_summaries
                """)
                for row in cursor:
                    c_id = sanitize_plain_text(row["conversation_id"], 100)
                    if not c_id:
                        continue
                    if c_id not in conv_map:
                        conv_map[c_id] = {
                            "conversationId": c_id,
                            "firstPrompt": sanitize_plain_text(row["title"] or f"Session {c_id[:8]}", 150),
                            "lastPrompt": sanitize_plain_text(row["preview"] or "Session", 250),
                            "workspace": sanitize_plain_text(row["workspace_uris"] or "", 300),
                            "timestamp": 0,
                            "stepCount": int(row["step_count"] or 0),
                            "agentName": sanitize_plain_text(row["agent_name"] or "Antigravity", 80)
                        }
                    else:
                        if row["title"]:
                            conv_map[c_id]["firstPrompt"] = sanitize_plain_text(row["title"], 150)
                        if row["preview"]:
                            conv_map[c_id]["lastPrompt"] = sanitize_plain_text(row["preview"], 250)
                        if row["agent_name"]:
                            conv_map[c_id]["agentName"] = sanitize_plain_text(row["agent_name"], 80)
        except Exception:
            pass

    # (d) Ensure active_lock_ids are included
    for cid in active_lock_ids:
        if cid not in conv_map:
            now_sec = dt.datetime.now().timestamp()
            conv_map[cid] = {
                "conversationId": cid,
                "firstPrompt": f"Session {cid[:8]}",
                "lastPrompt": "Active Session",
                "workspace": "",
                "timestamp": now_sec,
                "mtime": now_sec,
                "stepCount": 0,
                "agentName": "Antigravity"
            }

    # Sort sessions: active sessions first, then most recent modification time
    def session_sort_key(c: dict[str, Any]) -> tuple[int, float]:
        cid = c["conversationId"]
        is_act = 1 if cid in active_lock_ids else 0
        mtime = c.get("mtime") or c.get("timestamp", 0)
        return (is_act, mtime)

    sorted_convs = sorted(conv_map.values(), key=session_sort_key, reverse=True)

    all_sessions: list[dict[str, Any]] = []
    active_sessions: list[dict[str, Any]] = []
    any_session_working = False

    for item in sorted_convs:
        cid = item["conversationId"]
        is_active = cid in active_lock_ids
        is_working = False
        if is_active:
            is_working = check_session_working(cid, base_dir)
            if is_working:
                any_session_working = True

        clean_ws = sanitize_plain_text(item.get("workspace", ""), 300)
        ws_name = Path(clean_ws).name if clean_ws else "Workspace"
        mtime_sec = item.get("mtime") or item.get("timestamp", 0)
        date_str = local_date_from_timestamp(mtime_sec)
        iso_mod = dt.datetime.fromtimestamp(mtime_sec, tz=dt.timezone.utc).isoformat() if mtime_sec else ""

        first_p = item.get("firstPrompt", "").strip()
        last_p = item.get("lastPrompt", "").strip()
        title = first_p or last_p or f"Session {cid[:8]}"
        preview = last_p or first_p or title
        if len(last_p) < 12 and len(first_p) > len(last_p):
            preview = first_p

        s_item = {
            "conversationId": cid,
            "title": sanitize_plain_text(title, 150),
            "preview": sanitize_plain_text(preview, 250),
            "stepCount": item.get("stepCount", 0),
            "lastModified": iso_mod,
            "date": date_str,
            "workspace": clean_ws,
            "workspaceName": ws_name,
            "status": "active" if is_active else "idle",
            "agentName": item.get("agentName", "Antigravity"),
            "notFullyIdle": is_working,
            "killed": False,
            "isActive": is_active
        }
        all_sessions.append(s_item)
        if is_active:
            active_sessions.append(s_item)

    has_active_session = len(active_lock_ids) > 0
    if has_active_session:
        active_status = "Working" if any_session_working else "Waiting"
    else:
        active_status = "Idle"

    # Step and Session counts from real activity
    today_steps_from_models = sum(m.get("todaySteps", 0) for m in model_list)
    total_steps_from_models = sum(m.get("steps", 0) for m in model_list)
    today_db_steps = today_steps_from_models or sum(s["stepCount"] for s in all_sessions if s["date"] == today_str)
    total_db_steps = total_steps_from_models or sum(s["stepCount"] for s in all_sessions)
    today_db_sessions = len(set(s["conversationId"] for s in all_sessions if s["date"] == today_str)) or (1 if has_active_session else 0)
    total_db_sessions = len(all_sessions)

    # 6. Build recent days breakdown
    recent_days_data = []
    weekly_prompts = 0
    # Pre-compute per-day step counts from session data
    daily_steps: dict[str, int] = {}
    for s in all_sessions:
        d = s.get("date", "")
        if d in recent_dates:
            daily_steps[d] = daily_steps.get(d, 0) + s.get("stepCount", 0)
    for day in recent_dates:
        p_count = daily_prompts.get(day, 0)
        weekly_prompts += p_count
        recent_days_data.append({
            "date": day,
            "messageCount": p_count,
            "prompts": p_count,
            "steps": daily_steps.get(day, 0)
        })

    # 7. Convert quota groups into legacy limits array for backward compatibility
    limits = []
    for g in quota_groups:
        for b in g.get("buckets", []):
            limits.append({
                "group": b.get("id", ""),
                "groupName": g.get("name", ""),
                "title": f"{g.get('name', '')} {b.get('label', '')}",
                "icon": "",
                "color": b.get("color", "#38BDF8"),
                "used": b.get("usedPercent", 0),
                "allowance": 100,
                "percent": round(1.0 - b.get("remainingFraction", 1.0), 3),
                "resetsAt": b.get("resetTime", ""),
                "burnRatePerHour": b.get("burnRatePerHour", 0.0),
                "burnRateText": b.get("burnRateText", ""),
                "forecastText": b.get("forecastText", ""),
                "forecastStatus": b.get("forecastStatus", "stable")
            })

    # 8. Workspaces list (sorted by frequency)
    recent_workspaces = [
        {"path": sanitize_plain_text(ws, 300), "name": sanitize_plain_text(Path(ws).name, 100), "count": count}
        for ws, count in ws_counter.most_common(5)
    ]

    # Tools usage dict
    tools_dict = {sanitize_plain_text(k, 80): v for k, v in tool_counter.most_common(10)}

    clean_latest_model = sanitize_plain_text(latest_model, 80)

    quota_cache_path = base_dir / "cache" / "quota_usage_cache.json"
    quota_updated_at = ""
    quota_updated_ms = 0
    if quota_cache_path.exists():
        try:
            quota_mtime = quota_cache_path.stat().st_mtime
            quota_updated_at = dt.datetime.fromtimestamp(quota_mtime, tz=dt.timezone.utc).isoformat()
            quota_updated_ms = int(quota_mtime * 1000)
        except Exception:
            pass

    result = {
        "schemaVersion": 1,
        "id": "antigravity",
        "name": "Antigravity",
        "ready": True,
        "active": has_active_session,
        "activeStatus": active_status,
        "hasActiveSession": has_active_session,
        "hasLocalStats": True,
        "tierLabel": "Google DeepMind",
        "currentModel": clean_latest_model,
        "todayPrompts": daily_prompts.get(today_str, 0),
        "todaySessions": today_db_sessions or (1 if has_active_session else 0),
        "todaySteps": today_db_steps,
        "todayTotalTokens": today_token_usage(base_dir / "conversations", today_date),
        "todayTokensByModel": {},
        "recentDays": recent_days_data,
        "totalPrompts": total_prompts_hist,
        "totalSessions": total_db_sessions,
        "totalSteps": total_db_steps,
        "activeSessions": active_sessions,
        "recentSessions": all_sessions[:10],
        "toolUsage": tools_dict,
        "modelUsage": model_usage_dict,
        "modelList": model_list,
        "quotaGroups": quota_groups,
        "limits": limits,
        "recentWorkspaces": recent_workspaces,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": quota_updated_at,
        "quotaUpdatedMs": quota_updated_ms,
        "lastFullRefreshMs": quota_updated_ms,
        "usageStatusText": f"{active_status} • {clean_latest_model}",
        "authHelpText": ""
    }

    # Save to short-lived cache for concurrent monitor deduplication
    try:
        scan_cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_cache = scan_cache_path.with_suffix(".tmp")
        with open(tmp_cache, "w", encoding="utf-8") as f:
            json.dump(result, f)
        tmp_cache.replace(scan_cache_path)
    except Exception:
        pass

    return result


scan_antigravity = scan


def main() -> None:
    parser = argparse.ArgumentParser(description="Antigravity Usage Scanner")
    parser.add_argument("path", nargs="?", default=None, help="Path to ~/.gemini/antigravity-cli")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--force", action="store_true", help="Bypass cache and force refresh from agy /usage")
    parser.add_argument("--kill", type=str, default=None, help="Kill the running session by conversation ID")
    parser.add_argument("--refresh-quota-bg", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--notify-low-quota", type=int, nargs="?", const=15, default=None, help=argparse.SUPPRESS)
    args = parser.parse_args()

    base_dir = expand_path(args.path) if args.path else default_base_dir()

    if args.refresh_quota_bg:
        bg_refresh_quota(base_dir)
        return

    if args.kill:
        success = kill_session(args.kill, base_dir)
        print(json.dumps({"success": success, "conversationId": args.kill}))
        return

    result = scan(base_dir, force=args.force, alert_threshold=args.notify_low_quota)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
