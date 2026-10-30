import QtQuick
import "providers"

Item {
  id: root
  visible: false
  property var settings: ({})
  // Off when the Usage tab is hidden: no provider polls.
  property bool polling: true
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
  property double lastRefreshAllMs: 0
  Provider { id: codex; providerId: "codex"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  Provider { id: xsi; providerId: "xsi"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  Provider { id: antigravity; providerId: "antigravity"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  Provider { id: claude; providerId: "claude"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  Provider { id: copilot; providerId: "copilot"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  Provider { id: muse; providerId: "muse"; settings: root.settings; polling: root.polling; intervalSec: root.refreshIntervalSec }
  // Opening the Usage tab asks for fresh numbers; a scan from seconds ago still is.
  function refreshAll(force) {
    if (!force && Date.now() - lastRefreshAllMs < 5000) return
    lastRefreshAllMs = Date.now()
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
