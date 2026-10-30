import QtQuick
import "providers"

Item {
  id: root
  visible: false
  property var settings: ({})
  property var allProviders: [codex, xsi, antigravity, claude, copilot, muse]
  property var enabledProviders: {
    var result = []
    for (var i = 0; i < allProviders.length; i++) {
      if (allProviders[i].agentEnabled) result.push(allProviders[i])
    }
    return result
  }
  property bool anyActive: allProviders.some(function(p) { return p.agentEnabled && p.hasActiveSession })
  property bool refreshing: allProviders.some(function(p) { return p.agentEnabled && p.refreshing })
  property int refreshIntervalSec: Math.max(10, Number(settings.refreshIntervalSec || 60))
  Provider { id: codex; providerId: "codex"; settings: root.settings }
  Provider { id: xsi; providerId: "xsi"; settings: root.settings }
  Provider { id: antigravity; providerId: "antigravity"; settings: root.settings }
  Provider { id: claude; providerId: "claude"; settings: root.settings }
  Provider { id: copilot; providerId: "copilot"; settings: root.settings }
  Provider { id: muse; providerId: "muse"; settings: root.settings }
  Timer { interval: root.anyActive ? 10000 : root.refreshIntervalSec * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshAll(false) }
  function refreshAll(force) {
    for (var i = 0; i < allProviders.length; i++) {
      if (allProviders[i].agentEnabled) allProviders[i].refresh(force)
    }
  }
  function providerFor(id) {
    if (id === "grok" || id === "cursor") id = "xsi"
    for (var i = 0; i < allProviders.length; i++) {
      if (allProviders[i].providerId === id && allProviders[i].agentEnabled) return allProviders[i]
    }
    return null
  }
}
