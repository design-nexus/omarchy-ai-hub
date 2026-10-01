import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "pages/usage" as Usage
import "pages/live" as Live
import "pages/sessions" as Sessions
import "pages/skills" as Skills
import "pages/local" as Local

// One bar icon for every AI tool: usage and quotas, live herdr agents, past
// sessions, loaded skills, and local model servers (LM Studio and Ollama).
// Each tab is a copy of the original plugin, running unchanged except that
// its popup body renders here (EmbeddedPanel) and its bar facade is a
// PageBar proxy. Tabs can be hidden in the hub settings (the gear); a hidden
// tab's page is not loaded at all, so it stops polling.
BarWidget {
  id: root
  moduleName: "design-nexus.ai-hub"

  readonly property var pageKeys: ["usage", "live", "sessions", "skills", "local"]
  readonly property var pageTitles: ({
    usage: "Usage", live: "Live", sessions: "Sessions", skills: "Skills", local: "Local"
  })

  // Saved under the hub entry's `tabs` key as { usage: false, ... }; a tab
  // missing from it is shown. At least one tab always stays visible.
  readonly property var tabSettings: pageSettings("tabs")
  function tabShown(key) { return tabSettings[key] !== false }
  readonly property var visibleKeys: {
    var keys = pageKeys.filter(function(key) { return root.tabShown(key) })
    return keys.length > 0 ? keys : ["usage"]
  }

  // The Local page's servers, saved under `local`.
  readonly property var localSettings: pageSettings("local")
  readonly property bool lmStudioShown: localSettings.showLmStudio !== false
  readonly property bool ollamaShown: localSettings.showOllama !== false

  property string currentKey: "usage"
  property bool popupOpen: false
  property bool popoutSwitchClosing: false
  property bool switching: false
  property var panels: ({})
  readonly property bool settingsShown: currentKey === "settings"
  readonly property var activePanel: settingsShown ? null : (panels[currentKey] || null)
  readonly property bool activePanelShown: !!activePanel && activePanel.open

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var usagePage: usageLoader.item
  readonly property var livePage: liveLoader.item
  readonly property var sessionsPage: sessionsLoader.item
  readonly property var skillsPage: skillsLoader.item
  readonly property var localPage: localLoader.item

  // ------------------------------------------------------------ page host API

  readonly property alias pageArea: pageArea
  readonly property real borderInsetV: Border.top(panel.borderSpec) + Border.bottom(panel.borderSpec)
  readonly property real borderInsetH: Border.left(panel.borderSpec) + Border.right(panel.borderSpec)
  readonly property real availablePageWidth: Math.max(120, panel.availableCardWidth - borderInsetH)
  readonly property real availablePageHeight: Math.max(120, panel.availableCardHeight - borderInsetV - tabRow.height)

  function pageSettings(key) {
    var value = settings ? settings[key] : null
    return value && typeof value === "object" ? value : ({})
  }

  function savePageSettings(key, entry) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = {}
    for (var k in settings) if (k !== "id") next[k] = settings[k]
    var page = {}
    for (var p in entry) if (p !== "id") page[p] = entry[p]
    next[key] = page
    return shell.updateEntryInline(root.moduleName, next)
  }

  // One value inside a page's settings object, keeping the rest of it.
  function savePageSetting(key, name, value) {
    var entry = {}
    var current = pageSettings(key)
    for (var k in current) entry[k] = current[k]
    entry[name] = value
    return savePageSettings(key, entry)
  }

  function registerPanel(item) {
    if (!item || !item.pageKey || panels[item.pageKey] === item) return
    var next = {}
    for (var k in panels) next[k] = panels[k]
    next[item.pageKey] = item
    panels = next
    if (item.open) pageOpenChanged(item)
  }

  function unregisterPanel(key) {
    if (!(key in panels)) return
    var next = {}
    for (var k in panels) if (k !== key) next[k] = panels[k]
    panels = next
  }

  function pageOpenChanged(item) {
    if (!item || item.pageKey !== currentKey) return
    if (item.open) {
      if (popupOpen) Qt.callLater(focusActive)
      return
    }
    // The page closed itself (Escape, q, an action that dismisses): close the
    // hub with it, unless it only handed its card to a pinned window. Checked a
    // tick later, once the page's own `opened` binding has caught up.
    if (switching || !popupOpen) return
    var key = item.pageKey
    Qt.callLater(function() {
      if (!root.switching && root.popupOpen && root.currentKey === key && !root.pageIsOpen(key)) root.close()
    })
  }

  function focusActive() {
    if (!popupOpen) return
    if (settingsShown) settingsView.forceActiveFocus()
    else if (activePanel && activePanel.focusTarget) activePanel.focusTarget.forceActiveFocus()
  }

  // Tab / Shift+Tab from inside a page: next tab, then on past the ends to the
  // neighbouring bar panel.
  function cyclePage(direction) {
    var i = visibleKeys.indexOf(currentKey) + (direction < 0 ? -1 : 1)
    if (settingsShown) i = direction < 0 ? visibleKeys.length - 1 : 0
    if (i < 0 || i >= visibleKeys.length) {
      return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(root, direction) : false
    }
    showPage(visibleKeys[i])
    return true
  }

  function stepPage(direction) {
    var keys = visibleKeys
    var i = keys.indexOf(currentKey)
    if (i < 0) i = direction > 0 ? -1 : 0
    showPage(keys[(i + direction + keys.length) % keys.length])
  }

  // ------------------------------------------------------------ page adapters

  function entry(key) {
    return ({ usage: usagePage, live: livePage, sessions: sessionsPage, skills: skillsPage, local: localPage })[key] || null
  }

  function pageIsOpen(key) {
    var e = entry(key)
    if (!e) return false
    return key === "usage" ? e.popupOpen === true : e.opened === true
  }

  function openPage(key) {
    var e = entry(key)
    if (!e) return
    if (key === "usage") {
      e.showUsage()
      e.popupOpen = true
      e.triggerRefresh(false)
    } else {
      e.open()
    }
  }

  function closePage(key) {
    var e = entry(key)
    if (!e) return
    // A pinned herdr card lives on after the hub closes.
    if (key === "live" && e.pinned) return
    e.close()
  }

  // ------------------------------------------------------------ open / close

  // Every fresh open lands on Usage, or the first visible tab when Usage is
  // hidden; showPage() is the way to another tab.
  function open() {
    if (popupOpen) return
    currentKey = visibleKeys[0]
    popupOpen = true
    openPage(currentKey)
  }

  function close() {
    if (!popupOpen) return
    popupOpen = false
    switching = true
    closePage(currentKey)
    switching = false
  }

  function toggle() { popupOpen ? close() : open() }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  function showPage(key) {
    if (key !== "settings" && visibleKeys.indexOf(key) < 0) return
    if (key === currentKey && popupOpen) return
    switching = true
    if (popupOpen && key !== currentKey) closePage(currentKey)
    currentKey = key
    switching = false
    popupOpen = true
    openPage(key)
    Qt.callLater(focusActive)
  }

  function toggleSettings() {
    if (settingsShown && popupOpen) showPage(visibleKeys[0])
    else showPage("settings")
  }

  function refreshAll() {
    if (usagePage) usagePage.triggerRefresh(true)
    if (livePage) livePage.refresh()
    if (localPage) localPage.refresh()
  }

  // A tab hidden while it is on screen hands over to the first visible one.
  onVisibleKeysChanged: {
    if (settingsShown || visibleKeys.indexOf(currentKey) >= 0) return
    var next = visibleKeys[0]
    if (popupOpen) Qt.callLater(function() { root.showPage(next) })
    else currentKey = next
  }

  // ------------------------------------------------------------ bar summary

  readonly property int liveBlocked: livePage ? livePage.blockedCount : 0
  readonly property int liveDone: livePage ? livePage.doneCount : 0
  readonly property int liveWorking: livePage ? livePage.workingCount : 0
  readonly property int liveAgents: livePage ? livePage.agentCount : 0
  readonly property color liveColor: liveBlocked > 0 ? urgent : (!livePage ? foreground : (liveDone > 0 ? livePage.finished : livePage.working))
  readonly property bool localActive: !!localPage && localPage.active === true

  function tabLabel(key) {
    var title = pageTitles[key]
    if (key === "live" && liveAgents > 0) return title + " " + liveAgents
    if (key === "local" && localActive) return title + " ●"
    return title
  }

  function tooltip() {
    var lines = ["AI hub"]
    if (usagePage && usagePage.activeSessionTotal > 0) lines.push(usagePage.activeSessionTotal + " active agent session" + (usagePage.activeSessionTotal === 1 ? "" : "s"))
    if (liveAgents > 0) {
      var parts = []
      if (liveBlocked > 0) parts.push(liveBlocked + " waiting")
      if (liveWorking > 0) parts.push(liveWorking + " working")
      if (liveDone > 0) parts.push(liveDone + " done")
      lines.push("herdr: " + liveAgents + " agents" + (parts.length ? " (" + parts.join(", ") + ")" : ""))
    }
    if (localPage) {
      if (lmStudioShown) lines.push("LM Studio: " + (localPage.lmstudio.active ? "running" : "stopped"))
      if (ollamaShown) lines.push("Ollama: " + (localPage.ollama.active ? "running" : "stopped"))
    }
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ hosted pages

  PageBar { id: usageBar; realBar: root.bar; pageHost: root; pageKey: "usage"; pageEntry: root.usagePage }
  PageBar { id: liveBar; realBar: root.bar; pageHost: root; pageKey: "live"; pageEntry: root.livePage }
  PageBar { id: sessionsBar; realBar: root.bar; pageHost: root; pageKey: "sessions"; pageEntry: root.sessionsPage }
  PageBar { id: skillsBar; realBar: root.bar; pageHost: root; pageKey: "skills"; pageEntry: root.skillsPage }
  PageBar { id: localBar; realBar: root.bar; pageHost: root; pageKey: "local"; pageEntry: root.localPage }

  // The pages' own bar buttons live here, never shown; only their popup
  // bodies are reparented into the hub panel. Hidden tabs are not loaded.
  Item {
    id: pageHolder
    visible: false
    width: 0
    height: 0

    Loader {
      id: usageLoader
      active: root.tabShown("usage") || root.visibleKeys[0] === "usage"
      onActiveChanged: if (!active) root.unregisterPanel("usage")
      sourceComponent: Component { Usage.Widget { bar: usageBar; settings: root.pageSettings("usage") } }
    }
    Loader {
      id: liveLoader
      active: root.tabShown("live")
      onActiveChanged: if (!active) root.unregisterPanel("live")
      sourceComponent: Component { Live.Panel { bar: liveBar; settings: root.pageSettings("live") } }
    }
    Loader {
      id: sessionsLoader
      active: root.tabShown("sessions")
      onActiveChanged: if (!active) root.unregisterPanel("sessions")
      sourceComponent: Component { Sessions.BarWidget { bar: sessionsBar; settings: root.pageSettings("sessions") } }
    }
    Loader {
      id: skillsLoader
      active: root.tabShown("skills")
      onActiveChanged: if (!active) root.unregisterPanel("skills")
      sourceComponent: Component { Skills.BarWidget { bar: skillsBar; settings: root.pageSettings("skills") } }
    }
    Loader {
      id: localLoader
      active: root.tabShown("local")
      onActiveChanged: if (!active) root.unregisterPanel("local")
      sourceComponent: Component { Local.Panel { bar: localBar; settings: root.pageSettings("local") } }
    }
  }

  IpcHandler {
    target: "design-nexus.ai-hub"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function page(name: string): string {
      var key = name === "lmstudio" || name === "ollama" ? "local" : name
      if (key === "settings") { root.showPage(key); return "ok" }
      if (root.visibleKeys.indexOf(key) < 0) return "unknown or hidden page: " + name + " (" + root.visibleKeys.join(", ") + ", settings)"
      root.showPage(key)
      return "ok"
    }
    function refresh(): string { root.refreshAll(); return "ok" }
    function current(): string { return root.popupOpen ? root.currentKey : "closed" }
  }

  // ------------------------------------------------------------ bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltip()
    fixedWidth: root.vertical ? -1 : Math.round(chip.width + Style.spaceReal(8.5) * 2)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refreshAll()
      else if (b === Qt.RightButton && root.localPage) root.showPage("local")
      else root.toggle()
    }

    Row {
      id: chip
      anchors.centerIn: parent
      spacing: Style.space(3)

      Item {
        id: iconArea
        anchors.verticalCenter: parent.verticalCenter
        width: 18
        height: 18

        Image {
          id: hubIcon
          source: Qt.resolvedUrl("pages/usage/assets/omarchy.png")
          width: 12
          height: 12
          sourceSize.width: Math.round(12 * (Screen.devicePixelRatio || 1))
          sourceSize.height: Math.round(12 * (Screen.devicePixelRatio || 1))
          fillMode: Image.PreserveAspectFit
          anchors.centerIn: parent
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: hubIcon
          source: hubIcon
          colorization: 1.0
          colorizationColor: root.foreground
          brightness: 0.3
        }

        // Provider activity dots, as the usage widget drew them.
        Repeater {
          model: root.usagePage && root.tabShown("usage") ? root.usagePage.allProviders : []
          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool live: modelData.agentEnabled && modelData.available && modelData.hasActiveSession
            width: 3
            height: 3
            radius: 1.5
            visible: live
            color: modelData.color
            x: (index % 3) * ((iconArea.width - width) / 2)
            y: index < 3 ? 0 : iconArea.height - height
            SequentialAnimation on opacity {
              running: live
              loops: Animation.Infinite
              NumberAnimation { from: .25; to: 1; duration: 600; easing.type: Easing.InOutQuad }
              NumberAnimation { from: 1; to: .25; duration: 600; easing.type: Easing.InOutQuad }
            }
          }
        }
      }

      // Active agent count (usage badge mode), then herdr state and the local servers.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.usagePage && root.tabShown("usage") ? root.usagePage.badgeText : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: !!root.livePage && root.livePage.badgeActive
        width: 5
        height: 5
        radius: 2.5
        color: root.liveColor
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.localActive
        width: 5
        height: 5
        radius: 2.5
        color: "transparent"
        border.width: 1
        border.color: root.foreground
      }
    }
  }

  // ------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    padding: 0
    focusTarget: root.settingsShown ? settingsView : (root.activePanel ? root.activePanel.focusTarget : null)
    // One width for every tab: the Usage page's 390, or just enough for the tab
    // strip at its widest labels if that is more. Pages fill it; none sets it.
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(390),
      tabSizer.implicitWidth + settingsButton.width + Style.space(12) * 3 + root.borderInsetH))
    contentHeight: root.borderInsetV + tabRow.height
      + (root.settingsShown ? settingsView.implicitHeight
        : (root.activePanelShown ? root.activePanel.contentHeight : placeholder.implicitHeight))

    // Page switching that works whatever the page does with its own keys.
    Item {
      width: 0
      height: 0

      Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+PgDown"]
        enabled: root.popupOpen
        onActivated: root.stepPage(1)
      }
      Shortcut {
        sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab", "Ctrl+PgUp"]
        enabled: root.popupOpen
        onActivated: root.stepPage(-1)
      }
      Repeater {
        model: 5
        delegate: Item {
          required property int index
          Shortcut {
            sequence: "Alt+" + (index + 1)
            enabled: root.popupOpen && index < root.visibleKeys.length
            onActivated: root.showPage(root.visibleKeys[index])
          }
        }
      }
      Shortcut {
        sequence: "Alt+0"
        enabled: root.popupOpen
        onActivated: root.toggleSettings()
      }
    }

    Column {
      anchors.fill: parent

      Item {
        id: tabRow
        width: parent.width
        height: tabs.implicitHeight + Style.space(12) * 2

        // Never shown: the strip with its widest labels, so a count or dot
        // appearing on a tab never changes the panel width.
        ButtonGroup {
          id: tabSizer
          visible: false
          focusable: false
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          options: root.visibleKeys.map(function(key) {
            return key === "live" ? "Live 00" : (key === "local" ? "Local ●" : root.pageTitles[key])
          })
        }

        ButtonGroup {
          id: tabs
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          focusable: false
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          foreground: Color.foreground
          value: root.currentKey
          options: root.visibleKeys.map(function(key) {
            return { value: key, label: root.tabLabel(key) }
          })
          onChanged: function(value) { root.showPage(value) }
        }

        Button {
          id: settingsButton
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          width: tabs.implicitHeight
          height: tabs.implicitHeight
          horizontalPadding: 0
          verticalPadding: 0
          iconText: "󰒓"
          iconSize: Style.font.iconSmall
          foreground: Color.foreground
          fontFamily: root.fontFamily
          hasCursor: root.settingsShown
          tooltipText: root.settingsShown ? "Back (Alt+0)" : "Hub settings (Alt+0)"
          onClicked: root.toggleSettings()
        }
      }

      Item {
        id: pageArea
        width: parent.width
        clip: true
        height: parent.height - tabRow.height

        // Shown while a page has no card here: herdr pinned to the desktop,
        // or a page that has not mounted its panel yet.
        Column {
          id: placeholder
          anchors.centerIn: parent
          visible: !root.settingsShown && !root.activePanelShown
          spacing: Style.space(8)
          padding: Style.space(24)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.currentKey === "live" && root.livePage && root.livePage.pinned ? "herdr is pinned to the desktop" : "Loading…"
            color: Color.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.currentKey === "live" && !!root.livePage && root.livePage.pinned
            text: "Unpin"
            onClicked: root.livePage.togglePin()
          }
        }

        HubSettings {
          id: settingsView
          visible: root.settingsShown
          width: parent.width
          hub: root
          foreground: Color.foreground
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
