#!/usr/bin/env python3
"""Query Grok CLI state, sessions, and billing API to emit usage stats."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

from common import FetchGate, LogCache, apply_forecasts, cache_age_iso, cache_dir, date_string, local_date_from_timestamp, read_configured_model, recent_date_strings, sanitize_plain_text
from urllib.parse import unquote


def default_base_dir() -> Path:
    return Path(os.environ.get("GROK_HOME") or os.path.expanduser("~/.grok"))


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
    cache_file = cache_dir("grok") / "quota_usage_cache.json"
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


# Bump when read_update_lines changes what it records, so caches are rebuilt.
LOG_CACHE_VERSION = 3


def read_update_lines(entry: dict[str, Any], lines: list[bytes], mtime: float) -> None:
    """One session's updates.jsonl.

    turns: [prompts, steps, input, output, cached] by model and day. A turn is
    one prompt; its steps are the model's replies, one per tool call it made
    plus the final answer. Tool calls carry no timestamp, so they wait in
    `pending` for the turn that completes them. tools: tool calls by name.
    """
    for raw in lines:
        try:
            row = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            continue
        params = row.get("params") if isinstance(row, dict) else None
        update = params.get("update") if isinstance(params, dict) else None
        if not isinstance(update, dict):
            continue
        kind = update.get("sessionUpdate")
        if kind == "tool_call":
            entry["pending"] += 1
            name = sanitize_plain_text(str(update.get("title") or "tool").split(":")[0], 50)
            entry["tools"][name] = entry["tools"].get(name, 0) + 1
            continue
        if kind != "turn_completed":
            continue
        usage = update.get("usage") if isinstance(update.get("usage"), dict) else {}
        meta = row.get("_meta") if isinstance(row.get("_meta"), dict) else {}
        day = local_date_from_timestamp(meta.get("agentTimestampMs") or row.get("timestamp") or mtime)
        models = usage.get("modelUsage") if isinstance(usage.get("modelUsage"), dict) else {}
        m = next(iter(models), None) or "grok-3"
        m = str(m).rstrip("/").split("/")[-1] or "grok-3"
        counts = entry["turns"].setdefault(m + "\x1f" + day, [0, 0, 0, 0, 0])
        counts[0] += 1
        counts[1] += entry["pending"] + 1
        counts[2] += int(usage.get("inputTokens") or 0)
        counts[3] += int(usage.get("outputTokens") or 0)
        counts[4] += int(usage.get("cachedReadTokens") or usage.get("cacheReadInputTokens") or 0)
        entry["pending"] = 0


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
        entry = log_cache.update(p, lambda: {"turns": {}, "tools": {}, "pending": 0}, read_update_lines)
        if entry is None:
            continue
        for key, counts in entry["turns"].items():
            total = turns.setdefault(key, [0, 0, 0, 0, 0])
            for i, n in enumerate(counts):
                total[i] += n
        tool_counter.update(entry["tools"])
    log_cache.prune()

    for key, (count, steps, in_tok, out_tok, cached_tok) in turns.items():
        m, day = key.split("\x1f", 1)
        total_tok = in_tok + out_tok
        total_prompts += count
        total_steps += steps
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
        bucket["steps"] += steps
        bucket["inputTokens"] += in_tok
        bucket["outputTokens"] += out_tok
        bucket["cachedTokens"] += cached_tok
        if day in recent_days_map:
            recent_days_map[day]["messageCount"] += count
            recent_days_map[day]["prompts"] += count
            recent_days_map[day]["steps"] += steps
            bucket["weekPrompts"] += count
            bucket["weekSteps"] += steps
        if day == today_str:
            today_prompts += count
            today_steps += steps
            today_tokens += total_tok
            today_cached += cached_tok
            bucket["todayPrompts"] += count
            bucket["todaySteps"] += steps
            today_tokens_by_model[m] = today_tokens_by_model.get(m, 0) + total_tok
            today_cached_by_model[m] = today_cached_by_model.get(m, 0) + cached_tok

    # 3. Fetch billing limits
    groups, tier, err_str = fetch_grok_billing(base_dir, force=force)
    limits_list = apply_forecasts("grok", groups)


    model_list = list(model_usage.values())
    model_list.sort(key=lambda m: m["prompts"], reverse=True)

    has_stats = len(sessions) > 0 or total_prompts > 0 or len(groups) > 0

    res.update({
        "ready": True,
        "hasLocalStats": has_stats,
        "tierLabel": tier if tier else "xAI",
        "currentModel": read_configured_model(base_dir) or next((x.get("model") for x in sessions if x.get("model")), ""),
        "todayPrompts": today_prompts,
        "todaySessions": sum(1 for s in sessions if local_date_from_timestamp(s.get("updated_at")) == today_str),
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
        # Served from cache after a failed request: say how old, and why.
        "quotaError": err_str,
        "quotaUpdatedAt": (cache_age_iso(cache_dir("grok") / "quota_usage_cache.json") if err_str else dt.datetime.now(dt.timezone.utc).isoformat()) if groups else "",
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
