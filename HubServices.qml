pragma Singleton
import QtQuick
import Quickshell
import "pages/usage" as Usage
import "pages/live" as Live
import "pages/local" as Local

// The hub's background work, done once for the whole shell. Every monitor's
// bar builds its own AiHub; the pollers live here so a second screen doesn't
// double them, and each hub only draws what this holds.
Singleton {
  id: root

  // Every live AiHub, in the order they registered.
  property var hubs: []
  function addHub(hub) { if (hubs.indexOf(hub) < 0) hubs = hubs.concat([hub]) }
  function removeHub(hub) { hubs = hubs.filter(function(h) { return h !== hub }) }

  // Every hub reads the same shell.json entry, so the first speaks for all.
  readonly property var primary: hubs.length > 0 ? hubs[0] : null
  readonly property var settings: primary && primary.settings ? primary.settings : ({})
  readonly property var visibleKeys: primary ? primary.visibleKeys : []
  function section(key) {
    var value = settings[key]
    return value && typeof value === "object" ? value : ({})
  }
  function tabShown(key) { return visibleKeys.indexOf(key) >= 0 }

  // Pages on screen in any hub, as { usage: true, ... }.
  readonly property var openPages: {
    var open = {}
    for (var i = 0; i < hubs.length; i++) {
      var hub = hubs[i]
      if (hub && hub.popupOpen && !hub.settingsShown) open[hub.currentKey] = true
    }
    return open
  }

  readonly property var localSettings: section("local")

  property alias usage: usageMain
  property alias herdr: herdrService
  property alias lmstudio: lmService
  property alias ollama: ollamaService

  Usage.Main {
    id: usageMain
    settings: root.section("usage")
    polling: root.tabShown("usage")
  }

  Live.HerdrService {
    id: herdrService
    polling: root.tabShown("live")
    fast: root.openPages.live === true || root.section("live").pinned === true
  }

  Local.LmStudioService {
    id: lmService
    settings: root.localSettings
    polling: root.tabShown("local") && root.localSettings.showLmStudio !== false
    detailed: root.openPages.local === true
  }

  Local.OllamaService {
    id: ollamaService
    settings: root.localSettings
    polling: root.tabShown("local") && root.localSettings.showOllama !== false
    detailed: root.openPages.local === true
  }
}
