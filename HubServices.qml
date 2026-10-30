pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
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

  // The hub a script command acts on: the open one, else the one on the
  // focused output, like the shell's own panel hotkeys.
  function openHub() {
    for (var i = 0; i < hubs.length; i++) if (hubs[i].popupOpen) return hubs[i]
    return null
  }
  function focusedHub() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < hubs.length; i++) if (hubs[i].screenName === name) return hubs[i]
    return primary
  }
  function commandHub() { return openHub() || focusedHub() }

  // One handler for the shell rather than one per bar, where only the first
  // registered copy ever answered.
  ShellIpc {
    target: "design-nexus.ai-hub"
    function open(): void { var hub = root.focusedHub(); if (hub) hub.open() }
    function close(): void { var hub = root.openHub(); if (hub) hub.close() }
    function show(): void { var hub = root.focusedHub(); if (hub) hub.open() }
    function hide(): void { var hub = root.openHub(); if (hub) hub.close() }
    function toggle(): void {
      var hub = root.openHub()
      if (hub) hub.close()
      else if ((hub = root.focusedHub())) hub.open()
    }
    function page(name: string): string {
      var hub = root.commandHub()
      if (!hub) return "no AI Hub on the bar"
      var key = name === "lmstudio" || name === "ollama" ? "local" : name
      if (key === "settings") { hub.showPage(key); return "ok" }
      if (hub.visibleKeys.indexOf(key) < 0) return "unknown or hidden page: " + name + " (" + hub.visibleKeys.join(", ") + ", settings)"
      hub.showPage(key)
      return "ok"
    }
    function refresh(): string { var hub = root.commandHub(); if (hub) hub.refreshAll(); return "ok" }
    function current(): string { var hub = root.openHub(); return hub ? hub.currentKey : "closed" }
  }

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
