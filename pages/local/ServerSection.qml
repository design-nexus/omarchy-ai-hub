import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../.."
import "Model.js" as Model

// One local model server (LM Studio or Ollama): its header and power switch,
// errors, the server's own CPU and memory, loaded models, and actions.
//
// Content.qml stacks one per enabled server and owns the key handling; it
// drives the cursor here through enter(), move(), activate() and textKey().
// A section reports hover with cursorTaken() so only one shows a cursor.
Column {
  id: root

  property var svc: null
  property var resources: ({})
  property bool opened: false
  property Item keyCatcher: null
  property color foreground: Color.foreground
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family

  property bool cursorActive: false
  property string focusSection: "header"
  property int modelIndex: 0
  property int actionIndex: 0

  readonly property bool dropdownOpen: loadDropdown.popupOpen

  signal copyRequested(var model)
  signal cursorTaken()
  signal scrollRequested(Item item)

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property var proc: resources && resources.procs ? (resources.procs[svc.kind] || null) : null
  readonly property bool showModels: svc.serverRunning && svc.models.length > 0
  readonly property var stats: Model.aggregateStats(svc.models)
  readonly property string toggleHint: svc.active ? "Stop server" : (svc.serverError ? "Fix error first" : "Start server")

  // Visible action targets in order: Start, Load, then the footer buttons.
  readonly property bool hasStart: svc.installed && !svc.serverRunning
  readonly property bool hasLoad: svc.serverRunning
  readonly property bool hasOpen: svc.canOpen
  readonly property bool hasUnload: svc.serverRunning && svc.modelCount > 0
  readonly property bool hasQuit: svc.canQuit
  readonly property int actionCount: (hasStart ? 1 : 0) + (hasLoad ? 1 : 0) + (hasOpen ? 1 : 0) + (hasUnload ? 1 : 0) + (hasQuit ? 1 : 0)
  readonly property int startSlot: 0
  readonly property int loadSlot: hasStart ? 1 : 0
  readonly property int openSlot: (hasStart ? 1 : 0) + (hasLoad ? 1 : 0)
  readonly property int unloadSlot: openSlot + (hasOpen ? 1 : 0)
  readonly property int quitSlot: unloadSlot + (hasUnload ? 1 : 0)

  width: parent ? parent.width : implicitWidth
  spacing: HubStyle.gap

  function selectedModel() {
    if (svc.models.length === 0) return null
    return svc.models[Math.max(0, Math.min(modelIndex, svc.models.length - 1))]
  }

  // ── Cursor ──────────────────────────────────────────────────────────

  function clearCursor() { cursorActive = false }

  function take() {
    if (!cursorActive) cursorTaken()
    cursorActive = true
  }

  function setHeaderCursor() {
    take()
    focusSection = "header"
    scrollRequested(header)
  }

  function setModelCursor(index) {
    take()
    focusSection = "models"
    modelIndex = Math.max(0, Math.min(index, svc.models.length - 1))
    if (modelIndex < modelColumn.children.length) scrollRequested(modelColumn.children[modelIndex])
  }

  function setActionCursor(index) {
    take()
    focusSection = "actions"
    actionIndex = Math.max(0, Math.min(index, actionCount - 1))
    var containers = [actionColumn, footerRow]
    for (var c = 0; c < containers.length; c++) {
      for (var i = 0; i < containers[c].children.length; i++) {
        var child = containers[c].children[i]
        if (child.visible && child.slot === actionIndex) {
          scrollRequested(child)
          return
        }
      }
    }
  }

  // Land on the first target, or the last when arriving from below.
  function enter(fromBottom) {
    if (!fromBottom) setHeaderCursor()
    else if (actionCount > 0) setActionCursor(actionCount - 1)
    else if (showModels) setModelCursor(svc.models.length - 1)
    else setHeaderCursor()
  }

  // Move within the section; false at its top or bottom edge.
  function move(dy) {
    if (focusSection === "header") {
      if (dy < 0) return false
      if (showModels) setModelCursor(0)
      else if (actionCount > 0) setActionCursor(0)
      else return false
      return true
    }
    if (focusSection === "models") {
      if (dy < 0) {
        if (modelIndex <= 0) setHeaderCursor()
        else setModelCursor(modelIndex - 1)
      } else if (modelIndex >= svc.models.length - 1) {
        if (actionCount === 0) return false
        setActionCursor(0)
      } else {
        setModelCursor(modelIndex + 1)
      }
      return true
    }
    if (dy < 0) {
      if (actionIndex > 0) setActionCursor(actionIndex - 1)
      else if (showModels) setModelCursor(svc.models.length - 1)
      else setHeaderCursor()
      return true
    }
    if (actionIndex >= actionCount - 1) return false
    setActionCursor(actionIndex + 1)
    return true
  }

  function activate() {
    if (focusSection === "header") svc.toggleServer()
    else if (focusSection === "models") { var m = selectedModel(); if (m) copyRequested(m) }
    else if (actionIndex === startSlot && hasStart) svc.startServer()
    else if (actionIndex === loadSlot && hasLoad) loadDropdown.toggle()
    else if (actionIndex === openSlot && hasOpen) svc.openApp(selectedModel())
    else if (actionIndex === unloadSlot && hasUnload) svc.unloadAllModels()
    else if (actionIndex === quitSlot && hasQuit) svc.quitApp()
  }

  function textKey(t) {
    var k = String(t || "").toLowerCase()
    var m = selectedModel()
    if (k === "s") svc.toggleServer()
    else if (k === "r") { svc.refresh(); svc.refreshAvailableModels() }
    else if (k === "o") { if (svc.canOpen) svc.openApp(m) }
    else if (k === "q") { if (svc.canQuit) svc.quitApp() }
    else if (k === "u") { if (m) svc.unloadModel(m.identifier) }
    else if (k === "c") { if (m) copyRequested(m) }
    else if (k === "i") { if (m) svc.copyModelId(m) }
    else return false
    return true
  }

  onActionCountChanged: {
    if (focusSection !== "actions") return
    if (actionCount === 0) focusSection = showModels ? "models" : "header"
    else actionIndex = Math.max(0, Math.min(actionCount - 1, actionIndex))
  }

  // ── Formatting ──────────────────────────────────────────────────────

  function formatContext(n) {
    var value = parseInt(String(n || 0), 10)
    if (!isFinite(value) || value <= 0) return "—"
    if (value >= 1024) return (value / 1024).toFixed(value % 1024 === 0 ? 0 : 1) + "K"
    return String(value)
  }

  function formatPct(v) {
    var n = parseInt(String(v), 10)
    return isFinite(n) && n >= 0 ? n + "%" : "—"
  }

  function pctFraction(v) {
    var n = parseInt(String(v), 10)
    return isFinite(n) && n >= 0 ? Math.min(1.0, n / 100) : -1
  }

  // On-disk models, marked when already loaded, so the dropdown doubles as a
  // swap-in list.
  readonly property var loadOptions: svc.availableModels.map(function(o) {
    var loaded = svc.models.some(function(m) { return m.identifier === o.value })
    return { value: o.value, label: o.label, description: (loaded ? "Loaded • " : "") + String(o.description || "") }
  })

  // ── Header ──────────────────────────────────────────────────────────

  Item {
    id: header
    width: parent.width
    implicitHeight: hero.implicitHeight
    readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"

    HubHero {
      id: hero
      width: parent.width
      title: svc.name
      detail: svc.serverRunning ? "Running" : (svc.active ? "Starting" : "Stopped")
      detailActive: svc.serverRunning
      meta: svc.active
        ? (svc.serverRunning
          ? "Port " + svc.serverPort + " • " + svc.modelCount + " model" + (svc.modelCount !== 1 ? "s" : "") + " loaded"
          : "Starting…")
        : (svc.installed ? "Server stopped" : svc.notInstalledText)
      metaOpacity: svc.active && !svc.serverRunning ? 0.5 : 1.0
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconOpacity: svc.installed ? (svc.active ? 1.0 : 0.5) : 0.3
      iconComponent: svc.kind === "ollama" ? ollamaIcon : lmIcon
      trailingControl: Component {
        Row {
          spacing: Style.space(6)

          Button {
            visible: svc.installed
            iconText: "󰦖"
            iconSpinning: svc.refreshing
            iconSize: Style.font.iconSmall
            foreground: hero.foreground
            fontFamily: hero.fontFamily
            tooltipText: "Refresh (R)"
            width: Style.space(26)
            height: Style.space(26)
            horizontalPadding: 0
            verticalPadding: 0
            onClicked: { svc.refresh(); svc.refreshAvailableModels() }
          }

          PanelActionButton {
            visible: svc.serverRunning
            iconText: "󰆏"
            foreground: hero.foreground
            fontFamily: hero.fontFamily
            tooltipText: "Copy server base URL (" + svc.baseUrl + ")"
            onClicked: svc.copyServerBaseUrl()
          }

          ToggleSwitch {
            id: powerSwitch
            visible: svc.installed
            checked: svc.active
            busy: svc.busy
            hasCursor: header.ringVisible
            foreground: hero.foreground
            onHovered: function(on) { if (on) root.setHeaderCursor() }
            onToggled: svc.toggleServer()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleHint
              fontFamily: hero.fontFamily
            }
          }
        }
      }
    }
  }

  Component {
    id: lmIcon
    LMStudioIcon {
      iconSize: HubStyle.iconSize
      color: svc.active ? root.foreground : root.dim
      badgeColor: root.urgentColor
      running: svc.active
      modelCount: svc.modelCount
      warning: svc.serverError !== "" || svc.lastError !== ""
      crossed: svc.installed && !svc.active
    }
  }

  Component {
    id: ollamaIcon
    OllamaIcon {
      iconSize: HubStyle.iconSize
      color: svc.active ? root.foreground : root.dim
      badgeColor: root.urgentColor
      running: svc.active
      modelCount: svc.modelCount
      warning: svc.serverError !== "" || svc.lastError !== ""
      crossed: svc.installed && !svc.active
    }
  }

  // ── Error / status ──────────────────────────────────────────────────

  Text {
    visible: svc.actionStatus !== "" || svc.lastError !== "" || svc.serverError !== ""
    width: parent.width
    textFormat: Text.PlainText
    text: svc.actionStatus !== "" ? svc.actionStatus : (svc.lastError !== "" ? svc.lastError : svc.serverError)
    color: (svc.lastError !== "" || svc.serverError !== "") && svc.actionStatus === "" ? root.urgentColor : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
    padding: Style.space(8)
  }

  Text {
    visible: !svc.installed
    width: parent.width
    textFormat: Text.PlainText
    text: svc.notInstalledHint
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
    padding: Style.space(4)
  }

  // ── The server's own resource use ───────────────────────────────────

  HubSection {
    visible: svc.serverRunning && svc.modelCount > 0
    width: parent.width
    title: "Resource usage"
    foreground: root.foreground
    fontFamily: root.fontFamily

    GridLayout {
      width: parent.width
      columns: 2
      columnSpacing: Style.space(20)
      rowSpacing: Style.spacing.labelGap

      ResourceCell {
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconText: "󰻠"
        label: svc.name + " CPU"
        value: root.formatPct(root.proc ? root.proc.cpuPct : -1)
        fraction: root.pctFraction(root.proc ? root.proc.cpuPct : -1)
      }
      ResourceCell {
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconText: "󰘚"
        label: svc.name + " RAM"
        value: root.proc && root.proc.rss > 0 ? Model.formatBytes(root.proc.rss) : "—"
        fraction: root.proc && root.resources.ramTotal > 0 ? Math.min(1, root.proc.rss / root.resources.ramTotal) : -1
      }
      ResourceCell {
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconText: "󰹉"
        label: "Context"
        value: root.formatContext(root.stats.maxContextLength)
      }
      ResourceCell {
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconText: "󰍛"
        label: "Model memory"
        value: Model.formatBytes(root.stats.vramBytes + root.stats.ramBytes)
      }
    }
  }

  // ── Loaded models ───────────────────────────────────────────────────

  HubSection {
    visible: root.showModels
    width: parent.width
    title: "Loaded models (" + svc.modelCount + ")"
    foreground: root.foreground
    fontFamily: root.fontFamily

    Column {
      id: modelColumn
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: svc.models
        delegate: ModelCard {
          width: parent.width
          barForeground: root.foreground
          barDim: root.dim
          barUrgent: root.urgentColor
          fontFamily: root.fontFamily
          loadRemote: root.opened
          hasCursor: root.cursorActive && root.focusSection === "models" && root.modelIndex === index
          onUnload: svc.unloadModel(modelData.identifier)
          onCopy: root.copyRequested(modelData)
          onPointed: root.setModelCursor(index)
        }
      }
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Column {
    id: actionColumn
    visible: root.actionCount > 0
    width: parent.width
    spacing: Style.space(8)

    Button {
      readonly property int slot: root.startSlot
      visible: root.hasStart
      width: parent.width
      leftAlign: true
      fontSize: Style.font.body
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconText: "󰐥"
      text: "Start Server"
      hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
      onHovered: function(on) { if (on) root.setActionCursor(slot) }
      onClicked: svc.startServer()
    }

    SearchableDropdown {
      id: loadDropdown
      readonly property int slot: root.loadSlot
      visible: root.hasLoad
      width: parent.width
      showLabel: false
      triggerLabel: "Load Model"
      placeholderText: "Search models…"
      options: root.loadOptions
      foreground: root.foreground
      fontFamily: root.fontFamily
      hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
      onHovered: function(on) { if (on) root.setActionCursor(slot) }
      onChanged: function(v) {
        loadDropdown.value = ""
        svc.loadModel(v)
      }
      onPopupOpenChanged: if (!loadDropdown.popupOpen && root.opened && root.keyCatcher) {
        Qt.callLater(function() { root.keyCatcher.forceActiveFocus() })
      }
    }

    RowLayout {
      id: footerRow
      visible: root.hasOpen || root.hasUnload || root.hasQuit
      width: parent.width
      spacing: Style.space(6)

      FooterButton {
        slot: root.openSlot
        iconText: svc.kind === "ollama" ? "󰭹" : "󰏋"
        text: svc.openLabel
        visible: root.hasOpen
        tooltipText: svc.openTooltip
        onClicked: svc.openApp(root.selectedModel())
      }

      FooterButton {
        slot: root.unloadSlot
        iconText: "󰇪"
        text: "Unload All"
        visible: root.hasUnload
        tooltipText: "Unload all loaded models"
        onClicked: svc.unloadAllModels()
      }

      FooterButton {
        slot: root.quitSlot
        iconText: "󰤆"
        text: "Quit"
        visible: root.hasQuit
        tooltipText: "Quit " + svc.name + " (Q)"
        urgent: true
        onClicked: svc.quitApp()
      }
    }
  }

  Text {
    visible: svc.serverRunning && svc.modelCount === 0
    width: parent.width
    textFormat: Text.PlainText
    text: svc.noModelsHint
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
    padding: Style.space(8)
  }

  // ── Components ──────────────────────────────────────────────────────

  component FooterButton: Button {
    required property int slot
    property bool urgent: false
    Layout.fillWidth: true
    leftAlign: false
    fontSize: Style.font.bodySmall
    iconSize: Style.font.iconSmall
    foreground: urgent ? root.urgentColor : root.foreground
    fontFamily: root.fontFamily
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
    onHovered: function(on) { if (on) root.setActionCursor(slot) }
  }

  component ModelCard: CursorSurface {
    id: modelCard
    required property var modelData
    required property int index
    property color barForeground: Color.foreground
    property color barDim: Qt.darker(Color.foreground, 1.55)
    property color barUrgent: Color.urgent
    property string fontFamily: Style.font.family
    property bool loadRemote: true

    signal unload()
    signal copy()
    signal pointed()

    foreground: barForeground
    visible: Boolean(modelData && modelData.displayName)
    radius: Style.cornerRadius
    bordered: index !== 0
    implicitHeight: Math.max(content.implicitHeight, actions.implicitHeight) + Style.spacing.rowPaddingX

    RowLayout {
      id: content
      z: 1
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(10)

      Rectangle {
        Layout.preferredWidth: Style.space(40)
        Layout.preferredHeight: Style.space(40)
        radius: Style.cornerRadius
        color: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.1)

        PublisherLogo {
          anchors.fill: parent
          publisher: modelData ? modelData.publisher : ""
          label: modelData ? modelData.displayName : ""
          foreground: barForeground
          fontFamily: modelCard.fontFamily
          loadRemote: modelCard.loadRemote
        }
      }

      Column {
        Layout.fillWidth: true
        spacing: 2

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: modelData ? modelData.displayName : ""
          color: barForeground
          font.family: modelCard.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: {
            if (!modelData) return ""
            var parts = [Model.formatBytes(Model.totalMemoryBytes(modelData))]
            var kind = modelData.quantization || modelData.architecture || ""
            if (kind) parts.push(kind)
            if (modelData.paramsString) parts.push(modelData.paramsString)
            return parts.join(" • ")
          }
          color: barDim
          font.family: modelCard.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Rectangle {
        Layout.preferredWidth: Style.space(64)
        Layout.preferredHeight: Style.space(22)
        radius: height / 2
        color: modelData && modelData.status === "busy"
          ? Qt.rgba(barUrgent.r, barUrgent.g, barUrgent.b, 0.2)
          : Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.1)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: modelData ? Model.humanStatus(modelData.status) : ""
          color: modelData && modelData.status === "busy" ? barUrgent : barDim
          font.family: modelCard.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Column {
        id: actions
        spacing: 4

        PanelActionButton {
          iconText: "󰇪"
          tooltipText: "Unload model (U)"
          onClicked: modelCard.unload()
        }

        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy model name or id (C)"
          onClicked: modelCard.copy()
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: modelCard.pointed()
      onClicked: modelCard.pointed()
    }
  }
}
