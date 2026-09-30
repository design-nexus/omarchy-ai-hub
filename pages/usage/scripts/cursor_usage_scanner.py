#!/usr/bin/env python3
"""Local Cursor Agent usage. Remaining allowance is not available from the CLI."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

DATA_HOME = Path(os.environ.get("CURSOR_DATA_HOME", Path.home() / ".cursor"))
CONFIG_HOME = Path(os.environ.get("CURSOR_CONFIG_HOME", Path.home() / ".config" / "cursor"))
COLOR = "#f54e00"
QUOTA_NOTE = "Remaining allowance is not available from the local CLI."
PERIOD_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
PLAN_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


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
        "title": "Cursor session",
        "preview": "",
        "workspace": "",
        "workspaceName": "Cursor",
        "updated_at": "",
        "updated_ts": 0.0,
        "stepCount": 0,
        "model": "",
        "tokenCount": 0,
        "isActive": False,
        "prompts": 0,
        "promptDay": None,
    }


def resolve_executable() -> str:
    for name in ("agent", "cursor-agent"):
        path = shutil.which(name)
        if not path:
            continue
        real = os.path.realpath(path)
        if name == "cursor-agent" or "cursor" in real.lower():
            return path
    return ""


def cursor_active(executable: str) -> bool:
    if not executable:
        return False
    real = os.path.realpath(executable)
    proc = Path("/proc")
    if not proc.exists():
        return False
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if os.path.realpath(entry / "exe") == real:
                return True
        except OSError:
            continue
    return False


def iso_from_epoch(value) -> str:
    try:
        number = float(value or 0)
    except (TypeError, ValueError):
        return ""
    if number > 1e12:
        number /= 1000
    if number <= 0:
        return ""
    return dt.datetime.fromtimestamp(number, dt.timezone.utc).isoformat()


def quota_from_cursor_period(period: dict, plan_info: dict | None = None) -> tuple[list[dict], str]:
    info = {}
    if isinstance(plan_info, dict):
        nested = plan_info.get("planInfo") or plan_info.get("plan_info") or plan_info
        if isinstance(nested, dict):
            info = nested
    tier = str(info.get("planName") or info.get("plan_name") or "")
    usage = period.get("planUsage") or period.get("plan_usage") or {}
    if not isinstance(usage, dict):
        usage = {}
    reset_time = iso_from_epoch(period.get("billingCycleEnd") or info.get("billingCycleEnd"))
    message = str(period.get("displayMessage") or "")

    def bucket(bucket_id: str, label: str, percent_used, detail: str = "") -> dict | None:
        try:
            used = float(percent_used)
        except (TypeError, ValueError):
            return None
        remaining = max(0.0, min(100.0, 100.0 - used))
        return {
            "id": bucket_id,
            "name": label,
            "label": label,
            "remainingFraction": remaining / 100.0,
            "remainingPercent": round(remaining),
            "usedPercent": round(used),
            "resetTime": reset_time,
            "forecastText": detail,
            "color": COLOR,
        }

    total = bucket("cursor-included", "Included usage", usage.get("totalPercentUsed"), message)
    auto = bucket("cursor-auto", "Auto models", usage.get("autoPercentUsed"), str(period.get("autoModelSelectedDisplayMessage") or ""))
    api = bucket("cursor-api", "API models", usage.get("apiPercentUsed"), str(period.get("namedModelSelectedDisplayMessage") or ""))
    buckets = []
    if total:
        buckets.append(total)
    if auto and (not total or auto["usedPercent"] != total["usedPercent"]):
        buckets.append(auto)
    if api and (not total or api["usedPercent"] != total["usedPercent"]):
        buckets.append(api)
    if not buckets:
        return [], tier
    return [{"name": "Cursor", "buckets": buckets}], tier


def cursor_access_token(config_home: Path) -> str:
    path = config_home / "auth.json"
    if not path.exists():
        path = Path.home() / ".config" / "cursor" / "auth.json"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(payload, dict):
        return ""
    return str(payload.get("accessToken") or "").strip()


def cursor_post(url: str, token: str) -> dict:
    request = urllib.request.Request(url, data=b"{}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
    })
    with urllib.request.urlopen(request, timeout=12) as response:
        payload = json.loads(response.read().decode("utf-8", errors="replace"))
    return payload if isinstance(payload, dict) else {}


def fetch_cursor_quota(data_home: Path, config_home: Path) -> tuple[list[dict], str, str]:
    if os.environ.get("CURSOR_USAGE_SKIP_QUOTA") == "1":
        return [], "", ""
    cache = data_home / "cache" / "quota_usage_cache.json"
    if cache.exists():
        try:
            age = dt.datetime.now(dt.timezone.utc).timestamp() - cache.stat().st_mtime
            if age < 180:
                cached = json.loads(cache.read_text(encoding="utf-8"))
                groups = cached.get("groups") if isinstance(cached, dict) else None
                if groups:
                    return groups, str(cached.get("tier") or ""), ""
        except (OSError, ValueError, TypeError):
            pass
    token = cursor_access_token(config_home)
    if not token:
        return [], "", "No Cursor sign-in. Run `agent login`."
    try:
        period = cursor_post(PERIOD_URL, token)
        plan_info = cursor_post(PLAN_URL, token)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return [], "", "Cursor sign-in expired. Run `agent login`."
        return [], "", f"Cursor quota returned status {error.code}"
    except (OSError, ValueError, urllib.error.URLError) as exc:
        return [], "", str(exc)
    groups, tier = quota_from_cursor_period(period, plan_info)
    if groups:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"groups": groups, "tier": tier}), encoding="utf-8")
        except OSError:
            pass
    return groups, tier, ""


def plan_tier(executable: str, data_home: Path) -> str:
    if os.environ.get("CURSOR_USAGE_SKIP_ABOUT") == "1":
        return ""
    cache = data_home / "ai-usage-plan-tier.cache"
    try:
        cached = json.loads(cache.read_text(encoding="utf-8"))
        age = dt.datetime.now(dt.timezone.utc).timestamp() - float(cached.get("checkedAt") or 0)
        if 0 <= age < 6 * 60 * 60:
            return clip(cached.get("tier") or "", 40)
    except (OSError, ValueError, TypeError):
        pass
    tier = ""
    if executable:
        try:
            run = subprocess.run([executable, "about"], capture_output=True, text=True, timeout=4)
        except (OSError, subprocess.TimeoutExpired):
            run = None
        if run is not None:
            for line in (run.stdout or "").splitlines():
                if "Subscription Tier" not in line:
                    continue
                tier = clip(line.split("Subscription Tier", 1)[-1].strip(" :\t"), 40)
                break
    try:
        cache.write_text(json.dumps({"tier": tier, "checkedAt": dt.datetime.now(dt.timezone.utc).timestamp()}), encoding="utf-8")
    except OSError:
        pass
    return tier


def content_text(content) -> str:
    if isinstance(content, str):
        return clip(content)
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") in (None, "text"):
                parts.append(str(block.get("text") or ""))
        return clip(" ".join(parts))
    if isinstance(content, dict):
        return clip(content.get("text") or content.get("content") or "")
    return ""


def message_of(obj: dict) -> tuple[str, dict]:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else obj
    role = str(obj.get("role") or message.get("role") or obj.get("type") or "")
    return role, message


def read_jsonl(path: Path, session: dict, tools: Counter, models: dict[str, dict], daily_prompts: Counter, daily_steps: Counter, today: dt.date, week: set[str]) -> None:
    when = session["updated_ts"] or path.stat().st_mtime
    try:
        handle = path.open(encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for index, line in enumerate(handle):
            if index >= 8000:
                break
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            role, message = message_of(obj)
            model = str(message.get("model") or obj.get("model") or "")
            if model:
                session["model"] = model
            usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else {}
            if not usage and isinstance(message.get("usage"), dict):
                usage = message["usage"]
            input_tokens = int(usage.get("input_tokens") or usage.get("inputTokens") or 0)
            output_tokens = int(usage.get("output_tokens") or usage.get("outputTokens") or 0)
            cached = int(usage.get("cache_read_input_tokens") or usage.get("cacheReadTokens") or 0)
            cached += int(usage.get("cache_creation_input_tokens") or usage.get("cacheWriteTokens") or 0)
            if input_tokens or output_tokens or cached:
                target_name = model or session["model"] or "Cursor"
                row = models.setdefault(target_name, blank_model(target_name))
                row["inputTokens"] += input_tokens
                row["outputTokens"] += output_tokens
                row["cachedTokens"] += cached
                session["tokenCount"] += input_tokens + output_tokens + cached
            content = message.get("content", obj.get("content"))
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name"):
                        tools[clip(block.get("name"), 60)] += 1
            if role == "user":
                preview = content_text(content)
                if preview.startswith("<user_query>"):
                    preview = preview[len("<user_query>"):]
                if preview and not session["preview"]:
                    session["preview"] = preview
                session["prompts"] += 1
            elif role == "assistant":
                session["steps"] = session.get("steps", 0) + 1
    session["promptDay"] = local_day(when) or today
    if not session["updated_ts"]:
        session["updated_ts"] = when


def account_prompts(session: dict, models: dict[str, dict], daily_prompts: Counter, daily_steps: Counter, today: dt.date, week: set[str]) -> None:
    count = int(session.get("prompts") or 0)
    if count <= 0:
        return
    model = session["model"] or "Unknown"
    row = models.setdefault(model, blank_model(model))
    day = session["promptDay"] or today
    key = str(day)
    steps = max(int(session.get("steps") or 0), count)
    row["prompts"] += count
    row["steps"] += steps
    daily_prompts[key] += count
    daily_steps[key] += steps
    if day == today:
        row["todayPrompts"] += count
        row["todaySteps"] += steps
    if key in week:
        row["weekPrompts"] += count
        row["weekSteps"] += steps
    session["stepCount"] = count


def read_meta(path: Path, sessions: dict[str, dict]) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return
    if not isinstance(data, dict):
        return
    session_id = path.parent.name
    updated = stamp(data.get("updatedAtMs") or data.get("updatedAt"))
    created = stamp(data.get("createdAtMs") or data.get("createdAt"))
    prompts = path.parent / "prompt_history.json"
    prompt_count = 0
    preview = ""
    if prompts.exists():
        try:
            history = json.loads(prompts.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            history = []
        if isinstance(history, list):
            prompt_count = len(history)
            if history and isinstance(history[0], str):
                preview = clip(history[0])
    if data.get("hasConversation") is False and prompt_count == 0 and not (path.parent / "store.db").exists():
        return
    session = sessions.setdefault(session_id, blank_session(session_id))
    session["workspace"] = session["workspace"] or str(data.get("cwd") or "")
    session["updated_ts"] = max(session["updated_ts"], updated or created or path.stat().st_mtime)
    if preview and not session["preview"]:
        session["preview"] = preview
    if prompt_count:
        session["historyPrompts"] = prompt_count


def quoted(name: str) -> str:
    if not IDENT.match(name):
        raise ValueError(name)
    return '"' + name + '"'


def read_store(path: Path, session: dict) -> None:
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error:
        return
    try:
        tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for table in tables:
            try:
                table_sql = quoted(table)
                columns = connection.execute(f"PRAGMA table_info({table_sql})").fetchall()
            except (sqlite3.Error, ValueError):
                continue
            by_lower = {}
            for _cid, name, col_type, *_rest in columns:
                if str(col_type or "").upper() == "BLOB":
                    continue
                by_lower[str(name).lower()] = str(name)
            id_col = next((by_lower[key] for key in ("id", "conversationid", "chatid", "sessionid") if key in by_lower), "")
            title_col = next((by_lower[key] for key in ("title", "name", "summary") if key in by_lower), "")
            model_col = by_lower.get("model", "")
            if not id_col or not (title_col or model_col):
                continue
            selected = [id_col]
            if title_col:
                selected.append(title_col)
            if model_col:
                selected.append(model_col)
            try:
                sql = "SELECT " + ", ".join(quoted(col) for col in selected) + f" FROM {table_sql} LIMIT 200"
                rows = connection.execute(sql)
            except (sqlite3.Error, ValueError):
                continue
            for row in rows:
                if str(row[0]) != session["conversationId"]:
                    continue
                cursor = 1
                if title_col:
                    title = clip(row[cursor])
                    cursor += 1
                    if title and session["title"] == "Cursor session":
                        session["title"] = title
                if model_col:
                    model = clip(row[cursor], 80)
                    if model and not session["model"]:
                        session["model"] = model
    finally:
        connection.close()


def read_tracking(path: Path, sessions: dict[str, dict]) -> None:
    if not path.exists():
        return
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error:
        return
    try:
        try:
            rows = connection.execute(
                "SELECT conversationId, title, model, updatedAt FROM conversation_summaries"
            )
        except sqlite3.Error:
            rows = []
        for conversation_id, title, model, updated_at in rows:
            if not conversation_id:
                continue
            session = sessions.setdefault(str(conversation_id), blank_session(str(conversation_id)))
            if title and session["title"] == "Cursor session":
                session["title"] = clip(title)
            if model and not session["model"]:
                session["model"] = clip(model, 80)
            updated = stamp(updated_at)
            if updated:
                session["updated_ts"] = max(session["updated_ts"], updated)
        try:
            hashes = connection.execute(
                "SELECT conversationId, model, timestamp FROM ai_code_hashes"
            )
        except sqlite3.Error:
            hashes = []
        for conversation_id, model, timestamp in hashes:
            session = sessions.get(str(conversation_id or ""))
            if session and model and not session["model"]:
                session["model"] = clip(model, 80)
            if session and timestamp and not session["updated_ts"]:
                session["updated_ts"] = stamp(timestamp)
    finally:
        connection.close()


def transcript_id(path: Path) -> str:
    if path.suffix == ".jsonl" and path.stem == path.parent.name:
        return path.parent.name
    return path.stem


def scan(data_home: Path, config_home: Path) -> dict:
    today = dt.date.today()
    week = {str(today - dt.timedelta(days=i)) for i in range(7)}
    sessions: dict[str, dict] = {}
    tools: Counter = Counter()
    models: dict[str, dict] = {}
    daily_prompts: Counter = Counter()
    daily_steps: Counter = Counter()
    for root in (config_home / "chats", data_home / "chats"):
        if root.exists():
            for meta in root.glob("*/*/meta.json"):
                read_meta(meta, sessions)
    transcripts = []
    projects = data_home / "projects"
    if projects.exists():
        transcripts.extend(projects.glob("*/agent-transcripts/*/*.jsonl"))
        transcripts.extend(path for path in projects.glob("*/agent-transcripts/*.jsonl"))
        transcripts.extend(path for path in projects.glob("*/agent-transcripts/*/*.txt"))
        transcripts.extend(path for path in projects.glob("*/agent-transcripts/*.txt"))
    jsonl_ids = {transcript_id(path) for path in transcripts if path.suffix == ".jsonl"}
    for path in transcripts:
        if path.suffix == ".txt" and transcript_id(path) in jsonl_ids:
            continue
        session = sessions.setdefault(transcript_id(path), blank_session(transcript_id(path)))
        if path.suffix == ".jsonl":
            read_jsonl(path, session, tools, models, daily_prompts, daily_steps, today, week)
        elif not session["prompts"]:
            try:
                user_lines = [line for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.startswith("user:")]
            except OSError:
                user_lines = []
            session["prompts"] = len(user_lines)
            session["promptDay"] = local_day(path.stat().st_mtime) or today
            session["updated_ts"] = max(session["updated_ts"], path.stat().st_mtime)
            if user_lines and not session["preview"]:
                session["preview"] = clip(user_lines[0].split(":", 1)[-1])
    for root in (config_home / "chats", data_home / "chats"):
        if not root.exists():
            continue
        for database in root.glob("*/*/store.db"):
            session = sessions.get(database.parent.name)
            if session:
                read_store(database, session)
    read_tracking(data_home / "ai-tracking" / "ai-code-tracking.db", sessions)
    visible = []
    counted = set()
    for session in sessions.values():
        if not session["prompts"] and session.get("historyPrompts"):
            session["prompts"] = session["historyPrompts"]
            session["promptDay"] = session["promptDay"] or local_day(session["updated_ts"]) or today
        if session["conversationId"] not in counted:
            account_prompts(session, models, daily_prompts, daily_steps, today, week)
            counted.add(session["conversationId"])
        if session["workspace"]:
            session["workspaceName"] = Path(session["workspace"]).name or "Cursor"
        if session["preview"] and session["title"] == "Cursor session":
            session["title"] = session["preview"]
        if not session["preview"]:
            session["preview"] = session["title"]
        if session["updated_ts"]:
            session["updated_at"] = dt.datetime.fromtimestamp(session["updated_ts"]).isoformat()
        session.pop("promptDay", None)
        session.pop("historyPrompts", None)
        session.pop("prompts", None)
        session.pop("steps", None)
        session.pop("updated_ts", None)
        visible.append(session)
    executable = resolve_executable()
    active = cursor_active(executable)
    visible.sort(key=lambda item: item.get("updated_at") or "", reverse=True)
    if active and visible:
        visible[0]["isActive"] = True
    groups, quota_tier, quota_error = fetch_cursor_quota(data_home, config_home)
    tier = quota_tier or plan_tier(executable, data_home)
    model_list = sorted(models.values(), key=lambda item: (item["prompts"], item["steps"], item["name"]), reverse=True)
    days = []
    for offset in range(6, -1, -1):
        day = str(today - dt.timedelta(days=offset))
        days.append({
            "date": day,
            "messageCount": daily_prompts[day],
            "prompts": daily_prompts[day],
            "steps": daily_steps[day],
        })
    current = ""
    for session in visible:
        if session.get("model"):
            current = session["model"]
            break
    return {
        "ready": True,
        "active": active,
        "activeStatus": "Working" if active else "Idle",
        "hasActiveSession": active,
        "hasLocalStats": bool(visible),
        "canKill": False,
        "tierLabel": tier or "Cursor",
        "planTier": tier,
        "currentModel": current or "Cursor",
        "todayPrompts": daily_prompts[str(today)],
        "todaySessions": sum(1 for item in visible if str(item.get("updated_at", "")).startswith(str(today))),
        "todaySteps": daily_steps[str(today)],
        "todayTotalTokens": sum(item["tokenCount"] for item in visible),
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
        "premiumRequests": 0,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": "",
        "usageStatusText": "",
        "authHelpText": "",
        "display": {
            "name": "Cursor",
            "color": COLOR,
            "executable": Path(executable).name if executable else "agent",
        },
    }


def main() -> None:
    print(json.dumps(scan(DATA_HOME, CONFIG_HOME), separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
