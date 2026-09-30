#!/usr/bin/env python3
"""Local GitHub Copilot CLI usage. Monthly allowance is not queried."""
from __future__ import annotations

import datetime as dt
import json
import os
import sqlite3
import subprocess
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

HOME = Path(os.environ.get("COPILOT_HOME", Path.home() / ".copilot"))
COLOR = "#1f6feb"
QUOTA_NOTE = "Monthly allowance is not stored locally."
QUOTA_URL = "https://api.github.com/copilot_internal/user"
QUOTA_LABELS = {
    "chat": "Chat",
    "completions": "Completions",
    "premium_interactions": "Premium requests",
}


def stamp(value) -> float:
    if isinstance(value, (int, float)):
        number = float(value)
        return number / 1000 if number > 1e12 else number
    if isinstance(value, str) and value:
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return 0
    return 0


def local_day(timestamp: float) -> dt.date | None:
    if not timestamp:
        return None
    return dt.datetime.fromtimestamp(timestamp).date()


def clip(value, limit: int = 140) -> str:
    return " ".join(str(value or "").replace("\x00", "").split())[:limit]


def preview_from(data: dict) -> str:
    content = data.get("content", data.get("text", data.get("message", "")))
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                parts.append(str(block.get("text") or block.get("content") or ""))
        content = " ".join(parts)
    elif isinstance(content, dict):
        content = content.get("text") or content.get("content") or ""
    return clip(content)


def is_child(data: dict) -> bool:
    context = data.get("context") if isinstance(data.get("context"), dict) else {}
    return bool(data.get("parentSessionId") or context.get("parentSessionId"))


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


def blank_session(session_id: str) -> dict:
    return {
        "conversationId": session_id,
        "title": "Copilot session",
        "preview": "",
        "workspace": "",
        "workspaceName": "Copilot",
        "updated_at": "",
        "updated_ts": 0.0,
        "stepCount": 0,
        "model": "",
        "tokenCount": 0,
        "isActive": False,
        "prompts": 0,
        "promptDays": [],
        "requestCounts": Counter(),
        "child": False,
    }


def github_token() -> str:
    for name in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    try:
        run = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if run.returncode != 0:
        return ""
    return run.stdout.strip()


def quota_from_copilot_user(payload: dict) -> tuple[list[dict], str]:
    sku = str(payload.get("access_type_sku") or "")
    plan = str(payload.get("copilot_plan") or "")
    if "free" in sku or plan == "free":
        tier = "Free"
    else:
        tier = plan.replace("_", " ").title() if plan else "Copilot"
    buckets = []
    snapshots = payload.get("quota_snapshots") if isinstance(payload.get("quota_snapshots"), dict) else {}
    for key, snap in snapshots.items():
        if not isinstance(snap, dict):
            continue
        unlimited = bool(snap.get("unlimited"))
        try:
            entitlement = float(snap.get("entitlement") or 0)
        except (TypeError, ValueError):
            entitlement = 0
        if not unlimited and entitlement <= 0:
            continue
        try:
            remaining_pct = float(snap.get("percent_remaining") or 0)
        except (TypeError, ValueError):
            remaining_pct = 0
        remaining_pct = max(0.0, min(100.0, remaining_pct))
        try:
            remaining = int(float(snap.get("remaining") or 0))
        except (TypeError, ValueError):
            remaining = 0
        label = QUOTA_LABELS.get(str(key), str(key).replace("_", " ").title())
        reset_raw = snap.get("quota_reset_at") or 0
        reset_time = ""
        try:
            reset_num = float(reset_raw or 0)
        except (TypeError, ValueError):
            reset_num = 0
        if reset_num > 1e12:
            reset_num /= 1000
        if reset_num > 0:
            reset_time = dt.datetime.fromtimestamp(reset_num, dt.timezone.utc).isoformat()
        detail = "Unlimited" if unlimited else f"{remaining} of {int(entitlement)} left"
        buckets.append({
            "id": f"copilot-{key}",
            "name": label,
            "label": label,
            "remainingFraction": 1.0 if unlimited else remaining_pct / 100.0,
            "remainingPercent": 100 if unlimited else round(remaining_pct),
            "usedPercent": 0 if unlimited else round(100 - remaining_pct),
            "resetTime": reset_time,
            "forecastText": detail,
            "color": COLOR,
        })
    if not buckets:
        return [], tier
    return [{"name": "Copilot", "buckets": buckets}], tier


def fetch_copilot_quota(home: Path) -> tuple[list[dict], str, str]:
    if os.environ.get("COPILOT_USAGE_SKIP_QUOTA") == "1":
        return [], "", ""
    cache = home / "cache" / "quota_usage_cache.json"
    if cache.exists():
        try:
            if time_age(cache) < 180:
                cached = json.loads(cache.read_text(encoding="utf-8"))
                groups = cached.get("groups") if isinstance(cached, dict) else None
                if groups:
                    return groups, str(cached.get("tier") or ""), ""
        except (OSError, ValueError, TypeError):
            pass
    token = github_token()
    if not token:
        return [], "", "No GitHub token. Run `gh auth login`."
    request = urllib.request.Request(QUOTA_URL, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "GitHubCopilotChat/1.0.0",
        "Editor-Version": "vscode/1.96.0",
        "Editor-Plugin-Version": "copilot-chat/0.26.0",
        "Copilot-Integration-Id": "vscode-chat",
    })
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return [], "", "GitHub sign-in cannot read Copilot quota. Run `gh auth login`."
        return [], "", f"Copilot quota returned status {error.code}"
    except (OSError, ValueError, urllib.error.URLError) as exc:
        return [], "", str(exc)
    if not isinstance(payload, dict):
        return [], "", "Copilot quota response was empty"
    groups, tier = quota_from_copilot_user(payload)
    if groups:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"groups": groups, "tier": tier}), encoding="utf-8")
        except OSError:
            pass
    return groups, tier, ""


def time_age(path: Path) -> float:
    return dt.datetime.now(dt.timezone.utc).timestamp() - path.stat().st_mtime


def copilot_active() -> bool:
    try:
        return bool(subprocess.run(["pgrep", "-x", "copilot"], capture_output=True, timeout=1).stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def read_events(home: Path) -> tuple[dict[str, dict], Counter, int, dict]:
    sessions: dict[str, dict] = {}
    tools: Counter = Counter()
    premium = 0
    code = {"linesAdded": 0, "linesRemoved": 0, "filesModified": 0}
    root = home / "session-state"
    if not root.exists():
        return sessions, tools, premium, code
    for path in root.glob("*/events.jsonl"):
        session_id = path.parent.name
        session = sessions.setdefault(session_id, blank_session(session_id))
        try:
            lines = path.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        with lines:
            for index, line in enumerate(lines):
                if index >= 20000:
                    break
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                data = event.get("data") if isinstance(event.get("data"), dict) else {}
                kind = str(event.get("type") or "")
                if kind == "session.start":
                    if is_child(data):
                        session["child"] = True
                        break
                    context = data.get("context") if isinstance(data.get("context"), dict) else {}
                    session["workspace"] = session["workspace"] or str(context.get("cwd") or data.get("cwd") or "")
                    started = stamp(data.get("startTime"))
                    if started and not session["updated_ts"]:
                        session["updated_ts"] = started
                    model = data.get("model") or data.get("newModel") or ""
                    if model and not session["model"]:
                        session["model"] = str(model)
                elif session["child"]:
                    break
                elif kind == "session.model_change":
                    model = data.get("newModel") or data.get("model") or ""
                    if model:
                        session["model"] = str(model)
                elif kind == "user.message":
                    session["prompts"] += 1
                    when = stamp(data.get("timestamp") or event.get("timestamp")) or session["updated_ts"]
                    day = local_day(when)
                    if day:
                        session["promptDays"].append(day)
                    if not session["preview"]:
                        session["preview"] = preview_from(data)
                elif "tool" in kind:
                    name = data.get("toolName") or data.get("tool_name") or data.get("name") or ""
                    if name:
                        tools[clip(name, 60)] += 1
                elif kind == "session.shutdown":
                    try:
                        premium += int(data.get("totalPremiumRequests") or 0)
                    except (TypeError, ValueError):
                        pass
                    changes = data.get("codeChanges") if isinstance(data.get("codeChanges"), dict) else {}
                    for key in code:
                        try:
                            code[key] += int(changes.get(key) or 0)
                        except (TypeError, ValueError):
                            pass
                    ended = stamp(data.get("timestamp") or data.get("sessionStartTime"))
                    if ended:
                        session["updated_ts"] = max(session["updated_ts"], ended)
                    metrics = data.get("modelMetrics") if isinstance(data.get("modelMetrics"), dict) else {}
                    session["metrics"] = metrics
    return sessions, tools, premium, code


def read_database(home: Path, sessions: dict[str, dict], tools: Counter) -> list[dict]:
    path = home / "session-store.db"
    usage_rows = []
    if not path.exists():
        return usage_rows
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error:
        return usage_rows
    try:
        try:
            rows = connection.execute(
                "SELECT id, cwd, summary, created_at, updated_at FROM sessions"
            )
        except sqlite3.Error:
            rows = []
        for session_id, cwd, summary, created_at, updated_at in rows:
            session = sessions.setdefault(str(session_id), blank_session(str(session_id)))
            session["workspace"] = session["workspace"] or str(cwd or "")
            if summary and session["title"] == "Copilot session":
                session["title"] = clip(summary)
            if not session["preview"] and summary:
                session["preview"] = clip(summary)
            updated = stamp(updated_at) or stamp(created_at)
            if updated:
                session["updated_ts"] = max(session["updated_ts"], updated)
        try:
            for name, count in connection.execute(
                "SELECT tool_name, COUNT(*) FROM session_files "
                "WHERE tool_name IS NOT NULL AND tool_name != '' GROUP BY tool_name"
            ):
                tools[clip(name, 60)] += int(count or 0)
        except sqlite3.Error:
            pass
        try:
            usage_rows = list(connection.execute(
                "SELECT session_id, model, input_tokens, output_tokens, cache_read_tokens, "
                "cache_write_tokens, created_at FROM assistant_usage_events"
            ))
        except sqlite3.Error:
            usage_rows = []
    finally:
        connection.close()
    return usage_rows


def read_legacy(home: Path, sessions: dict[str, dict]) -> None:
    root = home / "history-session-state"
    if not root.exists():
        return
    for path in root.glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or is_child(data):
            continue
        session_id = str(data.get("sessionId") or path.stem)
        session = sessions.setdefault(session_id, blank_session(session_id))
        context = data.get("context") if isinstance(data.get("context"), dict) else {}
        session["workspace"] = session["workspace"] or str(data.get("cwd") or context.get("cwd") or "")
        title = data.get("summary") or data.get("title") or ""
        if title and not session["preview"]:
            session["preview"] = clip(title)
            session["title"] = clip(title)
        updated = stamp(data.get("updatedAt") or data.get("updated_at")) or path.stat().st_mtime
        session["updated_ts"] = max(session["updated_ts"], updated)


def apply_metrics(session: dict, models: dict[str, dict], today: dt.date, week: set[str]) -> None:
    metrics = session.get("metrics") if isinstance(session.get("metrics"), dict) else {}
    when = local_day(session["updated_ts"]) or today
    key = str(when)
    for name, entry in metrics.items():
        if not isinstance(entry, dict):
            continue
        usage = entry.get("usage") if isinstance(entry.get("usage"), dict) else {}
        requests = entry.get("requests") if isinstance(entry.get("requests"), dict) else {}
        try:
            count = int(requests.get("count") or 0)
        except (TypeError, ValueError):
            count = 0
        if count:
            session["requestCounts"][str(name)] += count
        row = models.setdefault(str(name), blank_model(str(name)))
        input_tokens = int(usage.get("inputTokens") or usage.get("input_tokens") or 0)
        output_tokens = int(usage.get("outputTokens") or usage.get("output_tokens") or 0)
        cached = int(usage.get("cacheReadTokens") or usage.get("cache_read_tokens") or 0)
        cached += int(usage.get("cacheWriteTokens") or usage.get("cache_write_tokens") or 0)
        row["inputTokens"] += input_tokens
        row["outputTokens"] += output_tokens
        row["cachedTokens"] += cached
        session["tokenCount"] += input_tokens + output_tokens + cached
        if not session["model"]:
            session["model"] = str(name)
        if key in week:
            row["weekSteps"] += max(count, 0)
        if when == today:
            row["todaySteps"] += max(count, 0)
        row["steps"] += max(count, 1 if (input_tokens or output_tokens) else 0)


def apply_usage_rows(rows: list, sessions: dict[str, dict], models: dict[str, dict], today: dt.date, week: set[str]) -> set[str]:
    seen = set()
    for session_id, model, input_tokens, output_tokens, cache_read, cache_write, created_at in rows:
        seen.add(str(session_id))
        name = str(model or "Copilot")
        row = models.setdefault(name, blank_model(name))
        incoming = int(input_tokens or 0)
        outgoing = int(output_tokens or 0)
        cached = int(cache_read or 0) + int(cache_write or 0)
        row["inputTokens"] += incoming
        row["outputTokens"] += outgoing
        row["cachedTokens"] += cached
        row["steps"] += 1
        when = local_day(stamp(created_at)) or today
        if when == today:
            row["todaySteps"] += 1
        if str(when) in week:
            row["weekSteps"] += 1
        session = sessions.setdefault(str(session_id), blank_session(str(session_id)))
        session["tokenCount"] += incoming + outgoing + cached
        session["model"] = session["model"] or name
        session["updated_ts"] = max(session["updated_ts"], stamp(created_at))
    return seen


def add_prompts(model: str, days: list[dt.date], models: dict[str, dict], daily_prompts: Counter, daily_steps: Counter, today: dt.date, week: set[str]) -> None:
    row = models.setdefault(model, blank_model(model))
    for day in days:
        key = str(day)
        row["prompts"] += 1
        daily_prompts[key] += 1
        if day == today:
            row["todayPrompts"] += 1
        if key in week:
            row["weekPrompts"] += 1


def scan(home: Path) -> dict:
    today = dt.date.today()
    week = {str(today - dt.timedelta(days=i)) for i in range(7)}
    sessions, tools, premium, code = read_events(home)
    usage_rows = read_database(home, sessions, tools)
    read_legacy(home, sessions)
    models: dict[str, dict] = {}
    token_sessions = apply_usage_rows(usage_rows, sessions, models, today, week)
    daily_prompts: Counter = Counter()
    daily_steps: Counter = Counter()
    visible = []
    for session in sessions.values():
        if session["child"]:
            continue
        if session["conversationId"] not in token_sessions:
            apply_metrics(session, models, today, week)
        model = session["model"] or "Copilot"
        if session["prompts"]:
            days = session["promptDays"] or [local_day(session["updated_ts"]) or today]
            add_prompts(model, days, models, daily_prompts, daily_steps, today, week)
            row = models[model]
            if row["steps"] < row["prompts"]:
                row["steps"] = row["prompts"]
                row["todaySteps"] = max(row["todaySteps"], row["todayPrompts"])
                row["weekSteps"] = max(row["weekSteps"], row["weekPrompts"])
                daily_steps[str(days[-1])] += session["prompts"]
        elif session["requestCounts"]:
            for name, count in session["requestCounts"].items():
                when = local_day(session["updated_ts"]) or today
                add_prompts(name, [when] * count, models, daily_prompts, daily_steps, today, week)
        if session["workspace"]:
            session["workspaceName"] = Path(session["workspace"]).name or "Copilot"
        if session["preview"]:
            session["title"] = session["preview"]
        session["stepCount"] = session["prompts"] or sum(session["requestCounts"].values())
        if session["updated_ts"]:
            session["updated_at"] = dt.datetime.fromtimestamp(session["updated_ts"]).isoformat()
        elif not session["updated_at"]:
            session["updated_at"] = ""
        visible.append(session)
    active = copilot_active()
    visible.sort(key=lambda item: item.get("updated_ts") or 0, reverse=True)
    if active and visible:
        visible[0]["isActive"] = True
    for session in visible:
        session.pop("promptDays", None)
        session.pop("requestCounts", None)
        session.pop("metrics", None)
        session.pop("child", None)
        session.pop("prompts", None)
        session.pop("updated_ts", None)
    model_list = sorted(models.values(), key=lambda item: (item["prompts"], item["steps"], item["name"]), reverse=True)
    total_tokens = sum(item["tokenCount"] for item in visible)
    days = []
    for offset in range(6, -1, -1):
        day = str(today - dt.timedelta(days=offset))
        days.append({
            "date": day,
            "messageCount": daily_prompts[day],
            "prompts": daily_prompts[day],
            "steps": daily_steps[day],
        })
    has_stats = bool(visible) or bool(daily_prompts) or total_tokens > 0
    groups, tier, quota_error = fetch_copilot_quota(home)
    return {
        "ready": True,
        "active": active,
        "activeStatus": "Working" if active else "Idle",
        "hasActiveSession": active,
        "hasLocalStats": has_stats,
        "canKill": False,
        "tierLabel": tier or "GitHub Copilot",
        "currentModel": visible[0]["model"] if visible and visible[0].get("model") else "Copilot",
        "todayPrompts": daily_prompts[str(today)],
        "todaySessions": sum(1 for item in visible if str(item.get("updated_at", "")).startswith(str(today))),
        "todaySteps": daily_steps[str(today)],
        "todayTotalTokens": total_tokens,
        "todayTokensByModel": {item["name"]: item["inputTokens"] + item["outputTokens"] + item["cachedTokens"] for item in model_list},
        "recentDays": days,
        "totalPrompts": sum(daily_prompts.values()),
        "totalSessions": len(visible),
        "totalSteps": sum(daily_steps.values()),
        "activeSessions": [item for item in visible if item["isActive"]],
        "recentSessions": visible[:10],
        "toolUsage": dict(tools.most_common(12)),
        "modelUsage": {item["name"]: item for item in model_list},
        "modelList": model_list,
        "quotaGroups": groups,
        "quotaNote": "" if groups else (quota_error or QUOTA_NOTE),
        "limits": [],
        "recentWorkspaces": [],
        "premiumRequests": premium,
        "planTier": tier,
        "codeChanges": code,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": "",
        "usageStatusText": "",
        "authHelpText": "",
    }


def main() -> None:
    print(json.dumps(scan(HOME), separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
