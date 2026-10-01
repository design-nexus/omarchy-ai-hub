// Local page model helpers (LM Studio and Ollama) - pure JavaScript for QML import

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
    if (s === "loaded") return "Loaded"
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

// ── Ollama ───────────────────────────────────────────────────────────────

// Ollama names carry their registry: "hf.co/google/gemma-…:Q4_0" or a library
// name like "qwen3:8b". Show them without the registry host and ":latest".
function ollamaDisplayName(name) {
    var n = String(name || "")
    n = n.replace(/^hf\.co\//, "").replace(/^registry\.ollama\.ai\/library\//, "")
    n = n.replace(/:latest$/, "")
    // Hugging Face names lead with the publisher, which the card shows as a logo.
    if (/^hf\.co\//.test(String(name || ""))) n = n.replace(/^[^\/]+\//, "")
    return n
}

// Library models have no publisher in their name; guess it from the family
// so the card can show a brand logo. Unknown families fall back to Ollama's.
var OLLAMA_FAMILY_PUBLISHERS = {
    "llama": "meta", "mllama": "meta",
    "gemma": "google", "gemma2": "google", "gemma3": "google", "gemma3n": "google", "gemma4": "google",
    "qwen": "qwen", "qwen2": "qwen", "qwen2moe": "qwen", "qwen3": "qwen", "qwen3moe": "qwen", "qwen25vl": "qwen",
    "mistral": "mistralai", "mistral3": "mistralai", "mixtral": "mistralai",
    "deepseek2": "deepseek", "deepseek3": "deepseek",
    "phi2": "microsoft", "phi3": "microsoft", "phi4": "microsoft",
    "command-r": "cohere", "granite": "ibm", "nomic-bert": "nomic"
}

function ollamaPublisher(name, family) {
    var n = String(name || "")
    var hf = /^hf\.co\/([^\/]+)\//.exec(n)
    if (hf) return hf[1]
    var slash = n.indexOf("/")
    if (slash > 0 && n.indexOf("registry.ollama.ai") !== 0) return n.substring(0, slash)
    var f = String(family || "").toLowerCase()
    return OLLAMA_FAMILY_PUBLISHERS[f] || "ollama"
}

function quantOf(details) {
    var q = details && details.quantization_level ? String(details.quantization_level) : ""
    return q.toLowerCase() === "unknown" ? "" : q
}

/**
 * Parse GET /api/tags. Returns { options: [{ value, label, description }],
 * info: { name: { embed, quantization, contextLength } } }
 */
function parseOllamaTags(raw) {
    var out = { options: [], info: {} }
    try {
        var data = JSON.parse(String(raw || "").trim() || "{}")
        var list = Array.isArray(data.models) ? data.models : []
        for (var i = 0; i < list.length; i++) {
            var m = list[i] || {}
            var name = String(m.name || m.model || "")
            if (name === "") continue
            var d = m.details || {}
            var caps = Array.isArray(m.capabilities) ? m.capabilities : []
            var embed = caps.indexOf("embedding") !== -1
                || (caps.indexOf("completion") === -1 && /bert|embed/i.test(String(d.family || "") + name))
            var parts = []
            if (d.parameter_size) parts.push(String(d.parameter_size))
            if (quantOf(d)) parts.push(quantOf(d))
            var size = parseInt(m.size || 0, 10)
            if (isFinite(size) && size > 0) parts.push(formatBytes(size))
            if (embed) parts.push("embedding")
            out.options.push({ value: name, label: ollamaDisplayName(name), description: parts.join(" • ") })
            out.info[name] = { embed: embed, quantization: quantOf(d), contextLength: parseInt(d.context_length || 0, 10) || 0 }
        }
    } catch (e) {
        console.warn("Ollama: Failed to parse tags:", e)
    }
    return out
}

/**
 * Parse GET /api/ps into the same model shape parsePs produces for LM Studio.
 * `info` is parseOllamaTags().info, used for what /api/ps leaves out.
 */
function parseOllamaPs(raw, info) {
    var result = []
    try {
        var data = JSON.parse(String(raw || "").trim() || "{}")
        var list = Array.isArray(data.models) ? data.models : []
        info = info || {}
        for (var i = 0; i < list.length; i++) {
            var m = list[i] || {}
            var name = String(m.name || m.model || "")
            if (name === "") continue
            var d = m.details || {}
            var known = info[name] || {}
            var size = parseInt(m.size || 0, 10) || 0
            var vram = parseInt(m.size_vram || 0, 10) || 0
            result.push({
                identifier: name,
                displayName: ollamaDisplayName(name),
                sizeBytes: size,
                vramBytes: vram,
                ramBytes: Math.max(0, size - vram),
                status: "loaded",
                contextLength: parseInt(m.context_length || 0, 10) || 0,
                quantization: quantOf(d) || known.quantization || "",
                architecture: String(d.family || ""),
                publisher: ollamaPublisher(name, d.family),
                paramsString: String(d.parameter_size || ""),
                embed: known.embed === true,
                expiresAt: String(m.expires_at || "")
            })
        }
    } catch (e) {
        console.warn("Ollama: Failed to parse ps:", e)
    }
    return result
}

// ── Resources ────────────────────────────────────────────────────────────

/**
 * Parse one bin/local-resources sample.
 * `prev` is the `next` object from the previous call, or null on the first.
 * CPU percentages are deltas against the previous sample, as btop computes
 * them, so the first sample reports -1 until a second one exists.
 *
 * Returns: { gpuUtil, vramUsed, vramTotal, ramUsed, ramTotal, cpuPct,
 *            procs: { <server>: { cpuPct, rss } }, next }   (-1 = no data)
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
        gpuUtil: -1, vramUsed: -1, vramTotal: -1,
        ramUsed: 0, ramTotal: 0, cpuPct: -1,
        procs: {},
        next: { stat: prev.stat || null, procs: {}, ncpu: parseInt(map.ncpu || prev.ncpu || 1, 10) || 1 }
    }

    var g = (map.gpu || "").split(",")
    if (g.length >= 3) {
        out.gpuUtil = parseInt(g[0], 10)
        out.vramUsed = parseInt(g[1], 10) * 1048576
        out.vramTotal = parseInt(g[2], 10) * 1048576
    }

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
            out.cpuPct = Math.round((dt - (idle - old.idle)) * 100 / dt)
        }
        out.next.stat = { tot: tot, idle: idle }
    }

    var prevProcs = prev.procs || {}
    for (var key in map) {
        if (key.indexOf("proc_") !== 0) continue
        var name = key.substring(5)
        var f = map[key].split(/\s+/)
        if (f.length < 3) continue
        var pids = f[0]
        var ticks = parseInt(f[2], 10) || 0
        var proc = { cpuPct: -1, rss: (parseInt(f[1], 10) || 0) * 1024 }
        var was = prevProcs[name]
        if (was && was.pids === pids && prev.stat && out.next.stat) {
            var dtot = out.next.stat.tot - prev.stat.tot
            var dproc = ticks - was.ticks
            if (dtot > 0 && dproc >= 0) proc.cpuPct = Math.round(dproc * out.next.ncpu * 100 / dtot)
        }
        out.procs[name] = proc
        out.next.procs[name] = { pids: pids, ticks: ticks }
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
        ollamaDisplayName: ollamaDisplayName,
        ollamaPublisher: ollamaPublisher,
        parseOllamaTags: parseOllamaTags,
        parseOllamaPs: parseOllamaPs,
        parseResources: parseResources,
        publisherLogoSlug: publisherLogoSlug,
        logoColorSuffix: logoColorSuffix,
        avatarHue: avatarHue,
        avatarInitial: avatarInitial
    }
}