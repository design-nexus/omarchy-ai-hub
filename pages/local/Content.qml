import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../.."
import "Model.js" as Model

// The Local tab: system resource use, then one ServerSection per enabled
// server (LM Studio above Ollama). Keys move one cursor through all of them;
// s, r, o, q, u, c and i act on the section the cursor is in.
Panel {
  id: root
  moduleName: "design-nexus.ai-hub.local"
  manageIpc: false

  property var lmstudio: null
  property var ollama: null
  property bool showLmStudio: true
  property bool showOllama: true
  property var anchorItem: null
  property var hostWidget: null
  property var bar: null

  // The section holding the cursor, or null before any key or hover.
  property var activeSection: null
  property var copyTarget: null
  property bool copyMenuOpen: false
  property int copyIndex: 0

  property var resources: ({})
  property var _prevResources: null

  function foreground() { return (bar && bar.foreground) ? bar.foreground : Color.foreground }
  function urgent() { return (bar && bar.urgent) ? bar.urgent : Color.urgent }
  function dim() { return Qt.darker(foreground(), 1.55) }
  function fontFamily() { return (bar && bar.fontFamily) ? bar.fontFamily : Style.font.family }

  readonly property var sections: {
    var list = []
    if (showLmStudio) list.push(lmSection)
    if (showOllama) list.push(ollamaSection)
    return list
  }
  readonly property bool anyRunning: (showLmStudio && lmstudio.serverRunning) || (showOllama && ollama.serverRunning)

  function takeCursor(section) {
    for (var i = 0; i < sections.length; i++) if (sections[i] !== section) sections[i].clearCursor()
    activeSection = section
  }

  function moveCursor(dy) {
    if (sections.length === 0) return
    var current = activeSection && activeSection.cursorActive ? activeSection : null
    if (!current) {
      (dy < 0 ? sections[sections.length - 1] : sections[0]).enter(dy < 0)
      return
    }
    if (current.move(dy)) return
    var i = sections.indexOf(current) + (dy < 0 ? -1 : 1)
    if (i >= 0 && i < sections.length) sections[i].enter(dy < 0)
  }

  function cursorSection() {
    if (activeSection && activeSection.cursorActive && sections.indexOf(activeSection) !== -1) return activeSection
    return sections.length > 0 ? sections[0] : null
  }

  function modelCopyOptions(model) {
    var options = []
    if (model && model.displayName) options.push({ kind: "name", label: model.displayName })
    if (model && model.identifier && model.identifier !== model.displayName) options.push({ kind: "id", label: model.identifier })
    return options
  }

  function openCopyMenu(section, model) {
    if (!model) return
    copyTarget = { svc: section.svc, model: model }
    copyIndex = 0
    copyMenu.open()
  }

  function copyChosen(kind) {
    if (!copyTarget) return
    if (kind === "id") copyTarget.svc.copyModelId(copyTarget.model)
    else copyTarget.svc.copyModelName(copyTarget.model)
  }

  function scrollItemIntoView(item) {
    if (!item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function refreshAll() {
    if (showLmStudio) { lmstudio.refresh(); lmstudio.refreshAvailableModels() }
    if (showOllama) { ollama.refresh(); ollama.refreshAvailableModels() }
  }

  function formatPct(v) {
    var n = parseInt(String(v), 10)
    return isFinite(n) && n >= 0 ? n + "%" : "—"
  }

  function pctFraction(v) {
    var n = parseInt(String(v), 10)
    return isFinite(n) && n >= 0 ? Math.min(1.0, n / 100) : -1
  }

  function formatMemPair(used, total) {
    if (total > 0) return Model.formatBytes(used) + " / " + Model.formatBytes(total)
    if (used > 0) return Model.formatBytes(used)
    return "—"
  }

  function memFraction(used, total) {
    return total > 0 ? Math.min(1.0, Math.max(0.0, used / total)) : -1
  }

  EmbeddedPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.copyMenuOpen || lmSection.dropdownOpen || ollamaSection.dropdownOpen
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: {
        var s = root.activeSection
        if (s && s.cursorActive) s.activate()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var s = root.cursorSection()
        if (s) s.textKey(t)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: HubStyle.gap * 2

          // ── System ──────────────────────────────────────────────────
          HubSection {
            visible: root.anyRunning
            width: parent.width
            title: "System"
            foreground: root.foreground()
            fontFamily: root.fontFamily()

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              ResourceCell {
                foreground: root.foreground()
                fontFamily: root.fontFamily()
                iconText: "󰓅"
                label: "GPU"
                value: root.formatPct(root.resources.gpuUtil)
                fraction: root.pctFraction(root.resources.gpuUtil)
              }
              ResourceCell {
                foreground: root.foreground()
                fontFamily: root.fontFamily()
                iconText: "󰍛"
                label: "VRAM"
                value: root.formatMemPair(root.resources.vramUsed, root.resources.vramTotal)
                fraction: root.memFraction(root.resources.vramUsed, root.resources.vramTotal)
              }
              ResourceCell {
                foreground: root.foreground()
                fontFamily: root.fontFamily()
                iconText: "󰻠"
                label: "CPU"
                value: root.formatPct(root.resources.cpuPct)
                fraction: root.pctFraction(root.resources.cpuPct)
              }
              ResourceCell {
                foreground: root.foreground()
                fontFamily: root.fontFamily()
                iconText: "󰘚"
                label: "RAM"
                value: root.formatMemPair(root.resources.ramUsed, root.resources.ramTotal)
                fraction: root.memFraction(root.resources.ramUsed, root.resources.ramTotal)
              }
            }
          }

          ServerSection {
            id: lmSection
            visible: root.showLmStudio
            svc: root.lmstudio
            resources: root.resources
            opened: root.opened
            keyCatcher: keyCatcher
            foreground: root.foreground()
            urgentColor: root.urgent()
            fontFamily: root.fontFamily()
            onCursorTaken: root.takeCursor(lmSection)
            onCopyRequested: function(model) { root.openCopyMenu(lmSection, model) }
            onScrollRequested: function(item) { root.scrollItemIntoView(item) }
          }

          // A hairline between the two servers when both are shown.
          Rectangle {
            visible: root.showLmStudio && root.showOllama
            width: parent.width
            height: 1
            color: HubStyle.outline(root.foreground())
          }

          ServerSection {
            id: ollamaSection
            visible: root.showOllama
            svc: root.ollama
            resources: root.resources
            opened: root.opened
            keyCatcher: keyCatcher
            foreground: root.foreground()
            urgentColor: root.urgent()
            fontFamily: root.fontFamily()
            onCursorTaken: root.takeCursor(ollamaSection)
            onCopyRequested: function(model) { root.openCopyMenu(ollamaSection, model) }
            onScrollRequested: function(item) { root.scrollItemIntoView(item) }
          }

          Text {
            visible: !root.showLmStudio && !root.showOllama
            width: parent.width
            textFormat: Text.PlainText
            text: "LM Studio and Ollama are both hidden. Turn one on in the hub settings."
            color: root.dim()
            font.family: root.fontFamily()
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            padding: Style.space(16)
          }

          Text {
            visible: root.sections.length > 0
            width: parent.width
            textFormat: Text.PlainText
            text: "↑/↓ move · ↵ select · s server · r refresh · o open · u unload · c copy · esc"
            color: root.dim()
            font.family: root.fontFamily()
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

      // ── Copy menu ───────────────────────────────────────────────────
      // Inside the panel surface (via keyCatcher) so it overlays the card;
      // at root level it would open off-screen.
      Popup {
        id: copyMenu
        x: parent.width - width - Style.space(12)
        y: Style.space(60)
        width: Style.space(280)
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        readonly property var options: root.copyTarget ? root.modelCopyOptions(root.copyTarget.model) : []

        function handleKey(event) {
          if (event.key === Qt.Key_Escape) {
            close()
          } else if (event.key === Qt.Key_Down || event.text === "j") {
            root.copyIndex = Math.max(0, Math.min(options.length - 1, root.copyIndex + 1))
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            root.copyIndex = Math.max(0, root.copyIndex - 1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (options.length > 0) root.copyChosen(options[root.copyIndex].kind)
            close()
          } else {
            return
          }
          event.accepted = true
        }

        onOpenedChanged: {
          root.copyMenuOpen = opened
          if (opened) Qt.callLater(function() { copyMenuContent.forceActiveFocus() })
          else if (root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }

        background: BorderSurface {
          color: Color.background
          borderSpec: Border.flat(root.dim(), 1)
          radius: Style.cornerRadius
        }

        contentItem: Column {
          id: copyMenuContent
          width: parent.width
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { copyMenu.handleKey(event) }

          Repeater {
            model: copyMenu.options
            delegate: CursorSurface {
              id: choice
              required property var modelData
              required property int index
              width: parent.width
              foreground: root.foreground()
              hasCursor: root.copyIndex === index
              implicitHeight: Style.space(48)
              radius: 0

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.copyIndex = choice.index
                onClicked: { root.copyChosen(choice.modelData.kind); copyMenu.close() }
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: String(choice.modelData.label || "")
                  color: root.foreground()
                  font.family: root.fontFamily()
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: choice.modelData.kind === "name" ? "name" : "id"
                  color: root.dim()
                  font.family: root.fontFamily()
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  // ── Resources ───────────────────────────────────────────────────────
  // Sampled every 2 s (btop's default) while the tab is open.

  Process {
    id: resProcess
    command: ["bash", Qt.resolvedUrl("bin/local-resources").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector { id: resStdout; waitForEnd: true }
    onExited: {
      var parsed = Model.parseResources(resStdout.text, root._prevResources)
      root._prevResources = parsed.next
      if (parsed.gpuUtil >= 0 || parsed.ramTotal > 0) root.resources = parsed
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.opened && root.sections.length > 0
    triggeredOnStart: true
    onTriggered: if (!resProcess.running) resProcess.running = true
  }

  // Model lists change behind our back (Ollama unloads idle models), so
  // re-read them while the tab is on screen.
  Timer {
    interval: 10000
    repeat: true
    running: root.opened
    onTriggered: {
      if (root.showLmStudio) root.lmstudio.refresh()
      if (root.showOllama) root.ollama.refresh()
    }
  }

  onOpenedChanged: if (opened) {
    for (var i = 0; i < sections.length; i++) sections[i].clearCursor()
    activeSection = null
    panelFlick.contentY = 0
    refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
}
