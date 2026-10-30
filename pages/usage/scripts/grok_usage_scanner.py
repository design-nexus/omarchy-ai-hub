#!/usr/bin/env python3
"""Query Grok CLI state, sessions, and billing API to emit usage stats."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

from common import FetchGate, LogCache
from urllib.parse import unquote


def default_base_dir() -> Path:
    return Path(os.environ.get("GROK_HOME") or os.path.expanduser("~/.grok"))


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def date_string(value: dt.date) -> str:
    return value.strftime("%Y-%m-%d")


def sanitize_plain_text(val: Any, max_len: int = 250) -> str:
    if val is None:
        return ""
    text = str(val)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_len]


def recent_date_strings() -> list[str]:
    today = dt.datetime.now().date()
    return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


_MS_EPOCH_THRESHOLD = 10_000_000_000


def normalize_timestamp_seconds(value: Any) -> float:
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


def compute_bucket_forecast(
    remaining_pct: float,
    burn_rate_pct_per_hour: float,
    resets_at_str: str,
) -> tuple[str, str, str]:
    if not resets_at_str:
        return "", "No reset time provided", "stable"

    try:
        resets_at = dt.datetime.fromisoformat(resets_at_str.replace("Z", "+00:00"))
        now = dt.datetime.now(dt.timezone.utc)
        hours_until_reset = max(0.0, (resets_at - now).total_seconds() / 3600.0)
    except Exception:
        return "", "Invalid reset time", "stable"

    burn_str = f"{burn_rate_pct_per_hour:.1f}%/h" if burn_rate_pct_per_hour > 0 else ""

    if burn_rate_pct_per_hour <= 0.001 or hours_until_reset <= 0:
        return burn_str, "Paced to reset", "stable"

    hours_until_depleted = remaining_pct / burn_rate_pct_per_hour
    depletion_duration_str = format_hours_duration(hours_until_depleted)

    if hours_until_depleted < hours_until_reset:
        return burn_str, f"Depletes in ~{depletion_duration_str} (before reset)", "critical"

    remaining_at_reset = max(0.0, remaining_pct - (burn_rate_pct_per_hour * hours_until_reset))
    status = "warning" if remaining_at_reset < 15.0 else "safe"
    prefix = "Tight pace" if status == "warning" else "On pace"
    return burn_str, f"{prefix} · ~{remaining_at_reset:.0f}% at reset", status


def update_quota_snapshots(base_dir: Path, groups: list[dict[str, Any]]) -> dict[str, float]:
    snap_file = base_dir / "cache" / "quota_snapshots.json"
    snap_file.parent.mkdir(parents=True, exist_ok=True)
    now_ts = time.time()

    snapshots: dict[str, list[tuple[float, float]]] = {}
    if snap_file.exists():
        try:
            with open(snap_file, "r", encoding="utf-8") as f:
                raw = json.load(f)
                if isinstance(raw, dict):
                    snapshots = {k: [(float(t), float(pct)) for t, pct in v] for k, v in raw.items() if isinstance(v, list)}
        except Exception:
            snapshots = {}

    burn_rates: dict[str, float] = {}

    for g in groups:
        for b in g.get("buckets", []):
            bid = b.get("id") or b.get("name")
            if not bid:
                continue
            rem_pct = float(b.get("remainingPercent", (b.get("remainingFraction", 1.0) * 100)))
            pts = snapshots.setdefault(bid, [])
            pts.append((now_ts, rem_pct))
            cutoff = now_ts - (6 * 3600)
            pts = [(t, pct) for t, pct in pts if t >= cutoff]
            snapshots[bid] = pts

            if len(pts) >= 2:
                t_first, p_first = pts[0]
                t_last, p_last = pts[-1]
                time_span_h = (t_last - t_first) / 3600.0
                if time_span_h >= (3.0 / 60.0):
                    pct_drop = p_first - p_last
                    burn_rates[bid] = max(0.0, pct_drop / time_span_h) if pct_drop > 0 else 0.0
                else:
                    burn_rates[bid] = 0.0
            else:
                burn_rates[bid] = 0.0

    try:
        tmp_snap = snap_file.with_suffix(".tmp")
        with open(tmp_snap, "w", encoding="utf-8") as f:
            json.dump(snapshots, f)
        tmp_snap.replace(snap_file)
    except Exception:
        pass

    return burn_rates


def read_configured_model(base_dir: Path | None = None) -> str:
    if base_dir:
        config_toml = base_dir / "config.toml"
        if config_toml.exists():
            try:
                for line in config_toml.read_text(encoding="utf-8", errors="replace").splitlines():
                    if line.startswith("["):
                        break  # top-level keys only; tables follow
                    key, sep, val = line.partition("=")
                    if sep and key.strip() == "model":
                        val = val.split("#", 1)[0].strip().strip('"').strip("'")
                        if val:
                            return sanitize_plain_text(val, 80)
            except Exception:
                pass
    return ""


def empty_result(base_dir: Path | None = None) -> dict[str, Any]:
    recent_dates = recent_date_strings()
    current_model = read_configured_model(base_dir)
    return {
        "schemaVersion": 1,
        "id": "grok",
        "name": "Grok",
        "ready": False,
        "active": False,
        "activeStatus": "Idle",
        "hasActiveSession": False,
        "hasLocalStats": False,
        "tierLabel": "xAI",
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
        "usageStatusText": "No Grok data found",
        "authHelpText": "Run `grok login` to authenticate.",
    }


def parse_grok_sessions(sessions_dir: Path) -> list[dict[str, Any]]:
    sessions = []
    if not sessions_dir.exists():
        return sessions

    for summary_path in sessions_dir.glob("*/*/summary.json"):
        try:
            with open(summary_path, "r", encoding="utf-8", errors="replace") as f:
                data = json.load(f)
                if not isinstance(data, dict):
                    continue
                info = data.get("info") or {}
                sid = sanitize_plain_text(info.get("id"), 100)
                if not sid:
                    continue

                raw_cwd = str(info.get("cwd") or "")
                if not raw_cwd:
                    # decode from parent folder name
                    encoded_dir = summary_path.parent.parent.name
                    raw_cwd = unquote(encoded_dir)

                ws_name = Path(raw_cwd).name if raw_cwd else "Work"
                updated_at = str(data.get("updated_at") or data.get("last_active_at") or "")
                title = sanitize_plain_text(data.get("session_summary") or f"Session in {ws_name}", 150)
                model_id = sanitize_plain_text(data.get("current_model_id"), 80)
                msg_count = int(data.get("num_chat_messages") or data.get("num_messages") or 0)

                sessions.append({
                    "conversationId": sid,
                    "title": title,
                    "preview": title,
                    "workspace": raw_cwd,
                    "workspaceName": ws_name,
                    "updated_at": updated_at,
                    "stepCount": msg_count,
                    "model": model_id,
                    "isActive": False,
                })
        except Exception:
            continue

    sessions.sort(key=lambda s: s.get("updated_at", ""), reverse=True)
    return sessions


UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
GROK_EXE_RE = re.compile(r"grok(-[0-9][0-9.]*)?")


def grok_processes() -> list[tuple[int, str]]:
    """(pid, cmdline) of live processes whose executable is grok."""
    found = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            argv = (proc / "cmdline").read_bytes().decode("utf-8", errors="replace").split("\0")
            exe = os.path.basename(os.readlink(proc / "exe"))
            if not (GROK_EXE_RE.fullmatch(exe) or GROK_EXE_RE.fullmatch(os.path.basename(argv[0]))):
                continue
            if re.search(r"^State:\s*Z", (proc / "status").read_text(errors="replace"), re.M):
                continue
            found.append((int(proc.name), " ".join(argv)))
        except OSError:
            continue
    return found


def get_active_grok_pids(base_dir: Path) -> dict[str, int]:
    session_pids = {}

    # 1. Check active_sessions.json
    active_json = base_dir / "active_sessions.json"
    if active_json.exists():
        try:
            with open(active_json, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    for item in data:
                        if isinstance(item, dict) and item.get("id"):
                            session_pids[item["id"]] = item.get("pid", 0)
                        elif isinstance(item, str):
                            session_pids[item] = 0
        except Exception:
            pass

    # 2. Running grok executables (the binary is grok or grok-<version>).
    for pid, cmd in grok_processes():
        m = UUID_RE.search(cmd)
        session_pids[m.group(0) if m else f"pid-{pid}"] = pid

    return session_pids


def kill_session(cid: str, base_dir: Path) -> bool:
    """Terminate the grok process running ``cid``; only grok executables are considered."""
    import signal
    pid = get_active_grok_pids(base_dir).get(cid)
    if not pid or not any(p == pid for p, _ in grok_processes()):
        return False
    try:
        os.kill(pid, signal.SIGTERM)
        return True
    except OSError:
        return False


def access_token(auth_path: Path) -> tuple[str, str]:
    if not auth_path.exists():
        return "", ""
    try:
        with open(auth_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            if not isinstance(data, dict):
                return "", ""
            for entry in data.values():
                if not isinstance(entry, dict):
                    continue
                token = str(entry.get("key") or "").strip()
                if token:
                    return token, str(entry.get("expires_at") or "")
    except Exception:
        pass
    return "", ""


def token_expired(expires_at: str) -> bool:
    if not expires_at:
        return False
    try:
        parsed = dt.datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed <= dt.datetime.now(dt.timezone.utc)
    except Exception:
        return False


BILLING_ENDPOINT = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"


def fetch_grok_billing(base_dir: Path, force: bool = False) -> tuple[list[dict[str, Any]], str, str]:
    cache_file = base_dir / "cache" / "quota_usage_cache.json"
    cache_file.parent.mkdir(parents=True, exist_ok=True)

    if not force and cache_file.exists():
        try:
            age = time.time() - cache_file.stat().st_mtime
            if age < 180:
                with open(cache_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict) and "groups" in data and len(data["groups"]) > 0:
                        return data.get("groups", []), data.get("tierLabel", "SuperGrok"), ""
        except Exception:
            pass

    def cached_groups(error: str) -> tuple[list[dict[str, Any]], str, str]:
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get("groups", []), data.get("tierLabel", "SuperGrok"), error
        except Exception:
            return [], "", error

    gate = FetchGate("grok")
    blocked = gate.blocked(force)
    if blocked:
        return cached_groups(blocked)

    auth_file = base_dir / "auth.json"
    token, expires_at = access_token(auth_file)
    if not token:
        if cache_file.exists():
            try:
                with open(cache_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    return data.get("groups", []), data.get("tierLabel", "SuperGrok"), "Waiting for auth"
            except Exception:
                pass
        return [], "", "No Grok authentication token found. Run `grok login`."

    if token_expired(expires_at):
        if cache_file.exists():
            try:
                with open(cache_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    return data.get("groups", []), data.get("tierLabel", "SuperGrok"), "Sign-in expired"
            except Exception:
                pass

    try:
        req = urllib.request.Request(
            BILLING_ENDPOINT,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read()
            payload = json.loads(body.decode("utf-8", errors="replace"))
        gate.succeeded()

        config = payload.get("config") if isinstance(payload, dict) else {}
        tier = str(config.get("subscriptionTier") or payload.get("subscriptionTier") or "SuperGrok")

        period = config.get("currentPeriod") or {}
        resets_at = str(period.get("end") or config.get("billingPeriodEnd") or "")
        if resets_at:
            try:
                resets_at = dt.datetime.fromisoformat(resets_at.replace("Z", "+00:00")).isoformat()
            except Exception:
                pass

        buckets = []

        # 1. Weekly credits limit
        weekly_used = float(config.get("creditUsagePercent") or 0.0)
        rem_weekly = max(0.0, 100.0 - weekly_used)
        buckets.append({
            "id": "grok-weekly",
            "name": "Weekly SuperGrok Pool",
            "label": "Weekly Pool",
            "remainingFraction": rem_weekly / 100.0,
            "remainingPercent": round(rem_weekly),
            "usedPercent": round(weekly_used),
            "resetTime": resets_at,
            "color": "#3B82F6",
        })

        # 2. Product usages
        products = config.get("productUsage")
        if isinstance(products, list):
            for p in products:
                if not isinstance(p, dict):
                    continue
                pname = str(p.get("product") or "Product")
                used_pct = float(p.get("usagePercent") or 0.0)
                rem_pct = max(0.0, 100.0 - used_pct)
                buckets.append({
                    "id": f"grok-{pname.lower().replace(' ', '-')}",
                    "name": f"{pname} Limit",
                    "label": pname,
                    "remainingFraction": rem_pct / 100.0,
                    "remainingPercent": round(rem_pct),
                    "usedPercent": round(used_pct),
                    "resetTime": resets_at,
                    "color": "#0EA5E9" if "Build" in pname else "#8B5CF6",
                })

        groups = [{
            "name": "Grok Quota Limits",
            "description": f"Subscription Tier: {tier}",
            "color": "#3B82F6",
            "buckets": buckets,
        }]

        try:
            with open(cache_file, "w", encoding="utf-8") as f:
                json.dump({"groups": groups, "tierLabel": tier}, f)
        except Exception:
            pass

        return groups, tier, ""
    except urllib.error.HTTPError as error:
        message = ("Grok sign-in is no longer valid. Run `grok login`." if error.code in (401, 403)
                   else f"Grok billing returned status {error.code}")
        gate.failed(message)
        return [], "", message
    except Exception as exc:
        gate.failed(str(exc))
        return cached_groups(str(exc))


# Bump when read_update_lines or read_history_lines change what they record.
LOG_CACHE_VERSION = 1


def read_update_lines(entry: dict[str, Any], lines: list[bytes], mtime: float) -> None:
    """Completed turns in one updates.jsonl, as [turns, input, output, cached] by model and day."""
    for raw in lines:
        try:
            row = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            continue
        params = row.get("params") if isinstance(row, dict) else None
        update = params.get("update") if isinstance(params, dict) else None
        if not isinstance(update, dict) or update.get("sessionUpdate") != "turn_completed":
            continue
        usage = update.get("usage")
        if not isinstance(usage, dict):
            continue
        meta = row.get("_meta") if isinstance(row.get("_meta"), dict) else {}
        day = local_date_from_timestamp(meta.get("agentTimestampMs") or row.get("timestamp"))
        models = usage.get("modelUsage") if isinstance(usage.get("modelUsage"), dict) else {}
        m = next(iter(models), None) or "grok-3"
        m = str(m).rstrip("/").split("/")[-1] or "grok-3"
        counts = entry["turns"].setdefault(m + "\x1f" + day, [0, 0, 0, 0])
        counts[0] += 1
        counts[1] += int(usage.get("inputTokens") or 0)
        counts[2] += int(usage.get("outputTokens") or 0)
        counts[3] += int(usage.get("cachedReadTokens") or usage.get("cacheReadInputTokens") or 0)


def read_history_lines(entry: dict[str, Any], lines: list[bytes], mtime: float) -> None:
    """Tool calls in one chat_history.jsonl, by tool name."""
    for raw in lines:
        try:
            row = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("type") == "tool_call":
            name = row.get("tool_name") or row.get("name")
            if name:
                key = sanitize_plain_text(name, 50)
                entry["tools"][key] = entry["tools"].get(key, 0) + 1


def scan(base_dir: Path, force: bool = False) -> dict[str, Any]:
    res = empty_result(base_dir)
    recent_dates = recent_date_strings()
    today_str = date_string(dt.datetime.now().date())

    # 1. Parse Grok sessions
    sessions_dir = base_dir / "sessions"
    sessions = parse_grok_sessions(sessions_dir)
    active_pids = get_active_grok_pids(base_dir)

    has_active = len(active_pids) > 0
    res["hasActiveSession"] = has_active
    res["active"] = has_active
    res["activeStatus"] = "Working" if has_active else "Idle"

    for s in sessions:
        if s["conversationId"] in active_pids or (has_active and len(sessions) > 0 and s == sessions[0]):
            s["isActive"] = True

    res["recentSessions"] = sessions[:10]
    res["activeSessions"] = [s for s in sessions if s.get("isActive")]
    res["totalSessions"] = len(sessions)

    # 2. Parse token and prompt activity
    model_usage: dict[str, dict[str, Any]] = {}
    tool_counter: Counter = Counter()
    recent_days_map = {d: {"date": d, "messageCount": 0, "prompts": 0, "steps": 0} for d in recent_dates}
    today_tokens_by_model: dict[str, int] = {}
    today_prompts = 0
    today_steps = 0
    today_tokens = 0
    today_cached = 0
    today_cached_by_model: dict[str, int] = {}
    total_prompts = 0
    total_steps = 0

    # Each log is read once and then only what is appended (LogCache): the
    # turns per model and day from updates.jsonl, tool calls from chat_history.
    log_cache = LogCache("grok", LOG_CACHE_VERSION)
    turns: dict[str, list[int]] = {}
    for p in sorted(sessions_dir.glob("*/*/updates.jsonl")) if sessions_dir.exists() else []:
        entry = log_cache.update(p, lambda: {"turns": {}}, read_update_lines)
        for key, counts in (entry or {}).get("turns", {}).items():
            total = turns.setdefault(key, [0, 0, 0, 0])
            for i, n in enumerate(counts):
                total[i] += n
    for p in sorted(sessions_dir.glob("*/*/chat_history.jsonl")) if sessions_dir.exists() else []:
        entry = log_cache.update(p, lambda: {"tools": {}}, read_history_lines)
        tool_counter.update((entry or {}).get("tools", {}))
    log_cache.prune()

    for key, (count, in_tok, out_tok, cached_tok) in turns.items():
        m, day = key.split("\x1f", 1)
        total_tok = in_tok + out_tok
        total_prompts += count
        total_steps += count
        bucket = model_usage.setdefault(m, {
            "name": m,
            "prompts": 0,
            "steps": 0,
            "todayPrompts": 0,
            "todaySteps": 0,
            "weekPrompts": 0,
            "weekSteps": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "cachedTokens": 0,
            "color": "#3B82F6",
        })
        bucket["prompts"] += count
        bucket["steps"] += count
        bucket["inputTokens"] += in_tok
        bucket["outputTokens"] += out_tok
        bucket["cachedTokens"] += cached_tok
        if day in recent_days_map:
            recent_days_map[day]["messageCount"] += count
            recent_days_map[day]["prompts"] += count
            recent_days_map[day]["steps"] += count
            bucket["weekPrompts"] += count
            bucket["weekSteps"] += count
        if day == today_str:
            today_prompts += count
            today_steps += count
            today_tokens += total_tok
            today_cached += cached_tok
            bucket["todayPrompts"] += count
            bucket["todaySteps"] += count
            today_tokens_by_model[m] = today_tokens_by_model.get(m, 0) + total_tok
            today_cached_by_model[m] = today_cached_by_model.get(m, 0) + cached_tok

    # 3. Fetch billing limits
    groups, tier, err_str = fetch_grok_billing(base_dir, force=force)
    burn_rates = update_quota_snapshots(base_dir, groups)

    limits_list = []
    for g in groups:
        for b in g.get("buckets", []):
            bid = b.get("id") or b.get("name")
            rem_pct = float(b.get("remainingPercent", 100))
            rate = burn_rates.get(bid, 0.0)
            burn_txt, fc_txt, status = compute_bucket_forecast(rem_pct, rate, b.get("resetTime", ""))
            b["burnRatePerHour"] = rate
            b["burnRateText"] = burn_txt
            b["forecastText"] = fc_txt
            b["forecastStatus"] = status

            limits_list.append({
                "label": b.get("label", "Limit"),
                "percent": float(b.get("usedPercent", 0)) / 100.0,
                "resetsAt": b.get("resetTime", ""),
            })


    model_list = list(model_usage.values())
    model_list.sort(key=lambda m: m["prompts"], reverse=True)

    has_stats = len(sessions) > 0 or total_prompts > 0 or len(groups) > 0

    res.update({
        "ready": True,
        "hasLocalStats": has_stats,
        "tierLabel": tier if tier else "xAI",
        "currentModel": read_configured_model(base_dir) or next((x.get("model") for x in sessions if x.get("model")), ""),
        "todayPrompts": today_prompts,
        "todaySessions": len(res["activeSessions"]) if has_active else (1 if today_prompts > 0 else 0),
        "todaySteps": today_steps,
        "todayTotalTokens": today_tokens,
        "todayCachedTokens": today_cached,
        "todayTokensByModel": today_tokens_by_model,
        "todayCachedByModel": today_cached_by_model,
        "recentDays": [recent_days_map[d] for d in recent_dates],
        "totalPrompts": total_prompts,
        "totalSessions": len(sessions),
        "totalSteps": total_steps,
        "toolUsage": dict(tool_counter.most_common(12)),
        "modelUsage": model_usage,
        "modelList": model_list,
        "quotaGroups": groups,
        "limits": limits_list,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": dt.datetime.now(dt.timezone.utc).isoformat() if groups else "",
        "quotaUpdatedMs": round(time.time() * 1000) if groups else 0,
        "lastFullRefreshMs": round(time.time() * 1000),
        "usageStatusText": "" if has_stats else "No Grok activity found",
        "authHelpText": "" if has_stats else "Run `grok login` to begin.",
    })

    return res


def collect(force: bool = False) -> dict:
    """This provider's usage, for usage_scanner.py to call in-process."""
    return scan(default_base_dir(), force=force)


def main() -> None:
    parser = argparse.ArgumentParser(description="Grok Usage Scanner for Omarchy")
    parser.add_argument("--force", action="store_true", help="Force refresh bypassing caches")
    parser.add_argument("--kill", type=str, metavar="CID", help="Kill session by conversation ID")
    args = parser.parse_args()

    base_dir = default_base_dir()

    if args.kill:
        killed = kill_session(args.kill, base_dir)
        print(json.dumps({"killed": killed, "conversationId": args.kill}))
        return

    data = scan(base_dir, force=args.force)
    print(json.dumps(data, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
