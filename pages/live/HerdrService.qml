import QtQuick
import Quickshell.Io

// herdr's sessions, polled once for the whole shell. Every bar's Live page
// and the hub's bar dot read these numbers; each page keeps its own cursor,
// blink and pin.
//
// Polled rather than subscribed: herdr has an event socket, but one per
// server, and the count in the bar can be a few seconds old. Faster while a
// Live card is on screen, and while an agent is working or waiting on you,
// the only states that change without you touching anything. A finished
// agent stays finished until you look at it, so it doesn't speed anything up.
Item {
  id: root

  property bool polling: true
  // A Live card is open in some hub, or pinned to the desktop.
  property bool fast: false

  readonly property string script:
    decodeURIComponent(Qt.resolvedUrl("bin/herdr-sessions").toString().replace(/^file:\/\//, ""))

  property var sessions: []
  property int runningCount: 0
  property int agentCount: 0
  property int blockedCount: 0
  property int doneCount: 0
  property int workingCount: 0
  readonly property bool badgeActive: blockedCount > 0 || doneCount > 0 || workingCount > 0
  property bool reachable: true
  property string errorText: ""

  property string lastPayload: ""
  property bool queued: false

  function refresh() {
    if (!polling) return
    if (listProc.running) { queued = true; return }
    listProc.running = true
    watchdog.restart()
  }

  function clear() {
    sessions = []
    runningCount = 0
    agentCount = 0
    blockedCount = 0
    doneCount = 0
    workingCount = 0
  }

  function apply(text) {
    if (text === lastPayload) return
    lastPayload = text
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) { clear(); return }
      runningCount = data.running || 0
      agentCount = data.agents || 0
      blockedCount = data.blocked || 0
      doneCount = data.done || 0
      workingCount = data.working || 0
      sessions = data.sessions || []
    } catch (e) {
      reachable = false
      errorText = "unexpected output from herdr-sessions"
      clear()
    }
  }

  onPollingChanged: {
    if (polling) { refresh(); return }
    clear()
    lastPayload = ""
  }

  Process {
    id: listProc
    command: [root.script, "list"]
    stdout: StdioCollector { onStreamFinished: root.apply(text) }
    onExited: {
      watchdog.stop()
      if (root.queued) { root.queued = false; root.refresh() }
    }
  }

  // A herdr server too wedged to answer would otherwise hold the poll forever.
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: if (listProc.running) listProc.running = false
  }

  Timer {
    interval: root.fast ? 3000 : (root.blockedCount > 0 || root.workingCount > 0 ? 5000 : 20000)
    running: root.polling
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
