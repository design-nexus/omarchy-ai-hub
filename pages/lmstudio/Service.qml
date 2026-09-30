import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  // CLI detection
  property bool installed: false

  // Server state
  property bool serverRunning: false
  property int serverPort: 0
  property string serverError: ""

  // Models state
  property var models: []
  property int modelCount: 0
  property var availableModels: []

  // System resource usage (GPU/CPU/RAM), polled directly from the OS
  property var resources: ({})
  property var _prevResources: null

  // UI state
  property bool refreshing: false
  property string statusText: "Checking…"
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic toggle state: -1 = follow reality, 0 = forcing off, 1 = forcing on
  property int _desiredServerState: -1
  readonly property bool active: _desiredServerState === -1 ? serverRunning : (_desiredServerState === 1)

  // One lms client at a time. A call that cannot find the API server spawns a
  // detached `lm-studio --run-as-service`, so overlapping calls start extra copies.
  property bool wantStatus: false
  property bool wantPs: false
  property bool wantLs: false
  property bool wantAction: false
  property var actionArgs: []
  property string currentLms: ""

  readonly property bool busy: whichProcess.running || currentLms !== "" || wantAction

  // Settings with defaults
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // Get LMS path from settings or default
  function lmsPath() {
    return Model.getLmsPath(settings)
  }

  function actionPending() {
    return currentLms === "action" || wantAction
  }

  function pumpLms() {
    if (currentLms !== "") return
    if (!serverRunning && !wantAction) {
      wantStatus = false
      wantPs = false
      wantLs = false
      refreshing = false
      return
    }
    var kind = ""
    var args = []
    if (wantAction) {
      kind = "action"
      args = actionArgs
      wantAction = false
    } else if (wantStatus) {
      kind = "status"
      args = ["server", "status", "--json"]
      wantStatus = false
    } else if (wantPs) {
      kind = "ps"
      args = ["ps", "--json"]
      wantPs = false
    } else if (wantLs) {
      kind = "ls"
      args = ["ls", "--json"]
      wantLs = false
    } else {
      refreshing = false
      return
    }
    currentLms = kind
    if (kind !== "action") refreshing = true
    var cmd = [lmsPath()]
    for (var i = 0; i < args.length; i++) cmd.push(args[i])
    var proc = statusProcess
    if (kind === "ps") proc = psProcess
    else if (kind === "ls") proc = lsProcess
    else if (kind === "action") proc = actionProcess
    proc.command = cmd
    proc.running = true
    pollWatchdog.restart()
  }

  function finishLms(kind) {
    if (currentLms !== kind) return
    currentLms = ""
    pumpLms()
  }

  // Polling must not call lms. Any lms command that cannot find the daemon
  // spawns a new `lm-studio --run-as-service`.
  readonly property string daemonProbe: [
    "if ! pgrep -f \"[l]m-studio|[l]lmster\" >/dev/null 2>&1; then echo down; exit 0; fi",
    "f=\"$HOME/.lmstudio/.internal/http-server.json\"",
    "port=\"\"",
    "if [ -f \"$f\" ]; then port=$(sed -n 's/.*\"port\": *\\([0-9]*\\).*/\\1/p' \"$f\"); fi",
    "if [ -z \"$port\" ] && [ -f \"$HOME/.lmstudio/.internal/http-server-config.json\" ]; then",
    "  port=$(sed -n 's/.*\"port\": *\\([0-9]*\\).*/\\1/p' \"$HOME/.lmstudio/.internal/http-server-config.json\")",
    "fi",
    "port=${port:-1234}",
    "if timeout 0.3 bash -c \"echo >/dev/tcp/127.0.0.1/$port\" >/dev/null 2>&1; then echo up; else echo down; fi"
  ].join("\n")

  function refresh(force) {
    if (!installed) {
      if (!whichProcess.running) {
        refreshing = true
        whichProcess.command = ["which", lmsPath()]
        whichProcess.running = true
      }
      return
    }
    if (probeProcess.running) return
    probeProcess.command = ["bash", "-c", daemonProbe]
    probeProcess.running = true
  }

  function markServerDown() {
    if (_desiredServerState === 1) return
    serverRunning = false
    serverPort = 0
    statusText = "Server stopped"
    models = []
    modelCount = 0
    availableModels = []
    serverError = ""
    refreshing = false
    wantStatus = false
    wantPs = false
    wantLs = false
  }

  function refreshStatusAndModels(forceModels) {
    if (!installed || !serverRunning) return
    wantStatus = true
    wantPs = true
    pumpLms()
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function resetServerState(message) {
    serverRunning = false
    serverPort = 0
    _desiredServerState = -1
    statusText = message
    models = []
    modelCount = 0
    serverError = ""
    resources = {}
    _prevResources = null
  }

  function parseServerStatusOutput(raw) {
    var parsed = Model.parseServerStatus(raw)
    if (!parsed.running && parsed.error) {
      resetServerState(parsed.error)
      lastError = parsed.error
      return
    }
    serverRunning = parsed.running
    serverPort = parsed.port
    // Reality caught up to pending toggle
    if (_desiredServerState !== -1 && serverRunning === (_desiredServerState === 1)) _desiredServerState = -1
    if (parsed.running) {
      statusText = "Connected (port " + parsed.port + ")"
    } else {
      statusText = "Server stopped"
    }
    serverError = parsed.error
    lastError = ""
  }

  function parseModelsOutput(raw) {
    var parsed = Model.parsePs(raw)
    models = parsed
    modelCount = parsed.length
  }

  function toggleServer() {
    if (!installed) return
    if (active) stopServer()
    else startServer()
  }

  function startServer() {
    if (!installed || actionPending()) return
    _desiredServerState = 1
    runAction(["server", "start"], "Starting server…")
  }

  function stopServer() {
    if (!installed || actionPending()) return
    _desiredServerState = 0
    runAction(["server", "stop"], "Stopping server…")
  }

  function loadModel(identifier) {
    if (!installed || actionPending()) return
    runAction(["load", identifier], "Loading model…")
  }

  function unloadModel(identifier) {
    if (!installed || actionPending()) return
    runAction(["unload", identifier], "Unloading model…")
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function copyModelName(model) {
    if (!model) return
    copyToClipboard(model.displayName, model.displayName + " name")
  }

  function copyModelId(model) {
    if (!model) return
    copyToClipboard(model.identifier, model.displayName + " identifier")
  }

  function refreshAvailableModels() {
    if (!installed || !serverRunning) return
    wantLs = true
    pumpLms()
  }

  function copyServerBaseUrl() {
    if (!serverRunning) return
    copyToClipboard("http://localhost:" + serverPort + "/v1", "LLM Server base URL")
  }

  function unloadAllModels() {
    if (!installed || actionPending()) return
    runAction(["unload", "--all"], "Unloading all models…")
  }

  function refreshResources() {
    if (!installed || resProcess.running) return
    resProcess.command = ["bash", "-c", Model.RESOURCE_POLL_SCRIPT]
    resProcess.running = true
  }

  function openLMStudio() {
    Quickshell.execDetached(["gtk-launch", "lmstudio"])
  }

  function quitLMStudio() {
    Quickshell.execDetached(["bash", "-c", "pkill -f lm-studio"])
  }

  function runAction(args, label) {
    actionStatus = label || ""
    actionArgs = args
    wantAction = true
    pumpLms()
  }

  // Timer: periodic refresh
  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Timer: startup ramp - poll quickly until server shows up
  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.serverRunning || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  // Timer: delayed refresh after action
  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  // Timer: poll watchdog - reap hung processes
  Timer {
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      var kind = root.currentLms
      if (kind === "status" && statusProcess.running) statusProcess.running = false
      else if (kind === "ps" && psProcess.running) psProcess.running = false
      else if (kind === "ls" && lsProcess.running) lsProcess.running = false
      else if (kind === "action" && actionProcess.running) actionProcess.running = false
      if (kind !== "" && root.currentLms === kind) root.finishLms(kind)
    }
  }

  // Timer: clear action status after a moment
  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: actionStatus = ""
  }

  // Process: check if LMS CLI exists
  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else {
        root.refreshing = false
        root.resetServerState("LMS CLI not found")
        root.lastError = "Install LM Studio or set custom path in settings"
      }
    }
  }

  // Process: is the daemon already listening? Does not start LM Studio.
  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(probeStdout.text || "").trim()
      if (text === "up") {
        root.serverRunning = true
        root.refreshStatusAndModels()
        root.refreshAvailableModels()
      } else {
        root.markServerDown()
      }
    }
  }

  // Process: server status
  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(statusStdout.text || "")
      var stderr = String(statusStderr.text || "")
      if (exitCode === 0) root.parseServerStatusOutput(stdout)
      else {
        root.resetServerState("Disconnected")
        root.lastError = stderr.trim() || "Server status failed"
      }
      root.finishLms("status")
    }
  }

  // Process: list models (ps)
  Process {
    id: psProcess
    running: false
    command: []
    stdout: StdioCollector { id: psStdout; waitForEnd: true }
    stderr: StdioCollector { id: psStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(psStdout.text || "")
      var stderr = String(psStderr.text || "")
      if (exitCode === 0) root.parseModelsOutput(stdout)
      else {
        root.models = []
        root.modelCount = 0
        root.lastError = stderr.trim() || "Failed to list models"
      }
      root.finishLms("ps")
    }
  }

  // Process: list on-disk models (ls)
  Process {
    id: lsProcess
    running: false
    command: []
    stdout: StdioCollector { id: lsStdout; waitForEnd: true }
    stderr: StdioCollector { id: lsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(lsStdout.text || "")
      if (exitCode === 0) root.availableModels = Model.parseLs(stdout)
      root.finishLms("ls")
    }
  }

  // Process: system resource usage (GPU/CPU/RAM), polled from the OS
  Process {
    id: resProcess
    running: false
    command: []
    stdout: StdioCollector { id: resStdout; waitForEnd: true }
    stderr: StdioCollector { id: resStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(resStdout.text || "")
      var parsed = Model.parseResources(stdout, root._prevResources)
      root._prevResources = parsed.next
      if (parsed.gpuUtil >= 0 || parsed.ramTotal > 0) root.resources = parsed
    }
  }

  // Process: actions (start/stop/load/unload)
  Process {
    id: actionProcess
    running: false
    command: []
    property string actionStatus: ""
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || "")
      var stderr = String(actionStderr.text || "")
      if (exitCode !== 0) {
        root._desiredServerState = -1
        root.lastError = elideStatus(stderr || stdout || "Command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
      root.finishLms("action")
    }
  }
}