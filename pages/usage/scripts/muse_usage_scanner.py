#!/usr/bin/env python3
"""Local Muse (Muse Code CLI) usage. Quota is not estimated from local data."""
from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
from collections import Counter
from pathlib import Path

DATA_HOME = Path(os.environ.get("MUSE_DATA_HOME", Path.home() / ".local" / "share" / "muse"))
COLOR = "#0082FB"
QUOTA_NOTE = "Muse quota is not estimated."


def stamp(value) -> float:
    if isinstance(value, (int, float)):
        number = float(value)
        return number / 1_000_000 if number > 1e12 else number
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


def format_muse_model_name(raw: str) -> str:
    name = (raw or "").strip()
    if not name:
        return ""
    low = name.lower()
    if low.startswith("muse-"):
        rest = name.split("-", 1)[1]
        parts = rest.replace("-", " ").split()
        titled = " ".join(part.upper() if len(part) <= 2 else part.capitalize() for part in parts)
        return "Muse " + titled
    return clip(name, 80)


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
        "todayTokens": 0,
        "todayCachedTokens": 0,
        "color": COLOR,
    }


def blank_session(session_id: str) -> dict:
    return {
        "conversationId": session_id,
        "title": "Muse session",
        "preview": "",
        "workspace": "",
        "workspaceName": "Muse",
        "updated_at": "",
        "updated_ts": 0.0,
        "stepCount": 0,
        "model": "",
        "tokenCount": 0,
        "isActive": False,
        "prompts": 0,
        "promptDay": None,
        # Prompts and steps by the local day they happened ("" when the record
        # had no time), so a session spanning days counts on each of them.
        "dayPrompts": {},
        "daySteps": {},
    }


def muse_active_cwds() -> list[str]:
    """Working directories of running muse processes (zombies excluded)."""
    try:
        out = subprocess.run(["pgrep", "-x", "muse"], capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    cwds = []
    for pid in out.split():
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as handle:
                state = handle.read().rsplit(")", 1)[-1].split()
            if len(state) > 0 and state[0] == "Z":
                continue
            cwds.append(os.readlink(f"/proc/{pid}/cwd"))
        except OSError:
            continue
    return cwds


def read_index(data_home: Path, sessions: dict[str, dict]) -> None:
    db = data_home / "session-index.db"
    if not db.exists():
        return
    try:
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
    except sqlite3.Error:
        return
    try:
        try:
            rows = connection.execute(
                "SELECT session_id, title, prompt_count, model_id, workspace_root,"
                " created_at_us, updated_at_us, first_user_prompt, session_log_path"
                " FROM sessions"
            ).fetchall()
        except sqlite3.Error:
            return
        for sid, title, prompt_count, model_id, workspace, created_us, updated_us, first_prompt, log_path in rows:
            if not sid:
                continue
            session = sessions.setdefault(str(sid), blank_session(str(sid)))
            title = clip(title)
            if title and title != "New session":
                session["title"] = title
            if workspace:
                session["workspace"] = str(workspace)
            try:
                count = int(prompt_count or 0)
            except (TypeError, ValueError):
                count = 0
            if count and not session.get("indexPrompts"):
                session["indexPrompts"] = count
            model = format_muse_model_name(str(model_id or ""))
            if model and not session["model"]:
                session["model"] = model
            updated = stamp(updated_us or 0) or stamp(created_us or 0)
            if updated:
                session["updated_ts"] = max(session["updated_ts"], updated)
            if first_prompt and not session["preview"]:
                session["preview"] = clip(first_prompt)
            if log_path:
                session["logPath"] = str(log_path)
    finally:
        connection.close()


def text_of(blocks) -> str:
    if isinstance(blocks, str):
        return blocks
    if isinstance(blocks, list):
        parts = []
        for block in blocks:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                if block.get("kind") == "text" and block.get("text"):
                    parts.append(str(block["text"]))
                elif isinstance(block.get("text"), str):
                    parts.append(block["text"])
        return " ".join(parts)
    return ""


def bump(counts: dict, when: float) -> None:
    key = str(local_day(when) or "")
    counts[key] = counts.get(key, 0) + 1


def read_transcript(path: Path, session: dict, tools: Counter, today: dt.date) -> None:
    try:
        handle = path.open(encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for index, line in enumerate(handle):
            if index >= 12000:
                break
            try:
                outer = json.loads(line)
            except ValueError:
                continue
            if not isinstance(outer, dict):
                continue
            records = [outer] if "payload_type" in outer else []
            children = outer.get("children")
            if isinstance(children, list):
                for child in children:
                    raw = child.get("record_json") if isinstance(child, dict) else None
                    if not raw:
                        continue
                    try:
                        rec = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(rec, dict) and "payload_type" in rec:
                        records.append(rec)
            for rec in records:
                payload_type = rec.get("payload_type")
                payload = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
                when = stamp(rec.get("recorded_at") or 0)
                if payload_type == "runtime.user_intent.accepted":
                    # Preview fallback only: the matching started event
                    # already counts the prompt, so this must not count again.
                    text = clip(text_of(payload.get("refill_blocks")))
                    if text and not session["preview"]:
                        session["preview"] = text
                elif payload_type == "run.model.configured":
                    record = payload.get("record") if isinstance(payload.get("record"), dict) else {}
                    model = format_muse_model_name(str(record.get("display_label") or record.get("model_id") or ""))
                    if model:
                        session["model"] = model
                elif payload_type == "tool_batch.effect.started":
                    record = payload.get("record") if isinstance(payload.get("record"), dict) else {}
                    tool = clip(record.get("tool_name") or "", 60)
                    if tool:
                        tools[tool] += 1
                        session["steps"] = session.get("steps", 0) + 1
                        bump(session["daySteps"], when)
                elif payload_type == "runtime.session":
                    event = payload.get("event") if isinstance(payload.get("event"), dict) else {}
                    kind = event.get("kind")
                    if kind == "started" and isinstance(event.get("prompt"), str) and event["prompt"].strip():
                        session["prompts"] += 1
                        bump(session["dayPrompts"], when)
                        if not session["preview"]:
                            session["preview"] = clip(event["prompt"])
                        day = local_day(when)
                        if day and (session["promptDay"] is None or when >= session.get("lastPromptTs", 0)):
                            session["promptDay"] = day
                            session["lastPromptTs"] = when
                    elif kind in ("assistant_message_committed", "assistant_tool_calls_committed"):
                        session["steps"] = session.get("steps", 0) + 1
                        bump(session["daySteps"], when)
    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = 0
    if mtime:
        session["updated_ts"] = max(session["updated_ts"], mtime)


def account_prompts(session: dict, models: dict[str, dict], daily_prompts: Counter, daily_steps: Counter, today: dt.date, week: set[str]) -> None:
    count = int(session.get("prompts") or session.get("indexPrompts") or 0)
    if count <= 0:
        return
    if not session.get("prompts"):
        session["prompts"] = count
        session["promptDay"] = session["promptDay"] or local_day(session["updated_ts"]) or today
    model = session["model"] or "Unknown"
    row = models.setdefault(model, blank_model(model))
    fallback = str(session["promptDay"] or local_day(session["updated_ts"]) or today)
    by_day: dict[str, list[int]] = {}
    for key, n in (session.get("dayPrompts") or {}).items():
        by_day.setdefault(key or fallback, [0, 0])[0] += n
    for key, n in (session.get("daySteps") or {}).items():
        by_day.setdefault(key or fallback, [0, 0])[1] += n
    if not by_day:
        # Known only from the index: every prompt on the session's last day.
        by_day[fallback] = [count, int(session.get("steps") or 0)]
    total_steps = 0
    for key, (prompts, steps) in by_day.items():
        # Each prompt took at least one step.
        steps = max(steps, prompts)
        total_steps += steps
        row["prompts"] += prompts
        row["steps"] += steps
        daily_prompts[key] += prompts
        daily_steps[key] += steps
        if key == str(today):
            row["todayPrompts"] += prompts
            row["todaySteps"] += steps
        if key in week:
            row["weekPrompts"] += prompts
            row["weekSteps"] += steps
    session["stepCount"] = total_steps


def scan(data_home: Path) -> dict:
    today = dt.date.today()
    week = {str(today - dt.timedelta(days=i)) for i in range(7)}
    sessions: dict[str, dict] = {}
    tools: Counter = Counter()
    models: dict[str, dict] = {}
    daily_prompts: Counter = Counter()
    daily_steps: Counter = Counter()
    read_index(data_home, sessions)
    store = data_home / "sessions"
    transcripts: list[Path] = []
    if store.exists():
        # Paths are YEAR/MONTH/DAY/<id>: newest first, so the cap drops the oldest.
        transcripts = sorted(store.glob("*/*/*/*/session.jsonl"), reverse=True)
    for path in transcripts[:400]:
        try:
            sid = path.parent.name
        except IndexError:
            continue
        session = sessions.setdefault(sid, blank_session(sid))
        session["logPath"] = session.get("logPath") or str(path)
        session["_hasLog"] = True
        read_transcript(path, session, tools, today)
    visible = []
    counted = set()
    for session in sessions.values():
        if not session.get("_hasLog"):
            # The index can lag a deletion; only count sessions whose log remains.
            claim = session.get("logPath") or ""
            if not (claim and Path(claim).is_file()):
                continue
        if session["conversationId"] not in counted:
            account_prompts(session, models, daily_prompts, daily_steps, today, week)
            counted.add(session["conversationId"])
        if session["workspace"]:
            session["workspaceName"] = Path(session["workspace"]).name or "Muse"
        if session["preview"] and session["title"] == "Muse session":
            session["title"] = session["preview"]
        if not session["preview"]:
            session["preview"] = session["title"]
        if session["updated_ts"]:
            session["updated_at"] = dt.datetime.fromtimestamp(session["updated_ts"]).isoformat()
        for key in ("promptDay", "prompts", "steps", "updated_ts", "lastPromptTs", "indexPrompts", "logPath", "_hasLog", "dayPrompts", "daySteps"):
            session.pop(key, None)
        visible.append(session)
    cwds = muse_active_cwds()
    active = bool(cwds)
    visible.sort(key=lambda item: item.get("updated_at") or "", reverse=True)
    if active and visible:
        if any(ws and ws in cwds for ws in (item.get("workspace") for item in visible)):
            for item in visible:
                if item.get("workspace") in cwds:
                    item["isActive"] = True
                    break
        else:
            visible[0]["isActive"] = True
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
        "tierLabel": "Meta",
        "planTier": "",
        "currentModel": current or "Muse",
        "todayPrompts": daily_prompts[str(today)],
        "todaySessions": sum(1 for item in visible if str(item.get("updated_at", "")).startswith(str(today))),
        "todaySteps": daily_steps[str(today)],
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": days,
        "totalPrompts": sum(daily_prompts.values()),
        "totalSessions": len(visible),
        "totalSteps": sum(daily_steps.values()),
        "activeSessions": [item for item in visible if item["isActive"]],
        "recentSessions": visible[:10],
        "toolUsage": dict(tools.most_common(12)),
        "modelUsage": {item["name"]: item for item in model_list},
        "modelList": model_list,
        "quotaGroups": [],
        "quotaNote": QUOTA_NOTE,
        "limits": [],
        "recentWorkspaces": [],
        "premiumRequests": 0,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quotaUpdatedAt": "",
        "usageStatusText": "",
        "authHelpText": "",
        "display": {
            "name": "Muse",
            "color": COLOR,
            "executable": "muse",
        },
    }


def collect(force: bool = False) -> dict:
    """This provider's usage, for usage_scanner.py to call in-process."""
    return scan(DATA_HOME)


def main() -> None:
    print(json.dumps(scan(DATA_HOME), separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
