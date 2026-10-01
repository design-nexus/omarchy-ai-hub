import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Ollama's server, through its HTTP API (bin/ollama-ctl). Same interface as
// LmStudioService, so the Local page draws both with one ServerSection.
Item {
  id: root

  property var settings: ({})
  // Off when the Local tab or the Ollama section is hidden: no polling.
  property bool polling: true

  readonly property string kind: "ollama"
  readonly property string name: "Ollama"
  readonly property string notInstalledText: "Ollama not found"
  readonly property string notInstalledHint: "Install it with 'sudo pacman -S ollama', or set ollamaUrl in the local settings"
  readonly property string noModelsHint: "No models loaded. Load one below, or with 'ollama run <model>'."
  readonly property string openLabel: "Chat"
  readonly property string openTooltip: "Chat with the selected model in a terminal (O)"
  readonly property bool canOpen: installed && serverRunning && modelCount > 0
  readonly property bool canQuit: false
  readonly property string baseUrl: serverRunning ? hostUrl + "/v1" : ""

  readonly property string hostUrl: {
    var url = String(setting("ollamaUrl", "") || "").trim()
    if (url === "") url = "http://127.0.0.1:11434"
    if (!/^https?:\/\//.test(url)) url = "http://" + url
    return url.replace(/\/+$/, "")
  }
  readonly property string ctl: Qt.resolvedUrl("bin/ollama-ctl").toString().replace(/^file:\/\//, "")

  // Ollama is installed when its CLI is here, or when a server answers anyway
  // (one on another machine, or in a container).
  property bool cliFound: false
  readonly property bool installed: cliFound || serverRunning

  property bool serverRunning: false
  readonly property int serverPort: {
    var m = /:(\d+)$/.exec(hostUrl)
    return m ? parseInt(m[1], 10) : (hostUrl.indexOf("https://") === 0 ? 443 : 80)
  }
  property string serverError: ""
  property string version: ""

  property var models: []
  property int modelCount: 0
  property var availableModels: []
  property var modelInfo: ({})

  property bool refreshing: false
  property string statusText: "Checking…"
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic toggle state: -1 = follow reality, 0 = forcing off, 1 = forcing on
  property int _desiredServerState: -1
  readonly property bool active: _desiredServerState === -1 ? serverRunning : (_desiredServerState === 1)

  readonly property bool busy: actionProcess.running || (_desiredServerState !== -1)

  readonly property int refreshIntervalSec: intSetting("ollamaRefreshSec", 30, 5, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function ctlCommand(args) {
    return ["env", "OLLAMA_URL=" + hostUrl, ctl].concat(args)
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function refresh() {
    if (!polling) return
    if (!whichProcess.running && !cliFound) {
      whichProcess.command = ["bash", "-c", "command -v ollama"]
      whichProcess.running = true
    }
    if (probeProcess.running) return
    refreshing = true
    probeProcess.command = ctlCommand(["probe"])
    probeProcess.running = true
  }

  function refreshModels() {
    if (!polling || !serverRunning || psProcess.running) return
    psProcess.command = ctlCommand(["ps"])
    psProcess.running = true
  }

  function refreshAvailableModels() {
    if (!polling || !serverRunning || tagsProcess.running) return
    tagsProcess.command = ctlCommand(["tags"])
    tagsProcess.running = true
  }

  function markServerDown() {
    if (_desiredServerState === 1 && startWait.running) return
    if (_desiredServerState === 0) _desiredServerState = -1
    serverRunning = false
    version = ""
    statusText = installed ? "Server stopped" : notInstalledText
    models = []
    modelCount = 0
    serverError = ""
  }

  function markServerUp(text) {
    serverRunning = true
    if (_desiredServerState === 1) _desiredServerState = -1
    try { version = String(JSON.parse(text).version || "") } catch (e) { version = "" }
    statusText = "Connected (port " + serverPort + ")"
    refreshModels()
    if (availableModels.length === 0) refreshAvailableModels()
  }

  function toggleServer() {
    if (!installed) return
    if (active) stopServer()
    else startServer()
  }

  function startServer() {
    if (!cliFound || actionProcess.running) return
    _desiredServerState = 1
    startWait.restart()
    runAction(["start"], "Starting server…")
  }

  function stopServer() {
    if (!cliFound || actionProcess.running) return
    _desiredServerState = 0
    runAction(["stop"], "Stopping server…")
  }

  function isEmbed(identifier) {
    var info = modelInfo[identifier]
    return !!info && info.embed === true
  }

  function loadModel(identifier) {
    if (!serverRunning || actionProcess.running || !identifier) return
    var args = ["load", identifier]
    if (isEmbed(identifier)) args.push("embed")
    runAction(args, "Loading " + Model.ollamaDisplayName(identifier) + "…")
  }

  function unloadModel(identifier) {
    if (!serverRunning || actionProcess.running || !identifier) return
    var args = ["unload", identifier]
    if (isEmbed(identifier)) args.push("embed")
    runAction(args, "Unloading model…")
  }

  function unloadAllModels() {
    if (!serverRunning || actionProcess.running || models.length === 0) return
    // One shell, one model after another, so a failure names its model.
    var script = []
    for (var i = 0; i < models.length; i++) {
      var id = models[i].identifier
      script.push(Util.shellQuote(ctl) + " unload " + Util.shellQuote(id) + (isEmbed(id) ? " embed" : "") + " || exit 1")
    }
    actionStatus = "Unloading all models…"
    actionProcess.command = ["env", "OLLAMA_URL=" + hostUrl, "bash", "-c", script.join("\n")]
    actionProcess.running = true
    actionWatchdog.restart()
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function copyModelName(model) { if (model) copyToClipboard(model.displayName) }
  function copyModelId(model) { if (model) copyToClipboard(model.identifier) }
  function copyServerBaseUrl() { if (serverRunning) copyToClipboard(baseUrl) }

  // Chat in a terminal with the given model, or the first loaded one.
  function openApp(model) {
    var m = model || (models.length > 0 ? models[0] : null)
    if (!m || m.embed) return
    var terminal = String(setting("terminalCommand", "") || "").trim() || "xdg-terminal-exec"
    Quickshell.execDetached(["bash", "-c",
      terminal + " env OLLAMA_HOST=" + Util.shellQuote(hostUrl) + " ollama run " + Util.shellQuote(m.identifier)])
  }

  function quitApp() {}

  function runAction(args, label) {
    actionStatus = label || ""
    actionProcess.command = ctlCommand(args)
    actionProcess.running = true
    actionWatchdog.restart()
  }

  onPollingChanged: {
    if (polling) {
      refresh()
      return
    }
    serverRunning = false
    _desiredServerState = -1
    statusText = "Hidden"
    models = []
    modelCount = 0
    availableModels = []
    lastError = ""
    actionStatus = ""
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.polling
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // After a start, poll quickly until the server answers or 30 s pass.
  Timer {
    id: startWait
    property int ticks: 0
    interval: 1000
    repeat: true
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      if (root.serverRunning || ticks >= 30) {
        running = false
        if (!root.serverRunning && root._desiredServerState === 1) {
          root._desiredServerState = -1
          root.lastError = "Ollama did not start"
        }
      } else {
        root.refresh()
      }
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    onTriggered: { root.refresh(); root.refreshAvailableModels() }
  }

  // Loading a large model can take minutes; ollama-ctl gives up at 10.
  Timer {
    id: actionWatchdog
    interval: 660000
    onTriggered: if (actionProcess.running) actionProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: whichProcess
    onExited: function(exitCode) {
      root.cliFound = exitCode === 0
      if (!root.installed) {
        root.statusText = root.notInstalledText
        root.refreshing = false
      }
    }
  }

  Process {
    id: probeProcess
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(probeStdout.text || "").trim()
      if (text.indexOf("{") === 0) root.markServerUp(text)
      else root.markServerDown()
      root.refreshing = false
    }
  }

  Process {
    id: psProcess
    stdout: StdioCollector { id: psStdout; waitForEnd: true }
    stderr: StdioCollector { id: psStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = Model.parseOllamaPs(psStdout.text, root.modelInfo)
        root.models = parsed
        root.modelCount = parsed.length
      } else {
        root.lastError = root.elideStatus(psStderr.text || "Failed to list models")
      }
    }
  }

  Process {
    id: tagsProcess
    stdout: StdioCollector { id: tagsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseOllamaTags(tagsStdout.text)
      root.availableModels = parsed.options
      root.modelInfo = parsed.info
      // Embedding flags and quantization come from tags; redraw the cards.
      root.refreshModels()
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      actionWatchdog.stop()
      if (exitCode !== 0) {
        root._desiredServerState = -1
        startWait.stop()
        root.lastError = root.elideStatus(actionStderr.text || actionStdout.text || "Command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }
}
