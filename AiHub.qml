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
import "pages/lmstudio" as LmStudio

// One bar icon for every AI tool: usage and quotas, live herdr agents, past
// sessions, loaded skills, and the LM Studio server. Each tab is a copy of
// the original plugin, running unchanged except that its popup body renders
// here (EmbeddedPanel) and its bar facade is a PageBar proxy.
BarWidget {
  id: root
  moduleName: "design-nexus.ai-hub"

  readonly property var pageKeys: ["usage", "live", "sessions", "skills", "lmstudio"]
  readonly property var pageTitles: ({
    usage: "Usage", live: "Live", sessions: "Sessions", skills: "Skills", lmstudio: "LM Studio"
  })

  property string currentKey: pageKeys.indexOf(String(setting("defaultPage", "usage"))) >= 0
    ? String(setting("defaultPage", "usage")) : "usage"
  property bool popupOpen: false
  property bool popoutSwitchClosing: false
  property bool switching: false
  property var panels: ({})
  readonly property var activePanel: panels[currentKey] || null
  readonly property bool activePanelShown: !!activePanel && activePanel.open

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

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

  function registerPanel(item) {
    if (!item || !item.pageKey || panels[item.pageKey] === item) return
    var next = {}
    for (var k in panels) next[k] = panels[k]
    next[item.pageKey] = item
    panels = next
    if (item.open) pageOpenChanged(item)
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
    if (popupOpen && activePanel && activePanel.focusTarget) activePanel.focusTarget.forceActiveFocus()
  }

  // Tab / Shift+Tab from inside a page: next tab, then on past the ends to the
  // neighbouring bar panel.
  function cyclePage(direction) {
    var i = pageKeys.indexOf(currentKey) + (direction < 0 ? -1 : 1)
    if (i < 0 || i >= pageKeys.length) {
      return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(root, direction) : false
    }
    showPage(pageKeys[i])
    return true
  }

  // ------------------------------------------------------------ page adapters

  function entry(key) {
    return ({ usage: usagePage, live: livePage, sessions: sessionsPage, skills: skillsPage, lmstudio: lmstudioPage })[key] || null
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

  function open() {
    if (popupOpen) return
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
    if (pageKeys.indexOf(key) < 0) return
    if (key === currentKey) {
      open()
      return
    }
    switching = true
    if (popupOpen) closePage(currentKey)
    currentKey = key
    switching = false
    if (popupOpen) openPage(key)
    else open()
    Qt.callLater(focusActive)
  }

  function refreshAll() {
    usagePage.triggerRefresh(true)
    livePage.refresh()
    lmstudioPage.lmstudio.refresh()
  }

  // ------------------------------------------------------------ bar summary

  readonly property int liveBlocked: livePage.blockedCount
  readonly property int liveDone: livePage.doneCount
  readonly property int liveWorking: livePage.workingCount
  readonly property color liveColor: liveBlocked > 0 ? urgent : (liveDone > 0 ? livePage.finished : livePage.working)
  readonly property bool lmActive: lmstudioPage.lmstudio.active === true

  function tabLabel(key) {
    var title = pageTitles[key]
    if (key === "live" && livePage.agentCount > 0) return title + " " + livePage.agentCount
    if (key === "lmstudio" && lmActive) return title + " ●"
    return title
  }

  function tooltip() {
    var lines = ["AI hub"]
    if (usagePage.activeSessionTotal > 0) lines.push(usagePage.activeSessionTotal + " active agent session" + (usagePage.activeSessionTotal === 1 ? "" : "s"))
    if (livePage.agentCount > 0) {
      var parts = []
      if (liveBlocked > 0) parts.push(liveBlocked + " waiting")
      if (liveWorking > 0) parts.push(liveWorking + " working")
      if (liveDone > 0) parts.push(liveDone + " done")
      lines.push("herdr: " + livePage.agentCount + " agents" + (parts.length ? " (" + parts.join(", ") + ")" : ""))
    }
    lines.push("LM Studio: " + (lmActive ? "running" : "stopped"))
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ hosted pages

  PageBar { id: usageBar; realBar: root.bar; pageHost: root; pageKey: "usage"; pageEntry: usagePage }
  PageBar { id: liveBar; realBar: root.bar; pageHost: root; pageKey: "live"; pageEntry: livePage }
  PageBar { id: sessionsBar; realBar: root.bar; pageHost: root; pageKey: "sessions"; pageEntry: sessionsPage }
  PageBar { id: skillsBar; realBar: root.bar; pageHost: root; pageKey: "skills"; pageEntry: skillsPage }
  PageBar { id: lmstudioBar; realBar: root.bar; pageHost: root; pageKey: "lmstudio"; pageEntry: lmstudioPage }

  // The pages' own bar buttons live here, never shown; only their popup
  // bodies are reparented into the hub panel.
  Item {
    id: pageHolder
    visible: false
    width: 0
    height: 0

    Usage.Widget { id: usagePage; bar: usageBar; settings: root.pageSettings("usage") }
    Live.Panel { id: livePage; bar: liveBar; settings: root.pageSettings("live") }
    Sessions.BarWidget { id: sessionsPage; bar: sessionsBar; settings: root.pageSettings("sessions") }
    Skills.BarWidget { id: skillsPage; bar: skillsBar; settings: root.pageSettings("skills") }
    LmStudio.Panel { id: lmstudioPage; bar: lmstudioBar; settings: root.pageSettings("lmstudio") }
  }

  IpcHandler {
    target: "design-nexus.ai-hub"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function page(name: string): string {
      if (root.pageKeys.indexOf(name) < 0) return "unknown page: " + name + " (" + root.pageKeys.join(", ") + ")"
      root.showPage(name)
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
      else if (b === Qt.RightButton) root.showPage("lmstudio")
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
          model: usagePage.allProviders
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

      // Active agent count (usage badge mode), then herdr state and LM Studio.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        textFormat: Text.PlainText
        text: usagePage.badgeText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: livePage.badgeActive
        width: 5
        height: 5
        radius: 2.5
        color: root.liveColor
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.lmActive
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
    focusTarget: root.activePanel ? root.activePanel.focusTarget : null
    // One width for every tab: the Usage page's 390, or just enough for the tab
    // strip at its widest labels if that is more. Pages fill it; none sets it.
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(390),
      tabSizer.implicitWidth + Style.space(12) * 2 + root.borderInsetH))
    contentHeight: root.borderInsetV + tabRow.height
      + (root.activePanelShown ? root.activePanel.contentHeight : placeholder.implicitHeight)

    // Page switching that works whatever the page does with its own keys.
    Item {
      width: 0
      height: 0

      Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+PgDown"]
        enabled: root.popupOpen
        onActivated: root.showPage(root.pageKeys[(root.pageKeys.indexOf(root.currentKey) + 1) % root.pageKeys.length])
      }
      Shortcut {
        sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab", "Ctrl+PgUp"]
        enabled: root.popupOpen
        onActivated: root.showPage(root.pageKeys[(root.pageKeys.indexOf(root.currentKey) + root.pageKeys.length - 1) % root.pageKeys.length])
      }
      Repeater {
        model: root.pageKeys
        delegate: Item {
          required property string modelData
          required property int index
          Shortcut {
            sequence: "Alt+" + (index + 1)
            enabled: root.popupOpen
            onActivated: root.showPage(modelData)
          }
        }
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
          options: root.pageKeys.map(function(key) {
            return key === "live" ? "Live 00" : (key === "lmstudio" ? "LM Studio \u25CF" : root.pageTitles[key])
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
          options: root.pageKeys.map(function(key) {
            return { value: key, label: root.tabLabel(key) }
          })
          onChanged: function(value) { root.showPage(value) }
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
          visible: !root.activePanelShown
          spacing: Style.space(8)
          padding: Style.space(24)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.currentKey === "live" && livePage.pinned ? "herdr is pinned to the desktop" : "Loading…"
            color: Color.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.currentKey === "live" && livePage.pinned
            text: "Unpin"
            onClicked: livePage.togglePin()
          }
        }
      }
    }
  }
}
