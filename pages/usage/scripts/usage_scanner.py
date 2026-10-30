#!/usr/bin/env python3
"""Normalize Design Nexus providers to one JSON contract.

Every result includes availability, activity, quota buckets, local usage, sessions,
errors, and presentation metadata. Network quota is not estimated for Claude,
Copilot, or Muse. XSI is Grok and Cursor together: their plans share one quota
pool, so it shows Grok's billing once and merges both CLIs' stats and sessions.

Each provider's scanner is imported and called in this process; `busy` tells the
hub which providers deserve the fast refresh.
"""
from __future__ import annotations
import argparse, datetime as dt, importlib, json, os, shutil, time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

META = {
    "codex": ("Codex", "#22c7b8", "codex_usage_scanner", "codex", "OpenAI"),
    "xsi": ("XSI", "#a855f7", "", "grok", "xAI"),
    "antigravity": ("Antigravity", "#3b82f6", "antigravity_usage_scanner", "agy", "Google DeepMind"),
    "claude": ("Claude Code", "#f97316", "claude_usage_scanner", "claude", "Anthropic"),
    "copilot": ("Copilot", "#1f6feb", "copilot_usage_scanner", "copilot", "GitHub"),
    "muse": ("Muse", "#0082FB", "muse_usage_scanner", "muse", "Meta"),
}
# XSI's sources, in quota priority: Grok's billing has the whole shared pool.
XSI_SOURCES = (
    ("grok", "Grok", "grok_usage_scanner"),
    ("cursor", "Cursor", "cursor_usage_scanner"),
)
# A live session counts as busy while its log changed this recently.
BUSY_WINDOW_SEC = 120
QUOTA_NOTES = {
    "copilot": "Monthly allowance is not stored locally.",
    "muse": "Muse quota is not estimated.",
}
SUMMED = ("todayPrompts", "todaySessions", "todaySteps", "todayTotalTokens", "todayCachedTokens",
          "totalPrompts", "totalSessions", "totalSteps", "premiumRequests")

def cursor_executable():
    for name in ("agent", "cursor-agent"):
        path = shutil.which(name)
        if not path:
            continue
        real = os.path.realpath(path)
        if name == "cursor-agent" or "cursor" in real.lower():
            return name
    return ""

def source_executable(source):
    if source == "cursor":
        return cursor_executable()
    return source if shutil.which(source) else ""

def installed(provider, executable):
    if provider == "xsi":
        return any(source_executable(source) for source, _, _ in XSI_SOURCES)
    return bool(shutil.which(executable))

def recent_days():
    today = dt.date.today()
    return [{"date": str(today - dt.timedelta(days=i)), "messageCount": 0, "prompts": 0, "steps": 0} for i in range(6, -1, -1)]

def empty(provider, available, error=""):
    name, color, _, executable, tier = META[provider]
    note = QUOTA_NOTES.get(provider, "")
    install = "`grok` or Cursor's `agent`" if provider == "xsi" else "`" + executable + "`"
    return {"schemaVersion": 2, "providerId": provider, "id": provider, "name": name,
      "display": {"name": name, "color": color, "executable": executable}, "available": available,
      "ready": available, "active": False, "activeStatus": "Unavailable" if not available else "Idle",
      "hasActiveSession": False, "hasLocalStats": False, "canKill": provider in ("codex", "xsi", "antigravity"),
      "tierLabel": tier, "currentModel": "", "planTier": "", "premiumRequests": 0, "quotaNote": note,
      "todayPrompts": 0, "todaySessions": 0, "todaySteps": 0, "todayTotalTokens": 0,
      "todayTokensByModel": {}, "recentDays": recent_days(), "totalPrompts": 0, "totalSessions": 0,
      "totalSteps": 0, "activeSessions": [], "recentSessions": [], "toolUsage": {}, "modelUsage": {},
      "modelList": [], "quotaGroups": [], "limits": [], "recentWorkspaces": [],
      "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "quotaUpdatedAt": "",
      "usageStatusText": error or ("CLI not installed" if not available else "No local activity found"),
      "authHelpText": "" if available else ("Install " + install + " to collect usage."), "error": error}

def run_collector(module, force):
    """A scanner module's result, or {"error": ...} when it fails."""
    try:
        data = importlib.import_module(module).collect(force=force)
        return data if isinstance(data, dict) else {"error": "Scanner returned no data"}
    except Exception as exc:
        return {"error": str(exc) or type(exc).__name__}

def session_time(session):
    raw = session.get("updated_at") or session.get("lastModified") or ""
    if isinstance(raw, (int, float)):
        return raw / 1000 if raw > 1e12 else float(raw)
    try:
        # Grok writes UTC with a Z; Cursor writes local time with no zone, which
        # timestamp() reads as local.
        return dt.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0

def busy(data):
    if not data.get("hasActiveSession"):
        return False
    sessions = (data.get("activeSessions") or []) + (data.get("recentSessions") or [])[:3]
    return any(time.time() - session_time(s) < BUSY_WINDOW_SEC for s in sessions)

def add_counts(target, source):
    for key, value in (source or {}).items():
        if isinstance(value, (int, float)):
            target[key] = target.get(key, 0) + value

def merge_xsi(force):
    sources = [(source, label, module, source_executable(source)) for source, label, module in XSI_SOURCES]
    sources = [entry for entry in sources if entry[3]]
    if not sources:
        return empty("xsi", False)

    with ThreadPoolExecutor(len(sources)) as pool:
        results = list(pool.map(lambda entry: run_collector(entry[2], force), sources))
    parts = [(source, label, (data.get("display") or {}).get("executable") or exe, data)
             for (source, label, _, exe), data in zip(sources, results)]

    data = empty("xsi", True)
    days = {day["date"]: day for day in data["recentDays"]}
    models, tokens, cached, tools = {}, {}, {}, Counter()
    sessions, active_sessions, errors, help_lines, notes = [], [], [], [], []
    for source, label, exe, part in parts:
        for key in SUMMED:
            data[key] = data.get(key, 0) + (part.get(key) or 0)
        for day in part.get("recentDays") or []:
            if day.get("date") in days:
                add_counts(days[day["date"]], day)
        for row in part.get("modelList") or []:
            name = row.get("name") or label
            if name in models:
                add_counts(models[name], {k: v for k, v in row.items() if k != "color"})
            else:
                models[name] = dict(row)
        add_counts(tokens, part.get("todayTokensByModel"))
        add_counts(cached, part.get("todayCachedByModel"))
        tools.update({k: v for k, v in (part.get("toolUsage") or {}).items() if isinstance(v, (int, float))})
        tag = {"source": source, "sourceName": label, "executable": exe, "canKill": source == "grok"}
        sessions += [dict(s, **tag) for s in part.get("recentSessions") or []]
        active_sessions += [dict(s, **tag) for s in part.get("activeSessions") or []]
        if part.get("error"):
            errors.append(label + ": " + part["error"])
        if part.get("authHelpText"):
            help_lines.append(label + ": " + part["authHelpText"])
        if part.get("quotaNote"):
            notes.append(label + ": " + part["quotaNote"])

    sessions.sort(key=session_time, reverse=True)
    model_list = sorted(models.values(), key=lambda m: (m.get("prompts", 0), m.get("steps", 0), m.get("name", "")), reverse=True)
    by_source = {source: (label, exe, part) for source, label, exe, part in parts}
    newest = sessions[0]["source"] if sessions else parts[0][0]
    _, newest_exe, newest_part = by_source[newest]
    quota = next((part for _, _, _, part in parts if part.get("quotaGroups")), None)
    active = any(part.get("hasActiveSession") for _, _, _, part in parts)
    has_stats = any(part.get("hasLocalStats") for _, _, _, part in parts)
    now = dt.datetime.now(dt.timezone.utc)

    data.update({
        "ready": True,
        "active": active,
        "hasActiveSession": active,
        "activeStatus": "Working" if active else "Idle",
        "hasLocalStats": has_stats,
        "currentModel": newest_part.get("currentModel") or next((p.get("currentModel") for _, _, _, p in parts if p.get("currentModel")), ""),
        "todayTokensByModel": tokens,
        "todayCachedByModel": cached,
        # Grok always records tokens; Cursor's transcripts usually don't.
        "tokensTracked": any(part.get("tokensTracked") is not False for _, _, _, part in parts if not part.get("error")),
        "recentDays": list(days.values()),
        "activeSessions": active_sessions,
        "recentSessions": sessions[:10],
        "toolUsage": dict(tools.most_common(12)),
        "modelUsage": {m.get("name"): m for m in model_list},
        "modelList": model_list,
        "quotaGroups": quota.get("quotaGroups") if quota else [],
        "limits": (quota.get("limits") or []) if quota else [],
        "quotaUpdatedAt": (quota.get("quotaUpdatedAt") or "") if quota else "",
        "quotaUpdatedMs": (quota.get("quotaUpdatedMs") or 0) if quota else 0,
        "tierLabel": (quota.get("tierLabel") or quota.get("planTier") or "xAI") if quota else "xAI",
        "planTier": (quota.get("planTier") or quota.get("tierLabel") or "") if quota else "",
        "quotaNote": "" if quota else " · ".join(notes),
        "updatedAt": now.isoformat(),
        "lastFullRefreshMs": round(now.timestamp() * 1000),
        "usageStatusText": "" if has_stats else "No Grok or Cursor activity found",
        "authHelpText": " · ".join(help_lines),
        "error": " · ".join(errors),
        "display": {"name": "XSI", "color": META["xsi"][1], "executable": newest_exe},
    })
    return data

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("provider", choices=META)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    if args.provider == "xsi":
        data = merge_xsi(args.force)
    else:
        data = scan_provider(args.provider, args.force)
    data["busy"] = busy(data)
    print(json.dumps(data, separators=(",", ":"), ensure_ascii=False))

def scan_provider(provider, force):
    name, color, module, executable, _ = META[provider]
    if not installed(provider, executable):
        return empty(provider, False)
    data = run_collector(module, force)
    if set(data) == {"error"}:
        data = empty(provider, True, data["error"])
    child_exe = (data.get("display") or {}).get("executable") or executable
    data.update({"schemaVersion": 2, "providerId": provider, "id": provider, "name": name,
                 "display": {"name": name, "color": color, "executable": child_exe}, "available": True})
    data.setdefault("error", "")
    return data

if __name__ == "__main__": main()
