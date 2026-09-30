import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../.."
import "Model.js" as Model

Panel {
  id: root
  moduleName: "design-nexus.lmstudio"
  manageIpc: false

  property var lmstudio: null
  property var anchorItem: null
  property var hostWidget: null
  property var bar: null

  property string focusSection: "header"
  property int modelIndex: 0
  property int actionIndex: 0
  property bool cursorActive: false
  property bool copyMenuOpen: false
  property int copyIndex: 0

  function foreground() { return (bar && bar.foreground) ? bar.foreground : Color.foreground }
  function urgent() { return (bar && bar.urgent) ? bar.urgent : Color.urgent }
  function dim() { return Qt.darker(foreground(), 1.55) }
  function fontFamily() { return (bar && bar.fontFamily) ? bar.fontFamily : Style.font.family }
  readonly property bool showModels: lmstudio.serverRunning && lmstudio.models.length > 0
  readonly property int actionCount: (lmstudio.installed && !lmstudio.serverRunning ? 1 : 0)
    + (lmstudio.serverRunning ? 1 : 0)
    + (lmstudio.installed ? 1 : 0)
    + (lmstudio.serverRunning && lmstudio.modelCount > 0 ? 1 : 0)
    + (lmstudio.installed && lmstudio.serverRunning ? 1 : 0)
  readonly property var stats: Model.aggregateStats(lmstudio.models)
  function iconColor() { return lmstudio.active ? foreground() : dim() }
  readonly property string toggleHint: lmstudio.active ? "Stop server" : (lmstudio.serverError ? "Fix error first" : "Start server")
  function barForeground() { return (bar && bar.foreground) ? bar.foreground : Color.foreground }

  function selectedModel() {
    if (lmstudio.models.length === 0) return null
    return lmstudio.models[Math.max(0, Math.min(modelIndex, lmstudio.models.length - 1))]
  }

  function modelCopyOptions(model) {
    var options = []
    if (model.displayName) options.push({ kind: "name", label: model.displayName })
    if (model.identifier) options.push({ kind: "id", label: model.identifier })
    return options
  }

  function clampModelIndex() {
    modelIndex = Math.max(0, Math.min(modelIndex, lmstudio.models.length - 1))
  }

  function clampCopyIndex(model) {
    var options = modelCopyOptions(model)
    copyIndex = Math.max(0, Math.min(copyIndex, options.length - 1))
  }

  function openCopyMenu(model) {
    if (!model) return
    clampCopyIndex(model)
    copyMenu.modelData = model
    copyMenu.open()
  }

  function moveModelCursor(delta) {
    if (lmstudio.models.length === 0) return
    cursorActive = true
    modelIndex = Math.max(0, Math.min(lmstudio.models.length - 1, modelIndex + delta))
    scrollModelCursorIntoView()
  }

  function activateModelCursor() {
    var model = selectedModel()
    if (model) openCopyMenu(model)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollModelCursorIntoView() {
    if (modelColumn && modelIndex >= 0 && modelIndex < modelColumn.children.length) {
      scrollItemIntoView(modelColumn.children[modelIndex])
    }
  }

  function setModelCursor(index) {
    cursorActive = true
    focusSection = "models"
    modelIndex = index
    scrollModelCursorIntoView()
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  // Index (among visible action targets) of each action. Mirrors the per-item
  // `slot` bindings on the action rows / footer buttons.
  function actionStartSlot() { return 0 }
  function actionLoadSlot() { return lmstudio.installed && !lmstudio.serverRunning ? 1 : 0 }
  function actionOpenSlot() { return 1 }
  function actionUnloadSlot() { return (lmstudio.installed && !lmstudio.serverRunning ? 1 : 0) + (lmstudio.serverRunning ? 1 : 0) + (lmstudio.installed ? 1 : 0) }
  function actionQuitSlot() { return actionCount - 1 }

  function clampActionIndex() {
    if (actionCount === 0) {
      actionIndex = 0
      if (focusSection === "actions") {
        if (showModels) setModelCursor(0)
        else setHeaderCursor()
      }
    } else {
      actionIndex = Math.max(0, Math.min(actionCount - 1, actionIndex))
    }
  }

  function moveActionCursor(delta) {
    if (actionCount === 0) return
    cursorActive = true
    actionIndex = Math.max(0, Math.min(actionCount - 1, actionIndex + delta))
    scrollActionCursorIntoView()
  }

  function setActionCursor(index) {
    cursorActive = true
    focusSection = "actions"
    actionIndex = index
    scrollActionCursorIntoView()
  }

  function activateActionCursor() {
    if (actionCount === 0) return
    if (actionIndex === actionStartSlot() && lmstudio.installed && !lmstudio.serverRunning) {
      lmstudio.startServer()
      return
    }
    if (actionIndex === actionLoadSlot() && lmstudio.serverRunning) {
      if (loadDropdown) loadDropdown.toggle()
      return
    }
    if (actionIndex === actionOpenSlot() && lmstudio.installed) lmstudio.openLMStudio()
    else if (actionIndex === actionUnloadSlot() && lmstudio.serverRunning && lmstudio.modelCount > 0) lmstudio.unloadAllModels()
    else if (actionIndex === actionQuitSlot() && lmstudio.installed && lmstudio.serverRunning) lmstudio.quitLMStudio()
  }

  function scrollActionCursorIntoView() {
    var containers = [actionColumn]
    if (footerRow) containers.push(footerRow)
    for (var c = 0; c < containers.length; c++) {
      var cont = containers[c]
      if (!cont) continue
      for (var i = 0; i < cont.children.length; i++) {
        var child = cont.children[i]
        if (child.visible && child.slot === actionIndex) {
          scrollItemIntoView(child)
          return
        }
      }
    }
  }

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

  function formatMemPair(used, total) {
    if (total > 0) return Model.formatBytes(used) + " / " + Model.formatBytes(total)
    if (used > 0) return Model.formatBytes(used)
    return "—"
  }

  function formatProcMem(rss) {
    return rss > 0 ? Model.formatBytes(rss) : "—"
  }

  // Fraction (0..1) for usage bars; -1 means "no bar".
  function pctFraction(v) {
    var n = parseInt(String(v), 10)
    if (!isFinite(n) || n < 0) return -1
    return Math.min(1.0, n / 100)
  }

  function memFraction(used, total) {
    if (total > 0) return Math.min(1.0, Math.max(0.0, used / total))
    return -1
  }

  // On-disk models with an "already loaded" marker in the description so the
  // dropdown doubles as a swap-in list.
  readonly property var loadOptions: lmstudio.availableModels.map(function(o) {
    var loaded = lmstudio.models.some(function(m) { return m.identifier === o.value })
    return {
      value: o.value,
      label: o.label,
      description: (loaded ? "Loaded • " : "") + String(o.description || "")
    }
  })

  EmbeddedPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.copyMenuOpen || loadDropdown.popupOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) {
          if (root.focusSection === "header") {
            if (dy > 0) {
              if (root.showModels) root.setModelCursor(0)
              else if (root.actionCount > 0) root.setActionCursor(0)
            }
          } else if (root.focusSection === "models") {
            if (dy < 0) {
              if (modelIndex <= 0) root.setHeaderCursor()
              else root.moveModelCursor(-1)
            } else {
              if (modelIndex >= root.modelCount - 1) {
                if (root.actionCount > 0) root.setActionCursor(0)
              } else {
                root.moveModelCursor(1)
              }
            }
          } else if (root.focusSection === "actions") {
            if (dy < 0) {
              if (actionIndex <= 0) {
                if (root.showModels) root.setModelCursor(root.modelCount - 1)
                else root.setHeaderCursor()
              } else {
                root.moveActionCursor(-1)
              }
            }
            // No wrap below the last action; stay put at the bottom.
          }
        }
      }
      onActivateRequested: if (root.cursorActive) {
        if (root.focusSection === "header") lmstudio.toggleServer()
        else if (root.focusSection === "actions") root.activateActionCursor()
        else if (root.focusSection === "models") root.activateModelCursor()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") lmstudio.toggleServer()
        else if (t === "r" || t === "R") lmstudio.refresh()
        else if (t === "o" || t === "O") lmstudio.openLMStudio()
        else if (t === "q" || t === "Q") lmstudio.quitLMStudio()
        else if (t === "u" || t === "U") {
          var m = selectedModel()
          if (m) lmstudio.unloadModel(m.identifier)
        }
        else if (t === "c" || t === "C") {
          var m = selectedModel()
          if (m) root.openCopyMenu(m)
        }
        else if (t === "i" || t === "I") {
          var m = selectedModel()
          if (m) lmstudio.copyModelId(m)
        }
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
          spacing: HubStyle.gap

          // ── Hero: Server Status ─────────────────────────────────────
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() { root.setHeaderCursor() }

            HubHero {
              id: hero
              width: parent.width
              title: "LM Studio"
              detail: lmstudio.serverRunning ? "Running" : (lmstudio.active ? "Starting" : "Stopped")
              detailActive: lmstudio.serverRunning
              meta: lmstudio.active
                ? (lmstudio.serverRunning
                  ? "Port " + lmstudio.serverPort + " • " + lmstudio.modelCount + " model" + (lmstudio.modelCount !== 1 ? "s" : "") + " loaded"
                  : "Starting…")
                : "Server stopped"
              metaOpacity: lmstudio.active && !lmstudio.serverRunning ? 0.5 : 1.0
              foreground: root.foreground()
              fontFamily: root.fontFamily()
              iconOpacity: lmstudio.installed ? (lmstudio.active ? 1.0 : 0.5) : 0.3
              iconComponent: Component {
                LMStudioIcon {
                  iconSize: HubStyle.iconSize
                  color: root.iconColor()
                  badgeColor: root.urgent()
                  running: lmstudio.active
                  modelCount: lmstudio.modelCount
                  warning: lmstudio.serverError !== "" || lmstudio.lastError !== ""
                  crossed: lmstudio.installed && !lmstudio.active
                }
              }
              trailingControl: Component {
                Row {
                  id: heroControls
                  spacing: Style.space(6)

                  Button {
                    id: refreshBtn
                    visible: lmstudio.installed
                    iconText: "󰦖"
                    iconSpinning: lmstudio.refreshing
                    iconSize: Style.font.iconSmall
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    tooltipText: "Refresh (R)"
                    width: Style.space(26)
                    height: Style.space(26)
                    horizontalPadding: 0
                    verticalPadding: 0
                    onClicked: lmstudio.refresh()
                  }

                  PanelActionButton {
                    id: copyUrlBtn
                    visible: lmstudio.serverRunning
                    iconText: "󰆏"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    tooltipText: "Copy LLM Server Base URL"
                    onClicked: lmstudio.copyServerBaseUrl()
                  }

                  ToggleSwitch {
                    id: powerSwitch
                    visible: lmstudio.installed
                    checked: lmstudio.active
                    busy: lmstudio.busy
                    hasCursor: header.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) header.focusHero() }
                    onToggled: lmstudio.toggleServer()

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

          // ── Error/Status Banner ─────────────────────────────────────
          Text {
            visible: lmstudio.actionStatus !== "" || lmstudio.lastError !== "" || lmstudio.serverError !== ""
            width: parent.width
            text: lmstudio.actionStatus !== "" ? lmstudio.actionStatus : (lmstudio.lastError !== "" ? lmstudio.lastError : lmstudio.serverError)
            color: (lmstudio.lastError !== "" || lmstudio.serverError !== "") && lmstudio.actionStatus === "" ? root.urgent() : root.dim()
            font.family: root.fontFamily()
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            padding: Style.space(8)
          }

          // ── Empty State ─────────────────────────────────────────────
          Rectangle {
            visible: !lmstudio.serverRunning
            width: parent.width
            height: Style.space(56)
            color: "transparent"

            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                text: lmstudio.installed ? "Server stopped — start it below" : "LM Studio CLI not found"
                color: root.dim()
                font.family: root.fontFamily()
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                visible: !lmstudio.installed
                text: "Install LM Studio or set custom path in plugin settings"
                color: root.dim()
                font.family: root.fontFamily()
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          // ── Resource Usage Section ──────────────────────────────────
          HubSection {
            visible: lmstudio.serverRunning && lmstudio.modelCount > 0
            width: parent.width
            title: "Resource usage"
            foreground: root.foreground()
            fontFamily: root.fontFamily()

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              ResourceCell {
                iconText: "󰓅"
                label: "GPU"
                value: root.formatPct(lmstudio.resources.gpuUtil)
                fraction: root.pctFraction(lmstudio.resources.gpuUtil)
              }
              ResourceCell {
                iconText: "󰍛"
                label: "VRAM"
                value: root.formatMemPair(lmstudio.resources.vramUsed, lmstudio.resources.vramTotal)
                fraction: root.memFraction(lmstudio.resources.vramUsed, lmstudio.resources.vramTotal)
              }

              ResourceCell {
                iconText: "󰻠"
                label: "CPU"
                value: root.formatPct(lmstudio.resources.cpuPct)
                fraction: root.pctFraction(lmstudio.resources.cpuPct)
              }
              ResourceCell {
                iconText: "󰘚"
                label: "RAM"
                value: root.formatMemPair(lmstudio.resources.ramUsed, lmstudio.resources.ramTotal)
                fraction: root.memFraction(lmstudio.resources.ramUsed, lmstudio.resources.ramTotal)
              }

              ResourceCell {
                iconText: "󰻠"
                label: "LM Studio CPU"
                value: root.formatPct(lmstudio.resources.procCpuPct)
                fraction: root.pctFraction(lmstudio.resources.procCpuPct)
              }
              ResourceCell {
                iconText: "󰘚"
                label: "LM Studio RAM"
                value: root.formatProcMem(lmstudio.resources.procRss)
                fraction: root.memFraction(lmstudio.resources.procRss, lmstudio.resources.ramTotal)
              }

              ResourceCell {
                iconText: "󰹉"
                label: "Context"
                value: root.formatContext(root.stats.maxContextLength)
              }
              ResourceCell {
                iconText: "󰆦"
                label: "Models"
                value: lmstudio.modelCount
              }
            }
          }

          // ── Loaded Models Section ───────────────────────────────────
          HubSection {
            visible: root.showModels
            width: parent.width
            title: "Loaded models (" + lmstudio.modelCount + ")"
            foreground: root.foreground()
            fontFamily: root.fontFamily()

            Column {
              id: modelColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: lmstudio.models
                delegate: ModelCard {
                  width: parent.width
                  barForeground: root.barForeground()
                  barDim: root.dim()
                  barUrgent: root.urgent()
                  fontFamily: root.fontFamily()
                  hasCursor: root.cursorActive && root.focusSection === "models" && root.modelIndex === index
                  onUnload: lmstudio.unloadModel(modelData.identifier)
                  onCopy: root.openCopyMenu(modelData)
                }
              }
            }
          }

          // ── Server Actions ──────────────────────────────────────────
          Column {
            id: actionColumn
            visible: root.actionCount > 0
            width: parent.width
            spacing: Style.space(8)

            ActionRow {
              slot: root.actionStartSlot()
              iconText: "󰐥"
              text: "Start Server"
              visible: lmstudio.installed && !lmstudio.serverRunning
              onClicked: lmstudio.startServer()
            }

            SearchableDropdown {
              id: loadDropdown
              property int slot: root.actionLoadSlot()
              visible: lmstudio.serverRunning
              width: parent.width
              showLabel: false
              triggerLabel: "Load Model"
              placeholderText: "Search models…"
              options: root.loadOptions
              foreground: root.foreground()
              fontFamily: root.fontFamily()
              hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
              onHovered: function(on) { if (on) root.setActionCursor(slot) }
              onChanged: function(v) {
                loadDropdown.value = ""
                lmstudio.loadModel(v)
              }
              onPopupOpenChanged: if (!loadDropdown.popupOpen && root.opened) {
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
            }

            RowLayout {
              id: footerRow
              width: parent.width
              spacing: Style.space(6)

              FooterButton {
                slot: root.actionOpenSlot()
                iconText: "󰏋"
                text: "Open"
                visible: lmstudio.installed
                tooltipText: "Open LM Studio (O)"
                onClicked: lmstudio.openLMStudio()
              }

              FooterButton {
                slot: root.actionUnloadSlot()
                iconText: "󰇪"
                text: "Unload All"
                visible: lmstudio.serverRunning && lmstudio.modelCount > 0
                tooltipText: "Unload all loaded models (U)"
                onClicked: lmstudio.unloadAllModels()
              }

              FooterButton {
                slot: root.actionQuitSlot()
                iconText: "󰤆"
                text: "Quit"
                visible: lmstudio.installed && lmstudio.serverRunning
                tooltipText: "Quit LM Studio (Q)"
                urgent: true
                onClicked: lmstudio.quitLMStudio()
              }
            }
          }

          // ── Help Text ───────────────────────────────────────────────
          Text {
            visible: lmstudio.serverRunning && lmstudio.modelCount === 0
            width: parent.width
            text: "No models loaded. Use 'lms load <model>' in terminal or load via LM Studio UI."
            color: root.dim()
            font.family: root.fontFamily()
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            padding: Style.space(8)
          }
        }
      }

      // ── Copy Menu Popup ────────────────────────────────────────────
      // Must live inside the KeyboardPanel surface (via keyCatcher) so
      // the popup overlays the panel card window. At root level it would
      // parent to the bar-widget loader item and open off-screen.
      Popup {
        id: copyMenu
        property var modelData: null
        x: parent.width - width - Style.space(12)
        y: Style.space(60)
        width: Style.space(280)
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        function handleKey(event) {
          var model = copyMenu.modelData
          var options = model ? root.modelCopyOptions(model) : []
          if (event.key === Qt.Key_Escape) {
            close()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Down || event.text === "j") {
            if (options.length > 0) root.copyIndex = Math.max(0, Math.min(options.length - 1, root.copyIndex + 1))
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Up || event.text === "k") {
            if (options.length > 0) root.copyIndex = Math.max(0, Math.min(options.length - 1, root.copyIndex - 1))
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (options.length > 0) {
              var opt = options[root.copyIndex]
              if (opt.kind === "name") lmstudio.copyModelName(model)
              else if (opt.kind === "id") lmstudio.copyModelId(model)
            }
            close()
            event.accepted = true
          }
        }

        onOpenedChanged: {
          root.copyMenuOpen = opened
          if (opened) {
            root.clampCopyIndex(copyMenu.modelData)
            Qt.callLater(function() { copyMenuContent.forceActiveFocus() })
          } else if (root.opened) {
            Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          }
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
            model: copyMenu.modelData ? root.modelCopyOptions(copyMenu.modelData) : []
            delegate: CopyChoice {
              required property var modelData
              required property int index
              width: parent.width
              label: String(modelData.label || "")
              kind: String(modelData.kind || "")
              selected: root.copyIndex === index
              onHovered: root.copyIndex = index
              onChosen: function(kind) {
                var m = copyMenu.modelData
                if (kind === "name") lmstudio.copyModelName(m)
                else if (kind === "id") lmstudio.copyModelId(m)
                copyMenu.close()
              }
            }
          }
        }
      }
    }
  }

  // ── ModelCard Component ───────────────────────────────────────────
  component ModelCard: CursorSurface {
    id: modelCard
    required property var modelData
    required property int index
    property color barForeground: Color.foreground
    property color barDim: Qt.darker(Color.foreground, 1.55)
    property color barUrgent: Color.urgent
    property string fontFamily: Style.font.family

    signal unload()
    signal copy()

    width: parent.width
    height: Style.space(72)
    foreground: barForeground
    visible: Boolean(modelData && modelData.displayName)
    radius: Style.cornerRadius
    bordered: index !== 0

    implicitHeight: Math.max(content.implicitHeight, actions.implicitHeight) + Style.spacing.rowPaddingX

    Row {
      id: content
      z: 1
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(10)

      // Model icon (publisher logo, LM Studio-style; initial tile fallback)
      Rectangle {
        width: Style.space(40)
        height: Style.space(40)
        radius: Style.cornerRadius
        color: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.1)

        PublisherLogo {
          anchors.fill: parent
          publisher: modelData ? modelData.publisher : ""
          label: modelData ? modelData.displayName : ""
          foreground: barForeground
          fontFamily: modelCard.fontFamily
          loadRemote: root.opened
        }
      }

      // Model info
      Column {
        Layout.fillWidth: true
        spacing: 2

        Text {
          width: parent.width
          text: modelData ? modelData.displayName : ""
          color: barForeground
          font.family: fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Row {
          spacing: Style.space(8)

          Text {
            text: modelData ? Model.formatBytes(Model.totalMemoryBytes(modelData)) : ""
            color: barDim
            font.family: fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "•"
            color: barDim
            font.pixelSize: Style.font.caption
          }

          Text {
            text: modelData ? (modelData.quantization || modelData.architecture || "") : ""
            color: barDim
            font.family: fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: modelData && modelData.paramsString ? (" • " + modelData.paramsString) : ""
            color: barDim
            font.family: fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Status badge
      Rectangle {
        width: Style.space(64)
        height: Style.space(22)
        radius: height / 2
        color: modelData && modelData.status === "busy"
            ? Qt.rgba(barUrgent.r, barUrgent.g, barUrgent.b, 0.2)
            : Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.1)

        Text {
          anchors.centerIn: parent
          text: modelData ? Model.humanStatus(modelData.status) : ""
          color: modelData && modelData.status === "busy" ? barUrgent : barDim
          font.family: fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      // Action buttons
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
      onEntered: root.setModelCursor(index)
      onClicked: root.setModelCursor(index)
    }
  }

  // ── CopyChoice Component ──────────────────────────────────────────
  component CopyChoice: CursorSurface {
    id: copyChoice
    signal chosen(string kind)
    signal hovered()
    property string label: ""
    property string kind: ""
    property bool selected: false

    visible: enabled
    foreground: root.foreground()
    hasCursor: selected
    implicitHeight: Style.space(48)
    radius: 0

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: copyChoice.hovered()
      onClicked: copyChoice.chosen(copyChoice.kind)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        text: copyChoice.label
        color: root.foreground()
        font.family: root.fontFamily()
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        text: copyChoice.kind === "name" ? "name" : "id"
        color: root.dim()
        font.family: root.fontFamily()
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  // ── ActionRow Component ───────────────────────────────────────────
  component ActionRow: Button {
    id: actionRow
    required property int slot
    width: parent.width
    leftAlign: true
    fontSize: Style.font.body
    foreground: root.foreground()
    fontFamily: root.fontFamily()
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
    onHovered: function(on) { if (on) root.setActionCursor(slot) }
  }

  // ── FooterButton Component ────────────────────────────────────────
  component FooterButton: Button {
    id: footerButton
    required property int slot
    property bool urgent: false
    Layout.fillWidth: true
    leftAlign: false
    fontSize: Style.font.bodySmall
    iconSize: Style.font.iconSmall
    foreground: urgent ? root.urgent() : root.foreground()
    fontFamily: root.fontFamily()
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
    onHovered: function(on) { if (on) root.setActionCursor(slot) }
  }

  // ── ResourceCell Component ────────────────────────────────────────
  component ResourceCell: Column {
    id: cell
    required property string iconText
    required property string label
    required property string value
    property real fraction: -1
    Layout.fillWidth: true
    spacing: Style.spacing.labelGap

    readonly property color cellForeground: root.foreground()
    readonly property color cellDim: Qt.darker(cellForeground, 1.4)

    Row {
      width: parent.width
      spacing: Style.space(6)

      Text {
        id: cellIcon
        text: cell.iconText
        color: cell.cellDim
        font.family: root.fontFamily()
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: Math.max(0, parent.width - cellIcon.width - cellValue.width - parent.spacing)
        text: cell.label
        color: cell.cellDim
        font.family: root.fontFamily()
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: cellValue
        text: cell.value
        color: cell.cellForeground
        font.family: root.fontFamily()
        font.pixelSize: Style.font.bodySmall
      }
    }

    Item {
      visible: cell.fraction >= 0
      width: parent.width
      height: Style.space(4)

      Rectangle {
        id: barTrack
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(cell.cellForeground.r, cell.cellForeground.g, cell.cellForeground.b, 0.12)
      }

      Rectangle {
        id: barFill
        anchors.left: barTrack.left
        anchors.verticalCenter: barTrack.verticalCenter
        height: barTrack.height
        radius: barTrack.radius
        width: Math.max(barTrack.height, barTrack.width * Math.min(1.0, Math.max(0.0, cell.fraction)))
        color: cell.cellForeground

        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      }
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────
  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    lmstudio.refresh()
    if (lmstudio.serverRunning) {
      lmstudio.refreshAvailableModels()
    }
    lmstudio.refreshResources()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onModelIndexChanged: scrollModelCursorIntoView()
  onActionCountChanged: clampActionIndex()

  // Poll system resources (~btop default cadence) while the panel is open.
  Timer {
    id: resourceTimer
    interval: 2000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: lmstudio.refreshResources()
  }
}
