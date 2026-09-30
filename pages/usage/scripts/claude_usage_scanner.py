#!/usr/bin/env python3
"""Claude Code usage and rate limit scanner."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

HOME = Path.home()
BASE = Path(os.environ.get("CLAUDE_CONFIG_DIR", HOME / ".claude"))
COLOR = "#D97757"
QUOTA_NOTE = "Claude quota is not estimated."


def stamp(value) -> float:
    if isinstance(value, (int, float)):
        return float(value) / (1000 if value > 1e10 else 1)
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return 0
    return 0


def text(value, limit: int = 140) -> str:
    return " ".join(str(value or "").replace("\x00", "").split())[:limit]


def local_day(timestamp: float, fallback: float) -> dt.date:
    return dt.datetime.fromtimestamp(timestamp or fallback).date()


def recent_days(today: dt.date, prompts: Counter, steps: Counter) -> list[dict]:
    rows = []
    for offset in range(6, -1, -1):
        day = today - dt.timedelta(days=offset)
        key = str(day)
        rows.append({
            "date": key,
            "messageCount": prompts[key],
            "prompts": prompts[key],
            "steps": steps[key],
        })
    return rows


def format_claude_model_name(raw: str) -> str:
    name = (raw or "").strip()
    if not name or name == "<synthetic>" or name.lower() == "claude":
        return ""
    mapping = {
        "claude-opus-5-5": "Claude Opus 5.5",
        "claude-opus-5": "Claude Opus 5",
        "claude-opus-4-8": "Claude Opus 4.8",
        "claude-opus-4-6": "Claude Opus 4.6",
        "claude-opus-4-5": "Claude Opus 4.5",
        "claude-opus-4-1": "Claude Opus 4.1",
        "claude-opus-4": "Claude Opus 4",
        "claude-opus-4-0": "Claude Opus 4",
        "claude-sonnet-5": "Claude Sonnet 5",
        "claude-sonnet-4-6": "Claude Sonnet 4.6",
        "claude-sonnet-4-5": "Claude Sonnet 4.5",
        "claude-sonnet-4": "Claude Sonnet 4",
        "claude-sonnet-4-0": "Claude Sonnet 4",
        "claude-haiku-4-5": "Claude Haiku 4.5",
        "claude-3-7-sonnet": "Claude 3.7 Sonnet",
        "claude-3-5-sonnet": "Claude 3.5 Sonnet",
        "claude-3-5-haiku": "Claude 3.5 Haiku",
        "claude-3-opus": "Claude 3 Opus",
        "claude-3-sonnet": "Claude 3 Sonnet",
        "claude-3-haiku": "Claude 3 Haiku",
        "claude-sonnet": "Claude Sonnet",
        "claude-opus": "Claude Opus",
        "claude-haiku": "Claude Haiku",
    }
    for k, v in mapping.items():
        if name.startswith(k):
            return v
    parts = name.split("-")
    if parts and parts[0].lower() == "claude":
        parts = parts[1:]
    return ("Claude " + " ".join(parts).title()).replace("-", ".")


def blank_model(name: str) -> dict:
    return {
        "name": name,
        "prompts": 0,
        "steps": 0,
        "todayPrompts": 0,
        "todaySteps": 0,
        "weekPrompts": 0,
        "weekSteps": 0,
        "inputTokens": 0,
        "outputTokens": 0,
        "cachedTokens": 0,
        "color": COLOR,
    }


def claude_active_cwds() -> list[str]:
    """Working directories of running claude processes (zombies excluded)."""
    try:
        out = subprocess.run(["pgrep", "-x", "claude"], capture_output=True, text=True, timeout=1).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    cwds = []
    for pid in out.split():
        proc = Path("/proc") / pid
        try:
            if re.search(r"^State:\s*Z", (proc / "status").read_text(errors="replace"), re.M):
                continue
            cwds.append(os.readlink(proc / "cwd"))
        except OSError:
            cwds.append("")
    return cwds


COMMAND_TAG = re.compile(r"<(command-name|command-args)>(.*?)</\1>", re.S)


def prompt_text(content: Any) -> str | None:
    """Text of a real user prompt, or None for tool results and CLI noise.

    Slash commands are prompts only when they carry arguments; their preview
    is the command line as typed.
    """
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        if not parts:
            return None  # tool_result / image-only rows
        content = " ".join(parts)
    if not isinstance(content, str):
        return None
    stripped = content.lstrip()
    if stripped.startswith("<local-command-"):
        return None
    if stripped.startswith("<command-"):
        tags = dict(COMMAND_TAG.findall(content))
        args = tags.get("command-args", "").strip()
        if not args:
            return None
        return text(tags.get("command-name", "").strip() + " " + args)
    return text(content) or None


def format_hours_duration(hours: float) -> str:
    if hours < 1.0:
        mins = max(1, round(hours * 60))
        return f"{mins}m"
    if hours < 24.0:
        return f"{hours:.1f}h"
    days = hours / 24.0
    return f"{days:.1f}d"


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


def check_and_send_quota_notifications(base_dir: Path, groups: list[dict[str, Any]], threshold_pct: int = 15) -> None:
    notify_cmd = shutil.which("omarchy-notification-send") or "/usr/share/omarchy/bin/omarchy-notification-send"
    if not notify_cmd or not Path(notify_cmd).exists():
        return

    cooldown_file = base_dir / "cache" / "low_quota_notified.json"
    cooldown_file.parent.mkdir(parents=True, exist_ok=True)
    now = time.time()
    notified_state: dict[str, float] = {}

    if cooldown_file.exists():
        try:
            with open(cooldown_file, "r", encoding="utf-8") as f:
                notified_state = json.load(f)
        except Exception:
            notified_state = {}

    dirty = False
    for g in groups:
        for b in g.get("buckets", []):
            rem_pct = b.get("remainingPercent", round((b.get("remainingFraction", 1.0) * 100)))
            bid = b.get("id") or b.get("name")
            if not bid:
                continue

            if rem_pct <= threshold_pct:
                last_sent = notified_state.get(bid, 0)
                if now - last_sent > 7200:
                    b_label = b.get("label") or b.get("name") or "Claude Quota"
                    msg = f"{b_label} is down to {rem_pct}% remaining."
                    try:
                        subprocess.run(
                            [notify_cmd, "Claude Quota Warning", msg, "--category", "ai"],
                            capture_output=True,
                            timeout=5,
                        )
                        notified_state[bid] = now
                        dirty = True
                    except Exception:
                        pass

    if dirty:
        try:
            with open(cooldown_file, "w", encoding="utf-8") as f:
                json.dump(notified_state, f)
        except Exception:
            pass


def parse_resets_time(s: str) -> str:
    if not s:
        return ""
    cleaned = re.sub(r"\(.*?\)", "", s).strip().rstrip(",")
    year = dt.datetime.now().year
    for fmt in ("%b %d, %I%p %Y", "%b %d %I%p %Y", "%b %d, %I:%M%p %Y"):
        try:
            parsed = dt.datetime.strptime(f"{cleaned} {year}", fmt)
            local_tz = dt.datetime.now().astimezone().tzinfo
            parsed = parsed.replace(tzinfo=local_tz)
            if parsed < dt.datetime.now(local_tz) - dt.timedelta(days=180):
                parsed = parsed.replace(year=year + 1)
            return parsed.isoformat()
        except ValueError:
            pass
    return ""


def parse_claude_usage_output(text: str, plan_tier: str = "") -> list[dict[str, Any]]:
    buckets: list[dict[str, Any]] = []
    pattern = re.compile(r"^([^:\n]+):\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^,\n]+(?:,\s*[^(\n]+)?(?:\s*\([^)]+\))?))?", re.MULTILINE)
    for match in pattern.finditer(text):
        raw_label = match.group(1).strip()
        used = float(match.group(2))
        rem_pct = max(0.0, 100.0 - used)
        resets_str = match.group(3).strip() if match.group(3) else ""
        resets_at = parse_resets_time(resets_str)

        low = raw_label.lower()
        if "session" in low:
            b_id = "claude-five-hour"
            badge = "5h window"
            b_name = "Current Session Remaining"
        elif "week" in low and ("all" in low or "model" in low):
            b_id = "claude-seven-day"
            badge = "Weekly (7-day)"
            b_name = "Weekly (all models) Remaining"
        elif "sonnet" in low:
            b_id = "claude-seven-day-sonnet"
            badge = "Weekly (Sonnet)"
            b_name = "Weekly (Sonnet) Remaining"
        elif "opus" in low:
            b_id = "claude-seven-day-opus"
            badge = "Weekly (Opus)"
            b_name = "Weekly (Opus) Remaining"
        else:
            slug = re.sub(r"[^a-z0-9]+", "-", low).strip("-")
            b_id = f"claude-{slug}"
            badge = raw_label
            b_name = f"{raw_label} Remaining"

        buckets.append({
            "id": b_id,
            "name": b_name,
            "label": badge,
            "remainingFraction": rem_pct / 100.0,
            "remainingPercent": round(rem_pct),
            "usedPercent": round(used),
            "resetTime": resets_at,
            "color": COLOR,
        })
    return buckets


def fetch_claude_quota(base_dir: Path, force: bool = False) -> tuple[list[dict[str, Any]], str, str]:
    if os.environ.get("CLAUDE_USAGE_SKIP_QUOTA") == "1":
        return [], "", ""
    cache_file = base_dir / "cache" / "quota_usage_cache.json"
    cache_file.parent.mkdir(parents=True, exist_ok=True)

    plan_tier = ""
    creds_file = base_dir / ".credentials.json"
    if creds_file.exists():
        try:
            creds = json.loads(creds_file.read_text(encoding="utf-8")).get("claudeAiOauth", {})
            plan_tier = str(creds.get("subscriptionType") or "").capitalize()
        except Exception:
            pass

    if not force and cache_file.exists():
        try:
            age = time.time() - cache_file.stat().st_mtime
            if age < 60:
                with open(cache_file, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                    if isinstance(cached, dict) and "groups" in cached and cached["groups"]:
                        return cached.get("groups", []), cached.get("planTier", plan_tier), ""
        except Exception:
            pass

    buckets: list[dict[str, Any]] = []

    # 1. Read quota via direct OAuth API (does not launch `claude -p` which spawns phantom sessions)
    if creds_file.exists():
        try:
            creds = json.loads(creds_file.read_text(encoding="utf-8")).get("claudeAiOauth", {})
            token = creds.get("accessToken")
            if token:
                req = urllib.request.Request(
                    "https://api.anthropic.com/api/oauth/usage",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                        "User-Agent": "Claude-Code/2.1.283",
                    },
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    api_data = json.loads(resp.read().decode())
                configs = [
                    ("five_hour", "Current Session Remaining", "5h window"),
                    ("seven_day", "Weekly (all models) Remaining", "Weekly (7-day)"),
                    ("seven_day_sonnet", "Weekly (Sonnet) Remaining", "Weekly (Sonnet)"),
                    ("seven_day_opus", "Weekly (Opus) Remaining", "Weekly (Opus)"),
                ]
                for key, name_label, badge_label in configs:
                    win = api_data.get(key)
                    if isinstance(win, dict) and win.get("utilization") is not None:
                        used = float(win["utilization"])
                        rem_pct = max(0.0, 100.0 - used)
                        buckets.append({
                            "id": f"claude-{key}",
                            "name": name_label,
                            "label": badge_label,
                            "remainingFraction": rem_pct / 100.0,
                            "remainingPercent": round(rem_pct),
                            "usedPercent": round(used),
                            "resetTime": win.get("resets_at", ""),
                            "color": COLOR,
                        })
        except Exception:
            pass

    if buckets:
        groups = [{
            "name": "Claude Code Quota",
            "description": f"Subscription plan: {plan_tier}" if plan_tier else "Anthropic",
            "color": COLOR,
            "buckets": buckets,
        }]
        try:
            with open(cache_file, "w", encoding="utf-8") as f:
                json.dump({"groups": groups, "planTier": plan_tier}, f)
        except Exception:
            pass
        return groups, plan_tier, ""

    if cache_file.exists():
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                cached = json.load(f)
                return cached.get("groups", []), cached.get("planTier", plan_tier), ""
        except Exception:
            pass

    return [], plan_tier, ""


def scan(base: Path, force: bool = False, notify_threshold: int | None = None) -> dict:
    today = dt.date.today()
    week = {str(today - dt.timedelta(days=i)) for i in range(7)}
    daily_prompts: Counter = Counter()
    daily_steps: Counter = Counter()
    models: dict[str, dict] = {}
    tools: Counter = Counter()
    sessions = []

    def bucket(name: str) -> dict:
        return models.setdefault(name, blank_model(name))

    def add_prompt(model: str, day: dt.date) -> None:
        row = bucket(model)
        key = str(day)
        row["prompts"] += 1
        daily_prompts[key] += 1
        if day == today:
            row["todayPrompts"] += 1
        if key in week:
            row["weekPrompts"] += 1

    def add_step(model: str, day: dt.date) -> None:
        row = bucket(model)
        key = str(day)
        row["steps"] += 1
        daily_steps[key] += 1
        if day == today:
            row["todaySteps"] += 1
        if key in week:
            row["weekSteps"] += 1

    projects = base / "projects"
    paths = projects.glob("**/*.jsonl") if projects.exists() else []
    for path in paths:
        prompts = 0
        tokens = 0
        updated = path.stat().st_mtime
        model = ""
        preview = ""
        cwd = ""
        # Subagent transcripts add steps and tokens but no user prompts, and
        # are not resumable sessions.
        is_subagent = path.parent.name == "subagents"
        pending: list[dt.date] = []
        try:
            for line in path.open(encoding="utf-8", errors="replace"):
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                message = row.get("message") or {}
                role = message.get("role") or row.get("role")
                day = local_day(stamp(row.get("timestamp")), updated)
                is_meta = bool(row.get("isMeta"))
                if not cwd and row.get("cwd"):
                    cwd = str(row["cwd"])
                user_text = prompt_text(message.get("content", row.get("content", ""))) if role == "user" and not is_meta and not is_subagent else None
                if user_text is not None:
                    prompts += 1
                    pending.append(day)
                    if not preview:
                        preview = user_text
                seen = message.get("model") or row.get("model") or ""
                if seen and seen != "<synthetic>":
                    clean = format_claude_model_name(str(seen))
                    if clean:
                        model = clean
                if role == "assistant" and model and seen != "<synthetic>":
                    add_step(model, day)
                    while pending:
                        add_prompt(model, pending.pop(0))
                usage = message.get("usage") or row.get("usage") or {}
                input_tokens = int(usage.get("input_tokens") or 0)
                output_tokens = int(usage.get("output_tokens") or 0)
                cached = int(usage.get("cache_read_input_tokens") or 0) + int(usage.get("cache_creation_input_tokens") or 0)
                piece = input_tokens + output_tokens + cached
                tokens += piece
                if piece and model:
                    target = bucket(model)
                    target["inputTokens"] += input_tokens
                    target["outputTokens"] += output_tokens
                    target["cachedTokens"] += cached
                content = message.get("content")
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tools[text(block.get("name"), 60)] += 1
        except OSError:
            continue
        if pending and model:
            for day in pending:
                add_prompt(model, day)
        if (prompts or tokens) and model and not is_subagent:
            sessions.append({
                "conversationId": path.stem,
                "title": preview or "Claude session",
                "preview": preview or "Claude session",
                "workspace": cwd,
                "workspaceName": Path(cwd).name if cwd else path.parent.name,
                "updated_at": dt.datetime.fromtimestamp(updated).isoformat(),
                "stepCount": prompts,
                "model": model,
                "tokenCount": tokens,
                "isActive": False,
            })

    if not sessions and (base / "sessions").exists():
        for path in (base / "sessions").glob("*.key"):
            try:
                updated = path.stat().st_mtime
            except OSError:
                continue
            sessions.append({
                "conversationId": path.stem,
                "title": "Claude session",
                "preview": "Local Claude session state",
                "workspace": "",
                "workspaceName": "Claude Code",
                "updated_at": dt.datetime.fromtimestamp(updated).isoformat(),
                "stepCount": 0,
                "model": "Claude",
                "tokenCount": 0,
                "isActive": False,
            })

    active_cwds = claude_active_cwds()
    active = bool(active_cwds)
    sessions.sort(key=lambda item: item["updated_at"], reverse=True)
    # A running claude process owns the newest session in its directory.
    for cwd in active_cwds:
        match = next((item for item in sessions if not item["isActive"] and (not cwd or item["workspace"] == cwd)), None)
        if match:
            match["isActive"] = True
    total_tokens = sum(item["tokenCount"] for item in sessions)
    total_prompts = sum(daily_prompts.values())
    total_steps = sum(daily_steps.values())
    model_list = sorted(models.values(), key=lambda item: (item["prompts"], item["steps"], item["name"]), reverse=True)

    # Fetch quota limits
    quota_groups, plan_tier, _ = fetch_claude_quota(base, force=force)
    burn_rates = update_quota_snapshots(base, quota_groups)

    limits_list = []
    for g in quota_groups:
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

    if notify_threshold is not None and quota_groups:
        check_and_send_quota_notifications(base, quota_groups, notify_threshold)

    has_stats = bool(sessions) or bool(quota_groups)
    tier_label = f"Anthropic ({plan_tier})" if plan_tier else "Anthropic"

    return {
        "ready": True,
        "active": active,
        "activeStatus": "Working" if active else "Idle",
        "hasActiveSession": active,
        "hasLocalStats": has_stats,
        "canKill": False,
        "tierLabel": tier_label,
        "currentModel": sessions[0]["model"] if sessions else "Claude",
        "todayPrompts": daily_prompts[str(today)],
        "todaySessions": sum(1 for item in sessions if str(item["updated_at"]).startswith(str(today))),
        "todaySteps": daily_steps[str(today)],
        "todayTotalTokens": total_tokens,
        "todayTokensByModel": {item["name"]: item["inputTokens"] + item["outputTokens"] + item["cachedTokens"] for item in model_list},
        "recentDays": recent_days(today, daily_prompts, daily_steps),
        "totalPrompts": total_prompts,
        "totalSessions": len(sessions),
        "totalSteps": total_steps,
        "activeSessions": [item for item in sessions if item["isActive"]],
        "recentSessions": sessions[:10],
        "toolUsage": dict(tools.most_common(12)),
        "modelUsage": {item["name"]: item for item in model_list},
        "modelList": model_list,
        "quotaGroups": quota_groups,
        "quotaNote": "" if quota_groups else QUOTA_NOTE,
        "limits": limits_list,
        "recentWorkspaces": [],
        "premiumRequests": 0,
        "planTier": plan_tier,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": dt.datetime.now(dt.timezone.utc).isoformat() if quota_groups else "",
        "quotaUpdatedMs": round(time.time() * 1000) if quota_groups else 0,
        "lastFullRefreshMs": round(time.time() * 1000),
        "usageStatusText": "" if has_stats else "No local activity found",
        "authHelpText": "",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--notify-low-quota", type=int, default=None)
    args = ap.parse_args()
    print(json.dumps(scan(BASE, force=args.force, notify_threshold=args.notify_low_quota), separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
