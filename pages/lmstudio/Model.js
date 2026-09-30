// LM Studio Model.js - Pure JavaScript module for QML import

// LM Studio CLI path getter (respects settings)
function getLmsPath(settings) {
    var custom = settings && settings.lmsPath ? String(settings.lmsPath).trim() : ""
    if (custom !== "") return custom
    return Quickshell.env("HOME") + "/.lmstudio/bin/lms"
}

/**
 * Parse `lms server status --json` output
 * Returns: { running: bool, port: int, error: string }
 */
function parseServerStatus(raw) {
    var text = String(raw || "").trim()
    if (text === "") return { running: false, port: 0, error: "Empty response" }

    try {
        var data = JSON.parse(text)
        return {
            running: data.running === true,
            port: parseInt(data.port || 0, 10),
            error: ""
        }
    } catch (e) {
        return { running: false, port: 0, error: "Failed to parse server status: " + e }
    }
}

/**
 * Parse `lms ps --json` output
 * Returns: Array of model objects with normalized fields
 */
function parsePs(raw) {
    var text = String(raw || "").trim()
    if (text === "") return []

    try {
        var data = JSON.parse(text)
        if (!Array.isArray(data)) return []

        var result = []
        for (var i = 0; i < data.length; i++) {
            var m = data[i] || {}
            result.push({
                identifier: String(m.identifier || m.modelKey || ""),
                displayName: String(m.displayName || m.identifier || "Unknown"),
                sizeBytes: parseInt(m.sizeBytes || 0, 10),
                vramBytes: parseInt(m.vramBytes || m.gpuMemoryBytes || 0, 10),
                ramBytes: parseInt(m.ramBytes || m.cpuMemoryBytes || 0, 10),
                status: String(m.status || "idle"),
                contextLength: parseInt(m.contextLength || m.maxContextLength || 0, 10),
                quantization: m.quantization ? String(m.quantization.name || "") : "",
                architecture: String(m.architecture || ""),
                publisher: String(m.publisher || ""),
                paramsString: String(m.paramsString || ""),
                vision: m.vision === true,
                trainedForToolUse: m.trainedForToolUse === true
            })
        }
        return result
    } catch (e) {
        console.warn("LM Studio: Failed to parse ps output:", e)
        return []
    }
}

/**
 * Format bytes to human-readable string
 */
function formatBytes(bytes) {
    var n = parseInt(String(bytes || 0), 10)
    if (!isFinite(n) || n <= 0) return "0 B"

    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024
        i++
    }
    return n.toFixed(i === 0 ? 0 : 1) + " " + units[i]
}

/**
 * Human-readable status
 */
function humanStatus(status) {
    var s = String(status || "").toLowerCase()
    if (s === "idle") return "Idle"
    if (s === "busy") return "Busy (generating)"
    if (s === "loading") return "Loading..."
    return s.charAt(0).toUpperCase() + s.slice(1)
}

/**
 * Total memory (VRAM + RAM) for display
 */
function totalMemoryBytes(model) {
    return parseInt(model.vramBytes || 0, 10) + parseInt(model.ramBytes || 0, 10)
}

/**
 * Parse `lms ls --json` output into model picker options
 * Returns: Array of { value, label, description }
 */
function parseLs(raw) {
    var text = String(raw || "").trim()
    if (text === "") return []

    try {
        var data = JSON.parse(text)
        if (!Array.isArray(data)) return []

        var result = []
        for (var i = 0; i < data.length; i++) {
            var m = data[i] || {}
            var key = String(m.modelKey || m.identifier || "")
            if (key === "") continue
            var parts = []
            if (m.paramsString) parts.push(String(m.paramsString))
            if (m.quantization && m.quantization.name) parts.push(String(m.quantization.name))
            var size = parseInt(m.sizeBytes || 0, 10)
            if (isFinite(size) && size > 0) parts.push(formatBytes(size))
            result.push({
                value: key,
                label: String(m.displayName || key),
                description: parts.join(" • ")
            })
        }
        return result
    } catch (e) {
        console.warn("LM Studio: Failed to parse ls output:", e)
        return []
    }
}

// ── Publisher logos ──────────────────────────────────────────────────────
// `lms` publishers are Hugging Face org/user names. Known brands map to
// their Simple Icons slug (CC0, served from cdn.simpleicons.org); unknown
// publishers are tried as a slug directly (many match, e.g. "ollama") and
// fall back to a colored initial tile at render time when they 404.

var PUBLISHER_LOGO_SLUGS = {
    "google": "google",
    "googleai": "google",
    "google-deepmind": "google",
    "googlegemini": "googlegemini",
    "qwen": "qwen",
    "qwenlm": "qwen",
    "meta": "meta",
    "meta-llama": "meta",
    "mistralai": "mistralai",
    "mistral": "mistralai",
    "deepseek": "deepseek",
    "deepseek-awq": "deepseek",
    "deepseek-coder": "deepseek",
    "anthropic": "anthropic",
    "nvidia": "nvidia",
    "ollama": "ollama",
    "huggingface": "huggingface"
}

// Simple Icons default fill for these slugs is too dark for the panel
// background; request a lighter hex from the CDN instead.
var LOGO_COLOR_OVERRIDES = {
    "anthropic": "D97757"
}

function publisherLogoSlug(publisher) {
    var p = String(publisher || "").trim().toLowerCase()
    if (p === "") return ""
    if (PUBLISHER_LOGO_SLUGS[p]) return PUBLISHER_LOGO_SLUGS[p]
    if (/^[a-z0-9][a-z0-9-]*$/.test(p)) return p
    return ""
}

function logoColorSuffix(slug) {
    var color = LOGO_COLOR_OVERRIDES[String(slug || "")]
    return color ? "/" + color : ""
}

// Deterministic hue (0..359) for the fallback initial tile
function avatarHue(seed) {
    var s = String(seed || "")
    var h = 0
    for (var i = 0; i < s.length; i++) {
        h = (h * 31 + s.charCodeAt(i)) % 360
    }
    return h
}

// First printable character (letter preferred) for the fallback tile
function avatarInitial(label, publisher) {
    var candidates = [String(label || ""), String(publisher || "")]
    for (var c = 0; c < candidates.length; c++) {
        var s = candidates[c]
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i)
            if (/[a-zA-Z0-9]/.test(ch)) return ch.toUpperCase()
        }
    }
    return "?"
}

/**
 * Sum resource usage across loaded models
 * Returns: { vramBytes, ramBytes, maxContextLength }
 */
function aggregateStats(models) {
    var list = Array.isArray(models) ? models : []
    var vram = 0
    var ram = 0
    var ctx = 0
    for (var i = 0; i < list.length; i++) {
        var m = list[i] || {}
        vram += parseInt(m.vramBytes || 0, 10)
        ram += parseInt(m.ramBytes || 0, 10)
        ctx += parseInt(m.contextLength || m.maxContextLength || 0, 10)
    }
    return { vramBytes: vram, ramBytes: ram, maxContextLength: ctx }
}

/**
 * Shell script (run via `bash -c`) that samples system resource usage in one
 * pass. Emits tab-separated `key<TAB>value` lines that parseResources reads:
 *
 *   gpu\t<util%>,<usedMiB>,<totalMiB>      whole-GPU util + VRAM (nvidia-smi)
 *   vram\t<pid>,<usedMiB>                  per-process VRAM for llama-server
 *   ram\t<usedKB> <availKB> <totalKB>      system RAM from /proc/meminfo
 *   stat\tcpu  <...>                       raw /proc/stat aggregate line
 *   ncpu\t<count>
 *   proc\t<pid>\t<rssKB> <utime+stime>     llama-server process (or -\t-\t-)
 *
 * All reads are permitted for the current user; no sudo required.
 */
var RESOURCE_POLL_SCRIPT = [
    "PID=$(pgrep -f 'llama-server' | head -1)",
    "printf 'gpu\\t'; nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || true",
    "if [ -n \"$PID\" ]; then",
    "  VRAM=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | grep \"^$PID,\" | head -1)",
    "  if [ -n \"$VRAM\" ]; then printf 'vram\\t%s\\n' \"$VRAM\"; fi",
    "fi",
    "printf 'ram\\t'; awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{printf \"%d %d %d\\n\", t-a, a, t}' /proc/meminfo",
    "printf 'stat\\t'; grep '^cpu ' /proc/stat",
    "printf 'ncpu\\t%s\\n' \"$(nproc)\"",
    "if [ -n \"$PID\" ]; then",
    "  printf 'proc\\t%s\\t' \"$PID\"",
    "  awk '/^VmRSS:/{printf \"%d \", $2}' /proc/$PID/status",
    "  awk '{for(i=1;i<=NF;i++){if($i ~ /\\)/){s=i;break}} print $(s+12)+$(s+13)}' /proc/$PID/stat",
    "else printf 'proc\\t-\\t-\\t-'",
    "fi"
].join("\n")

/**
 * Parse one resource poll payload.
 * `prev` is the `next` object from the previous call (stat/proc snapshots) or
 * null on the first tick. CPU% and per-process CPU% are deltas against the
 * previous snapshot, exactly how btop computes them; the first tick therefore
 * reports -1 for both until a second sample exists.
 *
 * Returns: { gpuUtil, vramUsed, vramTotal, ramUsed, ramTotal, cpuPct,
 *            procCpuPct, procRss, procPid, next }  (-1 = no data yet)
 */
function parseResources(raw, prev) {
    var map = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var idx = lines[i].indexOf("\t")
        if (idx > 0) map[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
    }
    prev = prev || {}
    var out = {
        gpuUtil: -1,
        vramUsed: -1,
        vramTotal: -1,
        ramUsed: 0,
        ramTotal: 0,
        cpuPct: -1,
        procCpuPct: -1,
        procRss: 0,
        procPid: 0,
        next: {
            stat: prev.stat || null,
            proc: prev.proc || null,
            ncpu: parseInt(map.ncpu || prev.ncpu || 1, 10) || 1
        }
    }

    var g = (map.gpu || "").split(",")
    if (g.length >= 3) {
        out.gpuUtil = parseInt(g[0], 10)
        out.vramUsed = parseInt(g[1], 10) * 1048576
        out.vramTotal = parseInt(g[2], 10) * 1048576
    }
    var v = (map.vram || "").split(",")
    if (v.length >= 2) out.vramUsed = parseInt(v[1], 10) * 1048576

    var r = (map.ram || "").split(/\s+/)
    if (r.length === 3) {
        out.ramUsed = parseInt(r[0], 10) * 1024
        out.ramTotal = parseInt(r[2], 10) * 1024
    }

    var s = (map.stat || "").split(/\s+/)
    if (s.length >= 9) {
        var idle = parseInt(s[4], 10) + parseInt(s[5], 10)
        var tot = 0
        for (var j = 1; j <= 8; j++) tot += parseInt(s[j], 10)
        var old = prev.stat
        if (old && tot > old.tot) {
            var dt = tot - old.tot
            var di = idle - old.idle
            if (dt > 0) out.cpuPct = Math.round((dt - di) * 100 / dt)
        }
        out.next.stat = { tot: tot, idle: idle }
    }

    var p = (map.proc || "").split(/\s+/)
    if (p.length >= 3 && p[0] !== "-") {
        var pid = parseInt(p[0], 10)
        out.procPid = pid
        out.procRss = (parseInt(p[1], 10) || 0) * 1024
        var pt = parseInt(p[2], 10)
        var oldProc = prev.proc
        var oldStat = prev.stat
        if (oldProc && oldStat && out.next.stat && oldProc.pid === pid) {
            var dproc = pt - oldProc.ticks
            var dtot = out.next.stat.tot - oldStat.tot
            if (dtot > 0 && dproc >= 0) {
                out.procCpuPct = Math.round(dproc * out.next.ncpu * 100 / dtot)
            }
        }
        out.next.proc = { pid: pid, ticks: pt }
    }
    return out
}

if (typeof module !== "undefined") {
    module.exports = {
        getLmsPath: getLmsPath,
        parseServerStatus: parseServerStatus,
        parsePs: parsePs,
        formatBytes: formatBytes,
        humanStatus: humanStatus,
        totalMemoryBytes: totalMemoryBytes,
        parseLs: parseLs,
        aggregateStats: aggregateStats,
        RESOURCE_POLL_SCRIPT: RESOURCE_POLL_SCRIPT,
        parseResources: parseResources,
        publisherLogoSlug: publisherLogoSlug,
        logoColorSuffix: logoColorSuffix,
        avatarHue: avatarHue,
        avatarInitial: avatarInitial
    }
}