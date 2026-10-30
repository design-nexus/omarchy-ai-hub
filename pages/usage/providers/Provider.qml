import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false
  property string providerId: ""
  property var settings: ({})
  property bool refreshing: false
  property bool available: false
  // False until the scanner has answered once (successfully or not).
  property bool loaded: false
  property var data: ({})
  property string color: "#888888"
  property string name: providerId
  property string providerName: name
  property bool ready: data.ready === true
  property bool active: data.active === true
  property bool hasActiveSession: data.hasActiveSession === true
  property string activeStatus: data.activeStatus || "Idle"
  property bool hasLocalStats: data.hasLocalStats === true
  property string usageStatusText: data.usageStatusText || ""
  property string authHelpText: data.authHelpText || ""
  property string error: data.error || ""
  property string currentModel: data.currentModel || ""
  property double lastUpdatedMs: data.updatedAt ? Date.parse(data.updatedAt) : 0
  property double lastFullRefreshMs: data.lastFullRefreshMs || lastUpdatedMs
  property var quotaGroups: data.quotaGroups || []
  property var recentSessions: data.recentSessions || []
  property var activeSessions: data.activeSessions || []
  property int todayPrompts: Number(data.todayPrompts || 0)
  property int todayTotalTokens: Number(data.todayTotalTokens || 0)
  property real todayCachedTokens: Number(data.todayCachedTokens || 0)
  property bool tokensTracked: data.tokensTracked !== false
  property int todaySteps: Number(data.todaySteps || 0)
  property int totalPrompts: Number(data.totalPrompts || 0)
  property var recentDays: data.recentDays || []
  property var toolUsage: data.toolUsage || ({})
  property var modelUsage: data.modelUsage || ({})
  property var modelList: data.modelList || []
  property string executable: data.display ? data.display.executable : providerId
  property bool canKill: data.canKill !== false
  property string quotaNote: data.quotaNote || ""
  // Why the quota shown is cached rather than fresh, and when it was fetched.
  property string quotaError: data.quotaError || ""
  property double quotaUpdatedMs: data.quotaUpdatedAt ? Date.parse(data.quotaUpdatedAt) : 0
  property string planTier: data.planTier || ""
  readonly property bool agentEnabled: {
    var key = ({
      codex: "enableCodex",
      xsi: "enableXsi",
      antigravity: "enableAntigravity",
      claude: "enableClaude",
      copilot: "enableCopilot",
      muse: "enableMuse"
    })[providerId]
    if (!key) return true
    var value = settings ? settings[key] : undefined
    // XSI replaced the Grok and Cursor toggles: off only if both were off.
    if (key === "enableXsi" && (value === undefined || value === null))
      return !(settings && settings.enableGrok === false && settings.enableCursor === false)
    return value !== false
  }
  // The scanner that can kill one of this provider's sessions; only Codex,
  // Grok, and Antigravity implement --kill. XSI sessions name their source.
  function killScriptPath(session) {
    var killable = session && session.canKill !== undefined ? session.canKill === true : canKill
    if (!killable) return ""
    return scriptPath(((session && session.source) || providerId) + "_usage_scanner.py")
  }
  // A live session whose log changed in the last two minutes (usage_scanner.py).
  property bool busy: data.busy === true
  // Off when the Usage tab is hidden: no polling at all.
  property bool polling: true
  property int intervalSec: 60
  readonly property string scanner: scriptPath("usage_scanner.py")
  function scriptPath(name) { return decodeURIComponent(String(Qt.resolvedUrl("../scripts/" + name)).replace("file://", "")) }
  Process {
    id: process
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.apply(text) }
    onExited: { root.refreshing = false; watchdog.stop() }
  }
  // Only the provider being worked in refreshes fast; the rest wait their interval.
  Timer {
    interval: root.busy ? 10000 : root.intervalSec * 1000
    running: root.polling && root.agentEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }
  // A scanner that hangs would otherwise hold `refreshing` and block every later refresh.
  Timer {
    id: watchdog
    interval: 60000
    onTriggered: if (process.running) process.running = false
  }
  function apply(text) {
    try {
      var next = JSON.parse(text)
      data = next; available = next.available === true
      color = next.display && next.display.color ? next.display.color : color
      name = next.name || name
    } catch (e) { data = { error: "Scanner response could not be read: " + e, usageStatusText: "Scanner error" }; available = false }
    loaded = true
  }
  function refresh(force) {
    if (process.running || !polling) return
    var cmd = ["/usr/bin/python3", scanner, providerId]
    if (force) cmd.push("--force")
    refreshing = true; process.command = cmd; process.running = true
    watchdog.restart()
  }
}
