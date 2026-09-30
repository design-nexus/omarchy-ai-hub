#!/usr/bin/env python3
"""Normalize Design Nexus providers to one JSON contract.

Every result includes availability, activity, quota buckets, local usage, sessions,
errors, and presentation metadata. Network quota is not estimated for Claude,
Copilot, or Cursor.
"""
from __future__ import annotations
import argparse, datetime as dt, json, os, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
META = {
    "codex": ("Codex", "#22c7b8", "codex_usage_scanner.py", "codex", "OpenAI"),
    "grok": ("Grok", "#a855f7", "grok_usage_scanner.py", "grok", "xAI"),
    "antigravity": ("Antigravity", "#3b82f6", "antigravity_usage_scanner.py", "agy", "Google DeepMind"),
    "claude": ("Claude Code", "#f97316", "claude_usage_scanner.py", "claude", "Anthropic"),
    "copilot": ("Copilot", "#1f6feb", "copilot_usage_scanner.py", "copilot", "GitHub"),
    "cursor": ("Cursor", "#f54e00", "cursor_usage_scanner.py", "agent", "Cursor"),
}
NO_QUOTA_NOTIFY = {"copilot", "cursor"}
QUOTA_NOTES = {
    "copilot": "Monthly allowance is not stored locally.",
    "cursor": "Remaining allowance is not available from the local CLI.",
}

def cursor_executable():
    for name in ("agent", "cursor-agent"):
        path = shutil.which(name)
        if not path:
            continue
        real = os.path.realpath(path)
        if name == "cursor-agent" or "cursor" in real.lower():
            return name
    return ""

def installed(provider, executable):
    if provider == "cursor":
        return bool(cursor_executable())
    return bool(shutil.which(executable))

def recent_days():
    today = dt.date.today()
    return [{"date": str(today - dt.timedelta(days=i)), "messageCount": 0, "prompts": 0, "steps": 0} for i in range(6, -1, -1)]

def empty(provider, available, error=""):
    name, color, _, executable, tier = META[provider]
    if provider == "cursor":
        executable = cursor_executable() or executable
    note = QUOTA_NOTES.get(provider, "")
    return {"schemaVersion": 2, "providerId": provider, "id": provider, "name": name,
      "display": {"name": name, "color": color, "executable": executable}, "available": available,
      "ready": available, "active": False, "activeStatus": "Unavailable" if not available else "Idle",
      "hasActiveSession": False, "hasLocalStats": False, "canKill": provider in ("codex", "grok", "antigravity"),
      "tierLabel": tier, "currentModel": "", "planTier": "", "premiumRequests": 0, "quotaNote": note,
      "todayPrompts": 0, "todaySessions": 0, "todaySteps": 0, "todayTotalTokens": 0,
      "todayTokensByModel": {}, "recentDays": recent_days(), "totalPrompts": 0, "totalSessions": 0,
      "totalSteps": 0, "activeSessions": [], "recentSessions": [], "toolUsage": {}, "modelUsage": {},
      "modelList": [], "quotaGroups": [], "limits": [], "recentWorkspaces": [],
      "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "quotaUpdatedAt": "",
      "usageStatusText": error or ("CLI not installed" if not available else "No local activity found"),
      "authHelpText": "" if available else ("Install `" + executable + "` to collect usage."), "error": error}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("provider", choices=META)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--notify-low-quota", type=int)
    args = ap.parse_args()
    name, color, script, executable, _ = META[args.provider]
    if args.provider == "cursor":
        executable = cursor_executable() or executable
    if not installed(args.provider, executable):
        print(json.dumps(empty(args.provider, False)))
        return
    command = [sys.executable, str(ROOT / script)]
    if args.force: command.append("--force")
    if args.notify_low_quota is not None and args.provider not in NO_QUOTA_NOTIFY:
        command += ["--notify-low-quota", str(args.notify_low_quota)]
    try:
        run = subprocess.run(command, capture_output=True, text=True, timeout=25, check=False)
        data = json.loads(run.stdout) if run.stdout.strip() else empty(args.provider, True, run.stderr.strip() or "Scanner returned no data")
    except Exception as exc:
        data = empty(args.provider, True, str(exc))
    child_exe = (data.get("display") or {}).get("executable") or executable
    data.update({"schemaVersion": 2, "providerId": args.provider, "id": args.provider, "name": name,
                 "display": {"name": name, "color": color, "executable": child_exe}, "available": True})
    data.setdefault("error", "")
    print(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
if __name__ == "__main__": main()
