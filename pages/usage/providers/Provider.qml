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
  property int todaySteps: Number(data.todaySteps || 0)
  property int totalPrompts: Number(data.totalPrompts || 0)
  property var recentDays: data.recentDays || []
  property var toolUsage: data.toolUsage || ({})
  property var modelUsage: data.modelUsage || ({})
  property var modelList: data.modelList || []
  // Per-agent scanner; only Codex, Grok, and Antigravity implement --kill.
  readonly property string scannerScriptPath: canKill ? scriptPath(providerId + "_usage_scanner.py") : ""
  property string executable: data.display ? data.display.executable : providerId
  property bool canKill: data.canKill !== false
  property string quotaNote: data.quotaNote || ""
  property string planTier: data.planTier || ""
  readonly property bool agentEnabled: {
    var key = ({
      codex: "enableCodex",
      grok: "enableGrok",
      antigravity: "enableAntigravity",
      claude: "enableClaude",
      copilot: "enableCopilot",
      cursor: "enableCursor"
    })[providerId]
    if (!key) return true
    var value = settings ? settings[key] : undefined
    return value !== false
  }
  readonly property string scanner: scriptPath("usage_scanner.py")
  function scriptPath(name) { return String(Qt.resolvedUrl("../scripts/" + name)).replace("file://", "") }
  Process {
    id: process
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.apply(text) }
    onExited: root.refreshing = false
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
    if (process.running) return
    var cmd = ["python3", scanner, providerId]
    if (force) cmd.push("--force")
    // usage_scanner.py ignores this for agents without quota alerts.
    if (settings.enableQuotaAlerts !== false) cmd.push("--notify-low-quota", String(settings.quotaAlertThreshold || 15))
    refreshing = true; process.command = cmd; process.running = true
  }
}
