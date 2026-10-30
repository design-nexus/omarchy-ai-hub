#!/usr/bin/env python3
"""Query ChatGPT / Codex CLI state, sessions, and app-server rate limits to emit usage stats."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import re
import select
import shutil
import sqlite3
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

from common import FetchGate, apply_forecasts, cache_age_iso


def default_base_dir() -> Path:
    return Path(os.environ.get("CODEX_HOME") or os.environ.get("CHATGPT_DATA_DIR") or os.path.expanduser("~/.codex"))


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
        "id": "chatgpt",
        "name": "ChatGPT",
        "ready": False,
        "active": False,
        "activeStatus": "Idle",
        "hasActiveSession": False,
        "hasLocalStats": False,
        "tierLabel": "OpenAI",
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
        "usageStatusText": "No Codex sessions found",
        "authHelpText": "Run `codex login` to start.",
    }


def parse_session_index(base_dir: Path) -> list[dict[str, Any]]:
    index_file = base_dir / "session_index.jsonl"
    sessions = []
    if not index_file.exists():
        return sessions
    try:
        with open(index_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    sid = sanitize_plain_text(data.get("id"), 100)
                    if sid:
                        sessions.append({
                            "conversationId": sid,
                            "title": sanitize_plain_text(data.get("thread_name") or "Session", 150),
                            "preview": sanitize_plain_text(data.get("thread_name") or "Session", 150),
                            "updated_at": str(data.get("updated_at") or ""),
                            "workspace": "",
                            "workspaceName": "",
                            "stepCount": 0,
                            "isActive": False,
                        })
                except Exception:
                    continue
    except Exception:
        pass
    # session_index.jsonl is append-oriented, so file order is creation order
    # rather than recency order. Sort newest-first for the Recent Sessions
    # card and keep malformed/missing timestamps at the end.
    def updated_timestamp(session: dict[str, Any]) -> float:
        raw = session.get("updated_at", "")
        try:
            return dt.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).timestamp()
        except (TypeError, ValueError, OverflowError):
            return 0.0

    sessions.sort(key=updated_timestamp, reverse=True)
    return sessions


# Codex processes that are not a session you are running: the ChatGPT desktop
# app's bundled codex, and the app-server, exec-server and MCP daemons.
DAEMON_COMMANDS = {"app-server", "exec-server", "mcp-server", "mcp"}


def not_a_session(argv: list[str]) -> bool:
    exe = argv[0] if argv else ""
    if exe.startswith("/usr/lib/chatgpt/") or "/app-server-daemon/" in exe:
        return True
    return bool(DAEMON_COMMANDS.intersection(argv[1:]))


def get_active_codex_pids() -> dict[str, int]:
    """Find interactive codex processes, keyed by conversation ID when the
    command line names one and by ``cwd:<dir>`` otherwise.

    The app-server daemon and zombie processes are ignored: neither is a
    session the user is running.
    """
    session_pids = {}
    try:
        proc = subprocess.run(
            # Match the executable name, not the full command line.  The
            # latter also matches the Codex sandbox/agent that runs this
            # scanner (and arbitrary shell commands containing "codex").
            ["pgrep", "-x", "codex"],
            capture_output=True,
            text=True,
            timeout=1,
        )
        if proc.returncode == 0:
            for pid_str in proc.stdout.strip().split():
                try:
                    pid = int(pid_str)
                    if pid == os.getpid():
                        continue
                    # Check cmdline or open file descriptors
                    try:
                        proc_dir = Path(f"/proc/{pid}")
                        cmd = (proc_dir / "cmdline").read_bytes().decode("utf-8", errors="replace")
                        argv = cmd.split("\0")
                        if not_a_session(argv):
                            continue
                        status = (proc_dir / "status").read_text(errors="replace")
                        if re.search(r"^State:\s*Z", status, re.M):
                            continue
                        m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", cmd)
                        if m:
                            session_pids[m.group(1)] = pid
                        else:
                            session_pids["cwd:" + os.readlink(proc_dir / "cwd")] = pid
                    except Exception:
                        pass
                except Exception:
                    continue
    except Exception:
        pass
    return session_pids


def session_cwd(base_dir: Path, cid: str) -> str:
    """Working directory recorded in a session's rollout file."""
    for root in (base_dir / "sessions", base_dir / "archived_sessions"):
        for path in root.rglob(f"*{cid}.jsonl") if root.exists() else []:
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    meta = json.loads(f.readline())
                return str((meta.get("payload") or {}).get("cwd") or "")
            except (OSError, ValueError):
                continue
    return ""


def holds_session_file(pid: int, cid: str) -> bool:
    try:
        for fd in Path(f"/proc/{pid}/fd").iterdir():
            try:
                if cid in os.readlink(fd):
                    return True
            except OSError:
                continue
    except OSError:
        pass
    return False


def kill_session(cid: str, base_dir: Path) -> bool:
    """Terminate the codex process running ``cid``.

    A codex session process naming the conversation ID, else one holding the
    session's rollout file open. Sharing a working directory is not enough:
    that would kill whatever other codex happens to run there.
    """
    import signal
    running = get_active_codex_pids()
    pid = running.get(cid)
    if pid is None:
        pid = next((p for p in running.values() if holds_session_file(p, cid)), None)
    if not pid:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
        return True
    except OSError:
        return False


def rpc_request(proc: Any, request_id: int, method: str, params: dict | None = None, timeout: float = 6.0) -> dict:
    payload = {"id": request_id, "method": method, "params": params or {}}
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    # Raw reads into our own buffer: a buffered readline() can pull several
    # replies in at once, after which select() sees nothing left to read and
    # the reply already in hand would time out.
    fd = proc.stdout.fileno()
    buffer = getattr(proc, "rpc_buffer", b"")
    deadline = time.time() + timeout
    while True:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict) and msg.get("id") == request_id:
                proc.rpc_buffer = buffer
                return msg
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        ready, _, _ = select.select([fd], [], [], min(0.25, remaining))
        if not ready:
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        buffer += chunk
    proc.rpc_buffer = buffer
    raise TimeoutError(method)


def fetch_codex_rpc_quota(base_dir: Path, force: bool = False) -> tuple[list[dict[str, Any]], str, str]:
    cache_file = base_dir / "cache" / "quota_usage_cache.json"
    cache_file.parent.mkdir(parents=True, exist_ok=True)

    if not force and cache_file.exists():
        try:
            age = time.time() - cache_file.stat().st_mtime
            if age < 180:
                with open(cache_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict) and "groups" in data:
                        return data.get("groups", []), data.get("tierLabel", "plus"), ""
        except Exception:
            pass

    def cached_groups(error: str) -> tuple[list[dict[str, Any]], str, str]:
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get("groups", []), data.get("tierLabel", "plus"), error
        except Exception:
            return [], "", error

    # Also spares starting `codex app-server` on every run while it is failing.
    gate = FetchGate("codex")
    blocked = gate.blocked(force)
    if blocked:
        return cached_groups(blocked)

    codex_bin = shutil.which("codex") or str(Path.home() / ".local/bin/codex")
    if not codex_bin or not Path(codex_bin).exists():
        return [], "", "codex not found in PATH"

    limits_data = []
    tier = "plus"
    error_str = ""

    try:
        proc = subprocess.Popen(
            [codex_bin, "-s", "read-only", "-a", "on-request", "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            rpc_request(proc, 1, "initialize", {"clientInfo": {"name": "omarchy-chatgpt-usage", "version": "1"}}, timeout=6)
            proc.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
            proc.stdin.flush()
            acc_msg = rpc_request(proc, 2, "account/read", timeout=4)
            lim_msg = rpc_request(proc, 3, "account/rateLimits/read", timeout=4)

            account = (acc_msg.get("result") or {}).get("account") or {}
            rate_limits = (lim_msg.get("result") or {}).get("rateLimits") or {}
            tier = str(rate_limits.get("planType") or account.get("planType") or account.get("type") or "plus")

            buckets = []
            for win_key in ("primary", "secondary"):
                win = rate_limits.get(win_key)
                if isinstance(win, dict) and win.get("usedPercent") is not None:
                    used = float(win.get("usedPercent", 0.0))
                    rem_pct = max(0.0, 100.0 - used)
                    rem_frac = rem_pct / 100.0
                    mins = int(win.get("windowDurationMins") or 0)
                    if mins == 10080:
                        label = "Weekly (7-day)"
                    elif mins and mins % 60 == 0:
                        label = f"{mins // 60}h window"
                    elif mins:
                        label = f"{mins}m window"
                    else:
                        label = "Limit"

                    reset_raw = win.get("resetsAt")
                    resets_at = ""
                    if reset_raw:
                        try:
                            resets_at = dt.datetime.fromtimestamp(float(reset_raw), dt.timezone.utc).isoformat()
                        except Exception:
                            resets_at = str(reset_raw)

                    buckets.append({
                        "id": f"codex-{win_key}",
                        "name": f"{label} Remaining",
                        "label": label,
                        "remainingFraction": rem_frac,
                        "remainingPercent": round(rem_pct),
                        "usedPercent": round(used),
                        "resetTime": resets_at,
                        "color": "#10A37F",
                    })

            if buckets:
                limits_data = [{
                    "name": "ChatGPT / Codex Quota",
                    "description": f"Subscription plan: {tier.capitalize()}",
                    "color": "#10A37F",
                    "buckets": buckets,
                }]

                try:
                    with open(cache_file, "w", encoding="utf-8") as f:
                        json.dump({"groups": limits_data, "tierLabel": tier}, f)
                except Exception:
                    pass
        finally:
            try:
                if proc.stdin:
                    proc.stdin.close()
                if proc.stdout:
                    proc.stdout.close()
                proc.terminate()
                proc.wait(timeout=1)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    except Exception as exc:
        error_str = f"Codex quota request failed: {exc or type(exc).__name__}"

    if limits_data:
        gate.succeeded()
        return limits_data, tier, ""
    error_str = error_str or "Codex reported no rate limits"
    gate.failed(error_str)
    return cached_groups(error_str)


def scan(base_dir: Path, force: bool = False) -> dict[str, Any]:
    res = empty_result(base_dir)
    recent_dates = recent_date_strings()
    today_str = date_string(dt.datetime.now().date())

    # 1. Parse session index & running processes
    sessions = parse_session_index(base_dir)
    active_pids = get_active_codex_pids()

    # 2. Parse session files for workspace, prompt, token, and tool metrics.
    # A prompt is one user turn (task_started); a step is one model call
    # (token_count).
    cutoff = time.time() - (30 * 86400)
    session_files = []
    roots = [base_dir / "sessions", base_dir / "archived_sessions"]
    for r in roots:
        if r.exists():
            for p in r.rglob("*.jsonl"):
                try:
                    if p.stat().st_mtime >= cutoff:
                        session_files.append(p)
                except Exception:
                    pass

    model_usage: dict[str, dict[str, Any]] = {}
    tool_counter: Counter = Counter()
    recent_days_map = {d: {"date": d, "messageCount": 0, "prompts": 0, "steps": 0} for d in recent_dates}
    file_meta: dict[str, dict[str, Any]] = {}
    today_tokens_by_model: dict[str, int] = {}
    today_prompts = 0
    today_steps = 0
    today_tokens = 0
    today_cached = 0
    today_cached_by_model: dict[str, int] = {}
    total_prompts = 0
    total_steps = 0

    def model_bucket(name: str) -> dict[str, Any]:
        return model_usage.setdefault(name, {
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
            "color": "#10A37F",
        })

    configured_model = read_configured_model(base_dir) or "Codex"
    for p in session_files:
        current_model = configured_model
        meta = {"cwd": "", "prompts": 0, "mtime": 0.0}
        sid = ""
        try:
            meta["mtime"] = p.stat().st_mtime
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue

                    etype = entry.get("type")
                    payload = entry.get("payload") if isinstance(entry.get("payload"), dict) else {}
                    ptype = payload.get("type")

                    if etype == "session_meta":
                        sid = sanitize_plain_text(payload.get("id") or payload.get("session_id"), 100)
                        meta["cwd"] = str(payload.get("cwd") or "")
                        continue
                    if etype == "turn_context":
                        m = payload.get("model") or payload.get("model_slug")
                        if m:
                            current_model = sanitize_plain_text(m, 60)
                        continue
                    if etype == "response_item" and ptype in ("function_call", "custom_tool_call"):
                        tname = payload.get("name")
                        if tname:
                            tool_counter[sanitize_plain_text(tname, 50)] += 1
                        continue
                    if etype != "event_msg" or ptype not in ("task_started", "token_count"):
                        continue

                    day = local_date_from_timestamp(entry.get("timestamp") or meta["mtime"])
                    bucket = model_bucket(current_model)
                    in_week = day in recent_days_map

                    if ptype == "task_started":
                        meta["prompts"] += 1
                        total_prompts += 1
                        bucket["prompts"] += 1
                        if in_week:
                            recent_days_map[day]["messageCount"] += 1
                            recent_days_map[day]["prompts"] += 1
                            bucket["weekPrompts"] += 1
                        if day == today_str:
                            today_prompts += 1
                            bucket["todayPrompts"] += 1
                        continue

                    usage = (payload.get("info") or {}).get("last_token_usage") or {}
                    in_tok = int(usage.get("input_tokens") or 0)
                    out_tok = int(usage.get("output_tokens") or 0)
                    cached_tok = int(usage.get("cached_input_tokens") or 0)
                    turn_total = in_tok + out_tok
                    if turn_total <= 0:
                        continue

                    total_steps += 1
                    bucket["steps"] += 1
                    bucket["inputTokens"] += in_tok
                    bucket["outputTokens"] += out_tok
                    bucket["cachedTokens"] += cached_tok
                    if in_week:
                        recent_days_map[day]["steps"] += 1
                        bucket["weekSteps"] += 1
                    if day == today_str:
                        today_steps += 1
                        today_tokens += turn_total
                        today_cached += cached_tok
                        bucket["todaySteps"] += 1
                        today_tokens_by_model[current_model] = today_tokens_by_model.get(current_model, 0) + turn_total
                        today_cached_by_model[current_model] = today_cached_by_model.get(current_model, 0) + cached_tok
        except Exception:
            continue
        if sid:
            prev = file_meta.get(sid)
            if prev:
                meta["prompts"] += prev["prompts"]
                meta["mtime"] = max(meta["mtime"], prev["mtime"])
                meta["cwd"] = meta["cwd"] or prev["cwd"]
            file_meta[sid] = meta

    # Fill session rows from their rollout files.
    for s in sessions:
        meta = file_meta.get(s["conversationId"])
        if not meta:
            continue
        s["stepCount"] = meta["prompts"]
        if meta["cwd"]:
            s["workspace"] = meta["cwd"]
            s["workspaceName"] = Path(meta["cwd"]).name or meta["cwd"]

    # Mark sessions active. A process that names a conversation ID owns it;
    # otherwise the most recently written session in the process's working
    # directory is the one it is running.
    claimed = set()
    for key in active_pids:
        if key.startswith("cwd:"):
            cwd = key[4:]
            candidates = [s for s in sessions if s.get("workspace") == cwd and s["conversationId"] not in claimed]
            if candidates:
                best = max(candidates, key=lambda s: file_meta.get(s["conversationId"], {}).get("mtime", 0.0))
                claimed.add(best["conversationId"])
        else:
            claimed.add(key)
    for s in sessions:
        if s["conversationId"] in claimed:
            s["isActive"] = True

    has_active = len(active_pids) > 0
    res["hasActiveSession"] = has_active
    res["active"] = has_active
    res["activeStatus"] = "Working" if has_active else "Idle"
    res["recentSessions"] = sessions[:10]
    res["activeSessions"] = [s for s in sessions if s.get("isActive")]
    # The same 30 days as the prompt and step totals, not the whole index.
    res["totalSessions"] = len({f.stem for f in session_files})

    # 3. Fetch rate limits & quotas
    groups, tier, err_str = fetch_codex_rpc_quota(base_dir, force=force)
    limits_list = apply_forecasts("codex", groups)


    # Build model list sorted by usage
    model_list = list(model_usage.values())
    model_list.sort(key=lambda m: m["prompts"], reverse=True)

    res.update({
        "ready": True,
        "hasLocalStats": len(sessions) > 0 or total_prompts > 0 or len(groups) > 0,
        "tierLabel": f"OpenAI ({tier.capitalize()})" if tier else "OpenAI",
        "currentModel": read_configured_model(base_dir),
        "todayPrompts": today_prompts,
        "todaySessions": sum(1 for m in file_meta.values() if local_date_from_timestamp(m["mtime"]) == today_str),
        "todaySteps": today_steps,
        "todayTotalTokens": today_tokens,
        "todayCachedTokens": today_cached,
        "todayTokensByModel": today_tokens_by_model,
        "todayCachedByModel": today_cached_by_model,
        "recentDays": [recent_days_map[d] for d in recent_dates],
        "totalPrompts": total_prompts,
        "totalSteps": total_steps,
        "toolUsage": dict(tool_counter.most_common(12)),
        "modelUsage": model_usage,
        "modelList": model_list,
        "quotaGroups": groups,
        "limits": limits_list,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        # Served from cache after a failed request: say how old, and why.
        "quotaError": err_str,
        "quotaUpdatedAt": (cache_age_iso(base_dir / "cache" / "quota_usage_cache.json") if err_str else dt.datetime.now(dt.timezone.utc).isoformat()) if groups else "",
        "lastFullRefreshMs": round(time.time() * 1000),
        "usageStatusText": "" if (res["hasLocalStats"] or groups) else "No Codex activity found",
        "authHelpText": "" if (res["hasLocalStats"] or groups) else "Run `codex login` to begin.",
    })

    return res


def collect(force: bool = False) -> dict:
    """This provider's usage, for usage_scanner.py to call in-process."""
    return scan(default_base_dir(), force=force)


def main() -> None:
    parser = argparse.ArgumentParser(description="ChatGPT / Codex Usage Scanner for Omarchy")
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
