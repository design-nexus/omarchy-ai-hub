import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../.."

BarWidget {
  id: root
  moduleName: "design-nexus.ai-usage"

  property bool popupOpen: false
  property bool settingsMode: false
  property var draftSettings: ({})
  property string settingsStatusText: ""
  property bool refreshFlash: false
  property double nowMs: Date.now()
  property string selectedProviderId: "codex"
  // Set only while opening the panel. A manual refresh must not move a tab
  // the user explicitly chose.
  property bool selectLastUsedOnRefresh: false
  readonly property bool refreshing: usageMain.refreshing

  // ---------------------------------------------------------------- Theme
  // Built-in bar icons use barForeground; foreground can be a dimmed text role.
  readonly property color foreground: (bar && bar.barForeground) ? bar.barForeground : ((bar && bar.foreground) ? bar.foreground : Color.foreground)
  readonly property color background: (Color.popups && Color.popups.background) ? Color.popups.background : Color.background
  readonly property color urgent: (bar && bar.urgent) ? bar.urgent : Color.urgent
  readonly property color accent: (bar && bar.accent) ? bar.accent : Color.accent
  readonly property color onAccent: background
  readonly property color warn: mix(urgent, foreground, 0.45)
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color card: alpha(foreground, 0.055)
  readonly property color cardHover: alpha(foreground, 0.085)
  readonly property color outline: alpha(foreground, 0.18)
  readonly property color track: alpha(foreground, 0.24)
  // Last 7 Days bars use one colour on every tab: Antigravity's (usage_scanner.py META).
  readonly property color weekBarColor: "#3b82f6"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Four sizes only: panel title, row text, secondary text, meta/chips.
  readonly property int fsTitle: Style.font.title
  readonly property int fsBody: Style.font.bodySmall
  readonly property int fsSmall: Style.font.caption
  readonly property int fsMeta: Style.font.caption - 1

  // ------------------------------------------------------------- Providers
  readonly property var provider: usageMain.providerFor(selectedProviderId)
  readonly property var installedProviders: usageMain.enabledProviders || []
  readonly property var allProviders: usageMain.allProviders || []
  readonly property url iconSource: Qt.resolvedUrl("assets/omarchy.png")
  readonly property int visibleSessionCount: provider ? Math.min((provider.recentSessions || []).length, sessionLimit) : 0
  readonly property int sessionLimit: Math.max(3, Math.min(10, Number(settings ? settings.recentSessionsLimit : 5) || 5))

  readonly property int activeSessionTotal: {
    var n = 0
    for (var i = 0; i < installedProviders.length; i++) n += activeCount(installedProviders[i])
    return n
  }
  readonly property int todayPromptTotal: {
    var n = 0
    for (var i = 0; i < installedProviders.length; i++) n += installedProviders[i].todayPrompts || 0
    return n
  }
  readonly property string badgeMode: normalizedSettings(settings).badgeMode
  readonly property string badgeText: {
    if (badgeMode === "active") return activeSessionTotal > 0 ? String(activeSessionTotal) : ""
    if (badgeMode === "prompts") return todayPromptTotal > 0 ? formatCount(todayPromptTotal) : ""
    return ""
  }

  function close() {
    popupOpen = false
    settingsMode = false
  }

  function triggerPress(button) {
    if (button === Qt.RightButton) {
      openSettings()
      return
    }
    if (button === Qt.MiddleButton) {
      triggerRefresh(true)
      return
    }
    if (popupOpen) {
      popupOpen = false
    } else {
      popupOpen = true
      triggerRefresh(false)
    }
  }

  function triggerRefresh(force) {
    refreshFlash = true
    refreshFlashTimer.restart()
    usageMain.refreshAll(force === true)
  }

  function getTerminalArgs(cmdArgs, workspacePath) {
    var termSetting = (root.settings && root.settings.terminalCommand) ? String(root.settings.terminalCommand).trim() : ""
    var ws = workspacePath || ""
    if (ws.indexOf("file://") === 0) ws = decodeURIComponent(ws.substring(7))

    var parts = termSetting.split(/\s+/).filter(function(p) { return p.length > 0 })
    if (parts.length === 0) parts = ["xdg-terminal-exec"]

    var bin = parts[0].split("/").pop()
    if (bin === "xdg-terminal-exec") {
      if (ws) parts.push("--dir=" + ws)
      parts.push("--")
    } else if (bin === "foot") {
      if (ws) parts.push("-D", ws)
    } else if (bin === "kitty") {
      if (ws) parts.push("-d", ws)
    } else if (bin === "ghostty") {
      if (ws) parts.push("--working-directory=" + ws)
      if (parts.indexOf("-e") === -1) parts.push("-e")
    } else if (bin === "alacritty") {
      if (ws) parts.push("--working-directory", ws)
      if (parts.indexOf("-e") === -1) parts.push("-e")
    } else if (parts.indexOf("-e") === -1 && parts.indexOf("--") === -1) {
      parts.push("-e")
    }
    return parts.concat(cmdArgs)
  }

  function launch(args) {
    try {
      Quickshell.execDetached(["uwsm-app", "--"].concat(args))
    } catch (e) {
      Quickshell.execDetached(args)
    }
  }

  function ensureSelection() {
    var list = usageMain.enabledProviders || []
    for (var i = 0; i < list.length; i++) {
      if (list[i].providerId === selectedProviderId) return
    }
    selectedProviderId = list.length ? list[0].providerId : ""
  }

  function selectProvider(id) {
    selectedProviderId = id
    selectLastUsedOnRefresh = false
    if (flick) flick.contentY = 0
  }

  function sessionActivityMs(session) {
    if (!session) return NaN
    var ms = Date.parse(session.updated_at || session.lastModified || "")
    return isFinite(ms) ? ms : NaN
  }

  function newestProviderSessionMs(provider) {
    var sessions = (provider.activeSessions || []).concat(provider.recentSessions || [])
    var best = NaN
    for (var i = 0; i < sessions.length; i++) {
      var ms = sessionActivityMs(sessions[i])
      if (isFinite(ms) && (!isFinite(best) || ms > best)) best = ms
    }
    return best
  }

  function selectLastUsedAgent() {
    var list = usageMain.enabledProviders || []
    var bestId = ""
    var bestMs = NaN
    for (var i = 0; i < list.length; i++) {
      var ms = newestProviderSessionMs(list[i])
      if (isFinite(ms) && (!isFinite(bestMs) || ms > bestMs)) {
        bestMs = ms
        bestId = list[i].providerId
      }
    }
    if (bestId) selectedProviderId = bestId
    else ensureSelection()
  }

  function activeCount(p) {
    if (!p || !p.hasActiveSession) return 0
    return Math.max(1, (p.activeSessions || []).length)
  }

  // Cards are shown for every provider once its scanner has answered, so
  // each tab has the same layout. Cards without data show an empty line.
  function cardsVisible(p) {
    return !!p && !settingsMode && p.ready
  }

  function resumeSession(conversationId, workspacePath) {
    if (!conversationId || !provider) return
    var id = provider.providerId
    var resumeArgs = (id === "claude" || id === "copilot" || id === "cursor")
      ? [provider.executable, "--resume", conversationId]
      : [provider.executable, "resume", conversationId]
    launch(getTerminalArgs(resumeArgs, workspacePath))
    root.close()
  }

  function resumeIndex(idx) {
    var list = provider ? (provider.recentSessions || []) : []
    if (idx >= 0 && idx < Math.min(5, visibleSessionCount)) resumeSession(list[idx].conversationId, list[idx].workspace)
  }

  function newSession() {
    if (!provider) return
    launch(getTerminalArgs([provider.executable], ""))
    root.close()
  }

  function killSession(conversationId) {
    if (!conversationId || !provider || !provider.scannerScriptPath) return
    Quickshell.execDetached(["python3", provider.scannerScriptPath, "--kill", conversationId])
    killRefreshTimer.restart()
  }

  // ------------------------------------------------------------ Formatting
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }

  function formatCount(n) {
    n = Number(n || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e4) return Math.round(n / 1e3) + "k"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "k"
    return String(n)
  }

  function formatAge(ms) {
    if (!isFinite(ms) || ms <= 0) return ""
    var sec = Math.floor((root.nowMs - ms) / 1000)
    if (sec < 60) return "just now"
    if (sec < 3600) return Math.floor(sec / 60) + "m ago"
    if (sec < 86400) return Math.floor(sec / 3600) + "h ago"
    return Math.floor(sec / 86400) + "d ago"
  }

  function formatCountdown(resetsAt) {
    if (!resetsAt) return ""
    var ms = new Date(resetsAt).getTime()
    if (!isFinite(ms)) return ""
    var diff = ms - root.nowMs
    if (diff <= 0) return "Resets now"
    var minutes = Math.floor(diff / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return "Resets in " + days + "d " + (hours % 24) + "h"
    if (hours > 0) return "Resets in " + hours + "h " + (minutes % 60) + "m"
    return "Resets in " + Math.max(1, minutes) + "m"
  }

  function formatExactResetTime(resetsAt) {
    if (!resetsAt) return ""
    var d = new Date(resetsAt)
    if (isNaN(d.getTime())) return ""
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
  }

  // Remaining-fraction thresholds shared by quota text, bar, and forecast.
  function levelColor(frac, status, normal) {
    if (frac <= 0.15 || status === "critical") return root.urgent
    if (frac <= 0.30 || status === "warning") return root.warn
    return normal
  }

  function tooltipText() {
    if (!provider) return "AI Usage"
    var count = activeCount(provider)
    var status = count > 0 ? " (" + count + " " + (count === 1 ? "session" : "sessions") + " " + provider.activeStatus.toLowerCase() + ")" : " (Idle)"
    var model = provider.currentModel ? " • " + provider.currentModel : ""
    return provider.providerName + status + "\n" + (provider.todayPrompts || 0) + " prompts today" + model
  }

  // -------------------------------------------------------------- Settings
  function cloneObject(value, fallback) {
    if (value === undefined || value === null) return fallback
    try { return JSON.parse(JSON.stringify(value)) }
    catch (e) { return fallback }
  }

  readonly property var agentSettingKeys: ["enableCodex", "enableGrok", "enableAntigravity", "enableClaude", "enableCopilot", "enableCursor"]

  function normalizedSettings(source) {
    var next = cloneObject(source, {}) || {}
    var refresh = Number(next.refreshIntervalSec === undefined || next.refreshIntervalSec === null ? 60 : next.refreshIntervalSec)
    next.refreshIntervalSec = Math.round(clamp(isFinite(refresh) ? refresh : 60, 10, 1800))

    // badgeMode supersedes the older showBadge boolean.
    var bm = next.badgeMode !== undefined && next.badgeMode !== null
      ? String(next.badgeMode).toLowerCase().trim()
      : (next.showBadge === false ? "off" : "active")
    if (bm !== "active" && bm !== "prompts" && bm !== "off") bm = "active"
    next.badgeMode = bm
    next.showBadge = bm !== "off"

    next.enableQuotaAlerts = next.enableQuotaAlerts !== false
    var thresh = Number(next.quotaAlertThreshold === undefined || next.quotaAlertThreshold === null ? 15 : next.quotaAlertThreshold)
    next.quotaAlertThreshold = Math.round(clamp(isFinite(thresh) ? thresh : 15, 5, 50))

    next.terminalCommand = next.terminalCommand ? String(next.terminalCommand).trim() : ""

    var limit = Number(next.recentSessionsLimit === undefined || next.recentSessionsLimit === null ? 5 : next.recentSessionsLimit)
    next.recentSessionsLimit = Math.round(clamp(isFinite(limit) ? limit : 5, 3, 10))

    for (var i = 0; i < agentSettingKeys.length; i++) next[agentSettingKeys[i]] = next[agentSettingKeys[i]] !== false
    return next
  }

  function openSettings() {
    draftSettings = normalizedSettings(settings)
    settingsStatusText = ""
    settingsMode = true
    popupOpen = true
    if (flick) flick.contentY = 0
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function showUsage() {
    settingsMode = false
    settingsStatusText = ""
    if (flick) flick.contentY = 0
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function applySettings(next) {
    var n = normalizedSettings(next)
    root.settings = n
    root.draftSettings = n
  }

  function persistSettings(next) {
    applySettings(next)
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && typeof items[i].applySettings === "function") items[i].applySettings(next)
    }
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") {
      bar.shell.updateEntryInline(root.moduleName, root.settings)
      settingsStatusText = "Saved to shell.json"
    } else {
      settingsStatusText = "Saved for this session"
    }
  }

  function draftValue(name, fallback) {
    var value = draftSettings ? draftSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Keeps typing in a text field from being normalized mid-edit.
  function setDraftOnly(name, value) {
    var next = normalizedSettings(draftSettings)
    next[name] = value
    draftSettings = next
  }

  // Every control saves immediately; there is no separate Save step.
  function updateSetting(name, value) {
    var next = normalizedSettings(root.settings)
    next[name] = value
    persistSettings(normalizedSettings(next))
    if (agentSettingKeys.indexOf(name) !== -1) {
      ensureSelection()
      usageMain.refreshAll(false)
    }
  }

  width: button.implicitWidth
  height: button.implicitHeight
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onPopupOpenChanged: {
    if (popupOpen) {
      if (!settingsMode) {
        selectLastUsedAgent()
        selectLastUsedOnRefresh = true
      }
      root.nowMs = Date.now()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  onRefreshingChanged: {
    if (!refreshing && popupOpen && !settingsMode && selectLastUsedOnRefresh) {
      selectLastUsedAgent()
      selectLastUsedOnRefresh = false
    }
  }

  onSettingsChanged: Qt.callLater(ensureSelection)
  Component.onCompleted: ensureSelection()

  Timer {
    interval: 10000
    running: root.popupOpen
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Main {
    id: usageMain
    settings: root.settings
  }

  Timer {
    id: refreshFlashTimer
    interval: 800
    onTriggered: root.refreshFlash = false
  }

  Timer {
    id: killRefreshTimer
    interval: 350
    onTriggered: root.triggerRefresh(false)
  }

  IpcHandler {
    target: "design-nexus.ai-usage"
    function open(): string {
      root.showUsage()
      root.popupOpen = true
      root.triggerRefresh(false)
      return "ok"
    }
    function close(): string { root.close(); return "ok" }
    function toggle(): string {
      if (root.popupOpen) {
        root.close()
      } else {
        root.showUsage()
        root.popupOpen = true
        root.triggerRefresh(false)
      }
      return "ok"
    }
    function refresh(): string { root.triggerRefresh(false); return "ok" }
    function settings(): string { root.openSettings(); return "ok" }
    function openSettings(): string { root.openSettings(); return "ok" }
    function select(id: string): string {
      if (!usageMain.providerFor(id)) return "unknown or disabled agent: " + id
      root.selectProvider(id)
      return "ok"
    }
    function setBadgeMode(mode: string): string {
      root.updateSetting("badgeMode", mode)
      return "ok"
    }
  }

  // ------------------------------------------------------------ Bar chip
  component UsageChip: Item {
    id: chip

    width: Math.max(root.barSize, iconArea.width + (badge.visible ? badge.width + 3 : 0) + 8)
    height: root.barSize

    Item {
      id: iconArea
      anchors.verticalCenter: parent.verticalCenter
      x: badge.visible ? 4 : (parent.width - width) / 2
      width: 18
      height: 18

      Image {
        id: barIconImage
        source: root.iconSource
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
        anchors.fill: barIconImage
        source: barIconImage
        colorization: 1.0
        colorizationColor: root.foreground
        brightness: 0.3
      }

      // One cell per agent, in allProviders order, so turning one off does not move the others.
      Repeater {
        model: usageMain.allProviders
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

    Text {
      id: badge
      textFormat: Text.PlainText
      visible: root.badgeText !== ""
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: iconArea.right
      anchors.leftMargin: 3
      text: root.badgeText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fsSmall
      font.bold: true
    }

    property var registeredBar: null

    function triggerPress(button) { root.triggerPress(button) }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(chip)
    }

    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)

    Connections {
      target: root
      function onBarChanged() { chip.syncClickRegistration() }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(chip, root.tooltipText())
      onExited: if (root.bar) root.bar.hideTooltip(chip)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
  }

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: usageChip.width
    implicitHeight: root.barSize

    UsageChip {
      id: usageChip
      anchors.centerIn: parent
    }
  }

  // ---------------------------------------------------------------- Panel
  EmbeddedPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: {
      var headerH = (root.settingsMode ? settingsHeader.implicitHeight : statsHeader.implicitHeight)
        + (tabBar.visible ? tabBar.implicitHeight + 8 : 0) + panelSeparator.implicitHeight + 16
      var needed = headerH + contentColumn.implicitHeight + Style.space(12)
      return panel.fittedContentHeight(needed, Style.space(640))
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: settingsMode && settingsContent.editorActive

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) flick.contentY = root.clamp(flick.contentY + dy * 56, 0, Math.max(0, flick.contentHeight - flick.height))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { if (root.bar) root.bar.switchPanelFrom(root, direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "r") root.triggerRefresh(true)
        else if (k === "s") root.settingsMode ? root.showUsage() : root.openSettings()
        else if (k === "q") root.close()
        else if (root.settingsMode) return
        else if (k === "n") root.newSession()
        else if (t >= "1" && t <= "5") root.resumeIndex(parseInt(t) - 1)
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 8

        Header {
          id: statsHeader
          visible: !root.settingsMode
          provider: root.provider
        }

        RowLayout {
          id: tabBar
          visible: !root.settingsMode && root.installedProviders.length > 1
          Layout.fillWidth: true
          spacing: 4

          Repeater {
            model: root.installedProviders
            delegate: Button {
              id: tab
              required property var modelData
              text: modelData.providerId === "claude" ? "Claude" : modelData.providerName
              foreground: root.foreground
              accent: root.accent
              tooltipText: modelData.hasActiveSession ? modelData.providerName + " — " + modelData.activeStatus.toLowerCase() : "Show " + modelData.providerName + " usage"
              tooltipBackground: root.background
              tooltipForeground: root.foreground
              fontFamily: root.fontFamily
              fontSize: root.fsSmall
              horizontalPadding: 7
              verticalPadding: 3
              active: root.selectedProviderId === modelData.providerId
              onClicked: root.selectProvider(modelData.providerId)

              // Live-session marker in the agent's colour, matching the bar dots.
              Rectangle {
                visible: tab.modelData.hasActiveSession
                width: 5
                height: 5
                radius: 2.5
                color: tab.modelData.color
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 2
              }
            }
          }
          Item { Layout.fillWidth: true }
        }

        SettingsHeader {
          id: settingsHeader
          visible: root.settingsMode
        }

        PanelSeparator {
          id: panelSeparator
          Layout.fillWidth: true
          foreground: root.foreground

          Item {
            anchors.fill: parent
            clip: true
            visible: usageMain.refreshing

            Rectangle {
              id: loadingGlow
              anchors.verticalCenter: parent.verticalCenter
              height: 2
              width: Math.max(60, panelSeparator.width * 0.35)
              radius: 1
              color: root.accent

              NumberAnimation on x {
                loops: Animation.Infinite
                running: root.popupOpen && usageMain.refreshing
                from: -loadingGlow.width
                to: panelSeparator.width
                duration: 800
                easing.type: Easing.InOutQuad
              }
            }
          }
        }

        Flickable {
          id: flick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: contentColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          ScrollBar.vertical: ScrollBar {
            policy: flick.contentHeight > (flick.height + 2) ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
          }

          ColumnLayout {
            id: contentColumn
            width: flick.width
            spacing: 8

            SkeletonContent {
              visible: !root.settingsMode && !!root.provider && !root.provider.loaded
            }

            EmptyText {
              visible: !root.settingsMode && root.installedProviders.length === 0
              Layout.topMargin: 24
              text: "All agents are disabled. Press s to turn one on."
            }

            StatusCard { provider: root.settingsMode ? null : root.provider }
            TodayCard { provider: root.provider }
            QuotaLimitsCard { provider: root.provider }
            ModelUsageCard { provider: root.provider }
            WeekCard { provider: root.provider }
            ToolsCard { provider: root.provider }
            RecentSessionsCard { provider: root.provider }

            FooterText {
              visible: root.cardsVisible(root.provider)
              text: "j/k scroll · 1-5 resume · n new · r refresh · s settings · q/esc close"
              wrapMode: Text.NoWrap
              fontSizeMode: Text.HorizontalFit
              minimumPixelSize: 8
            }

            SettingsContent {
              id: settingsContent
              visible: root.settingsMode
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------ Shared pieces
  component EmptyText: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.fsSmall
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
  }

  component FooterText: EmptyText {}

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property color textColor: root.foreground
    color: root.track
    radius: 3
    implicitHeight: 14
    implicitWidth: pillText.implicitWidth + 8
    Layout.preferredHeight: implicitHeight
    Layout.preferredWidth: implicitWidth

    Text {
      id: pillText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, pill.width - 8)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: pill.text
      color: pill.textColor
      font.family: root.fontFamily
      font.pixelSize: root.fsMeta
      font.bold: true
    }
  }

  component MeterBar: Rectangle {
    id: meter
    property real fraction: 0
    property color fill: root.accent
    Layout.fillWidth: true
    Layout.preferredHeight: 6
    color: root.track
    radius: 2
    clip: true

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(meter.fraction, 0, 1)
      color: meter.fill
      radius: 2
      Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
  }

  component IconButton: Button {
    foreground: root.foreground
    accent: root.accent
    tooltipBackground: root.background
    tooltipForeground: root.foreground
    fontFamily: root.fontFamily
    fontSize: root.fsBody
    iconSize: root.fsBody
    horizontalPadding: 6
    verticalPadding: 4
  }

  component RowText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fsSmall
  }

  component MetaText: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.fsMeta
  }

  // --------------------------------------------------------------- Header
  component Header: RowLayout {
    property var provider: null
    Layout.fillWidth: true
    spacing: 8

    Item {
      Layout.preferredWidth: 18
      Layout.preferredHeight: 18
      Layout.alignment: Qt.AlignVCenter

      Image {
        id: headerIconImage
        source: root.iconSource
        anchors.fill: parent
        sourceSize.width: Math.round(18 * (Screen.devicePixelRatio || 1))
        sourceSize.height: Math.round(18 * (Screen.devicePixelRatio || 1))
        fillMode: Image.PreserveAspectFit
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: headerIconImage
        source: headerIconImage
        colorization: 1.0
        colorizationColor: root.foreground
        brightness: 0.3
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 1

      RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
          textFormat: Text.PlainText
          text: provider ? provider.providerName : "AI Usage"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.fsTitle
          font.bold: true
          elide: Text.ElideRight
          Layout.maximumWidth: 180
        }

        Pill {
          visible: !!provider && provider.hasActiveSession
          text: provider ? provider.activeStatus : ""
          readonly property bool working: !!provider && provider.activeStatus === "Working"
          color: working ? root.accent : root.track
          textColor: working ? root.onAccent : root.foreground
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
          textFormat: Text.PlainText
          text: provider ? provider.currentModel : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fsSmall
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        MetaText {
          readonly property double refMs: provider ? (provider.lastFullRefreshMs || provider.lastUpdatedMs) : 0
          readonly property bool stale: refMs > 0 && root.nowMs - refMs > 300000
          visible: !usageMain.refreshing && refMs > 0
          text: root.formatAge(refMs)
          color: stale ? root.urgent : root.dim
        }

        MetaText {
          visible: usageMain.refreshing
          text: "Updating…"
          color: root.accent
        }
      }
    }

    RowLayout {
      spacing: 4
      Layout.alignment: Qt.AlignVCenter

      IconButton {
        iconText: ""
        tooltipText: "New session (n)"
        enabled: !!provider && provider.ready
        onClicked: root.newSession()
      }

      IconButton {
        iconText: ""
        iconSpinning: usageMain.refreshing
        tooltipText: "Refresh (r)"
        active: root.refreshFlash || usageMain.refreshing
        onClicked: {
          root.triggerRefresh(true)
          keyCatcher.forceActiveFocus()
        }
      }

      IconButton {
        iconText: ""
        tooltipText: "Settings (s)"
        onClicked: root.openSettings()
      }
    }
  }

  component SettingsHeader: RowLayout {
    Layout.fillWidth: true
    spacing: 8

    Text {
      textFormat: Text.PlainText
      text: "AI Usage Settings"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fsTitle
      font.bold: true
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
    }

    IconButton {
      text: "Done"
      fontSize: root.fsSmall
      horizontalPadding: 8
      tooltipText: "Back to usage (s)"
      active: true
      onClicked: root.showUsage()
    }
  }

  // ---------------------------------------------------------------- Cards
  component SectionCard: BorderSurface {
    id: section
    property string title: ""
    property string subtitle: ""
    property color titleColor: root.foreground
    property Component headerAccessory: null
    default property alias content: body.data

    Layout.fillWidth: true
    color: root.card
    borderSpec: Border.flat(root.alpha(root.foreground, 0.05), 1)
    padding: 10
    radius: Style.cornerRadius
    implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset
    clip: true

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: section.contentTopInset
      anchors.rightMargin: section.contentRightInset
      anchors.leftMargin: section.contentLeftInset
      spacing: 6

      RowLayout {
        visible: section.title !== "" || section.headerAccessory !== null
        Layout.fillWidth: true
        spacing: 6

        PanelSectionHeader {
          visible: section.title !== ""
          Layout.fillWidth: true
          text: section.title
          foreground: section.titleColor
          fontFamily: root.fontFamily
          fontSize: root.fsBody
        }

        Loader {
          sourceComponent: section.headerAccessory
          visible: !!section.headerAccessory
          Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: section.subtitle !== ""
        Layout.fillWidth: true
        text: section.subtitle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fsSmall
        wrapMode: Text.WordWrap
      }
    }
  }

  component CardEmpty: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.fsSmall
    wrapMode: Text.WordWrap
  }

  component StatBlock: ColumnLayout {
    property string value: "0"
    property string label: ""
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    Layout.minimumWidth: 0
    spacing: 1

    Text {
      textFormat: Text.PlainText
      text: value
      elide: Text.ElideRight
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fsTitle
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      Layout.fillWidth: true
    }
    Text {
      textFormat: Text.PlainText
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.fsMeta
      horizontalAlignment: Text.AlignHCenter
      Layout.fillWidth: true
      elide: Text.ElideRight
    }
  }

  component SkeletonBlock: Rectangle {
    radius: 4
    color: root.alpha(root.foreground, 0.10)

    SequentialAnimation on opacity {
      loops: Animation.Infinite
      running: root.popupOpen
      NumberAnimation { from: 0.4; to: 0.85; duration: 800; easing.type: Easing.InOutQuad }
      NumberAnimation { from: 0.85; to: 0.4; duration: 800; easing.type: Easing.InOutQuad }
    }
  }

  component SkeletonContent: ColumnLayout {
    Layout.fillWidth: true
    spacing: 8

    SectionCard {
      title: "Today"
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Repeater {
          model: 4
          delegate: ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            spacing: 4
            SkeletonBlock { Layout.fillWidth: true; Layout.preferredHeight: 20 }
            SkeletonBlock { Layout.fillWidth: true; Layout.preferredHeight: 9; radius: 3 }
          }
        }
      }
    }

    SectionCard {
      title: "Quota Limits"
      Repeater {
        model: 2
        delegate: ColumnLayout {
          Layout.fillWidth: true
          spacing: 5
          RowLayout {
            Layout.fillWidth: true
            SkeletonBlock { Layout.preferredWidth: 90; Layout.preferredHeight: 11 }
            Item { Layout.fillWidth: true }
            SkeletonBlock { Layout.preferredWidth: 45; Layout.preferredHeight: 11 }
          }
          SkeletonBlock { Layout.fillWidth: true; Layout.preferredHeight: 6; radius: 3 }
        }
      }
    }

    SectionCard {
      title: "Recent Sessions"
      Repeater {
        model: 3
        delegate: ColumnLayout {
          Layout.fillWidth: true
          spacing: 4
          SkeletonBlock { Layout.fillWidth: true; Layout.preferredHeight: 12 }
          SkeletonBlock { Layout.preferredWidth: 130; Layout.preferredHeight: 10 }
        }
      }
    }
  }

  component StatusCard: SectionCard {
    property var provider: null
    readonly property string help: provider ? (provider.authHelpText || provider.error || "") : ""
    visible: help !== ""
    titleColor: root.urgent
    title: provider ? (provider.usageStatusText || "Status") : ""
    subtitle: help
  }

  component TodayCard: SectionCard {
    property var provider: null
    visible: root.cardsVisible(provider)
    title: "Today"

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      StatBlock { value: root.formatCount(provider ? provider.todayPrompts : 0); label: "prompts" }
      StatBlock { value: root.formatCount(provider ? provider.todaySteps : 0); label: "steps" }
      StatBlock { value: root.formatCount(provider ? provider.todayTotalTokens : 0); label: "tokens" }
      StatBlock { value: root.formatCount(provider ? provider.todayCachedTokens : 0); label: "cached" }
      StatBlock { value: root.formatCount(provider ? provider.totalPrompts : 0); label: "all prompts" }
    }
  }

  component QuotaLimitsCard: SectionCard {
    id: quotaCard
    property var provider: null
    readonly property var groups: provider ? (provider.quotaGroups || []) : []
    visible: root.cardsVisible(provider)
    title: "Quota Limits"
    subtitle: provider && provider.planTier ? "Plan: " + provider.planTier : ""

    CardEmpty {
      visible: quotaCard.groups.length === 0
      text: (provider && provider.quotaNote) || "This agent does not report a remaining allowance."
    }

    Repeater {
      model: quotaCard.groups
      delegate: ColumnLayout {
        id: group
        required property var modelData
        readonly property color groupColor: modelData.color || (quotaCard.provider ? quotaCard.provider.color : root.accent)
        Layout.fillWidth: true
        spacing: 4

        RowLayout {
          visible: quotaCard.groups.length > 1
          Layout.fillWidth: true
          spacing: 5

          Rectangle { width: 6; height: 6; radius: 3; color: group.groupColor }

          RowText {
            text: group.modelData.name || "Group"
            font.bold: true
            Layout.fillWidth: true
            elide: Text.ElideRight
          }
        }

        Repeater {
          model: group.modelData.buckets || []
          delegate: ColumnLayout {
            required property var modelData
            readonly property real frac: root.clamp(Number(modelData.remainingFraction !== undefined ? modelData.remainingFraction : (Number(modelData.remainingPercent || 0) / 100)), 0, 1)
            readonly property string reset: modelData.resetTime || modelData.reset_time || ""
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              RowText {
                text: modelData.label || modelData.name || "Limit"
                color: root.dim
                Layout.fillWidth: true
                elide: Text.ElideRight
              }

              MetaText {
                readonly property string exact: root.formatExactResetTime(reset)
                text: {
                  var cd = root.formatCountdown(reset)
                  return exact ? (cd + " · " + exact) : cd
                }
              }

              MetaText {
                text: Math.round(frac * 100) + "% left"
                color: root.levelColor(frac, "", root.foreground)
                font.bold: true
              }
            }

            MeterBar {
              fraction: frac
              fill: root.levelColor(frac, modelData.forecastStatus, modelData.color || group.groupColor)
            }

            MetaText {
              visible: !!modelData.forecastText
              Layout.fillWidth: true
              text: (modelData.burnRateText ? "Burn: " + modelData.burnRateText + " · " : "") + (modelData.forecastText || "")
              color: modelData.forecastStatus === "critical" ? root.urgent : (modelData.forecastStatus === "warning" ? root.warn : root.dim)
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  component ModelUsageCard: SectionCard {
    id: modelCardRoot
    property var provider: null
    property string timeRange: "today" // "today" | "week" | "all"
    visible: root.cardsVisible(provider)
    title: "Models"

    headerAccessory: Component {
      Rectangle {
        color: root.track
        radius: 3
        implicitHeight: 18
        implicitWidth: toggleRow.implicitWidth + 4
        border.color: root.outline
        border.width: 1

        RowLayout {
          id: toggleRow
          anchors.centerIn: parent
          spacing: 1

          Repeater {
            model: [
              { key: "today", label: "Today" },
              { key: "week", label: "7 days" },
              { key: "all", label: "All time" }
            ]

            delegate: Rectangle {
              required property var modelData
              readonly property bool isSelected: modelCardRoot.timeRange === modelData.key
              radius: 2
              implicitHeight: 14
              implicitWidth: optText.implicitWidth + 8
              color: isSelected ? root.accent : (optMouse.containsMouse ? root.cardHover : "transparent")

              Behavior on color { ColorAnimation { duration: 100 } }

              Text {
                id: optText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData.label
                color: isSelected ? root.onAccent : (optMouse.containsMouse ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: root.fsMeta
                font.bold: isSelected
              }

              MouseArea {
                id: optMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: modelCardRoot.timeRange = modelData.key
              }
            }
          }
        }
      }
    }

    readonly property var rawModelList: {
      if (provider && provider.modelList && provider.modelList.length > 0) return provider.modelList
      var usage = provider ? (provider.modelUsage || {}) : {}
      var res = []
      for (var k in usage) res.push(usage[k])
      return res
    }

    function getPrompts(m) {
      if (timeRange === "today") return Number(m.todayPrompts || 0)
      if (timeRange === "week") return Number(m.weekPrompts || 0)
      return Number(m.prompts || 0)
    }

    function getSteps(m) {
      if (timeRange === "today") return Number(m.todaySteps || 0)
      if (timeRange === "week") return Number(m.weekSteps || 0)
      return Number(m.steps || 0)
    }

    readonly property real totalPrompts: rawModelList.reduce(function(sum, m) { return sum + getPrompts(m) }, 0)
    readonly property real totalSteps: rawModelList.reduce(function(sum, m) { return sum + getSteps(m) }, 0)

    // Models with no activity in the selected range are hidden.
    readonly property var displayModelList: rawModelList
      .filter(function(m) { return getPrompts(m) > 0 || getSteps(m) > 0 })
      .sort(function(a, b) { return (getPrompts(b) - getPrompts(a)) || (getSteps(b) - getSteps(a)) })

    CardEmpty {
      visible: modelCardRoot.displayModelList.length === 0
      text: modelCardRoot.timeRange === "today" ? "No prompts recorded yet today."
        : (modelCardRoot.timeRange === "week" ? "No prompts recorded in the last 7 days." : "No model activity recorded.")
    }

    Repeater {
      model: modelCardRoot.displayModelList
      delegate: ColumnLayout {
        required property var modelData
        readonly property int pCount: modelCardRoot.getPrompts(modelData)
        readonly property int sCount: modelCardRoot.getSteps(modelData)
        readonly property real shareFrac: modelCardRoot.totalPrompts > 0
          ? pCount / modelCardRoot.totalPrompts
          : (modelCardRoot.totalSteps > 0 ? sCount / modelCardRoot.totalSteps : 0)
        Layout.fillWidth: true
        spacing: 2

        RowLayout {
          Layout.fillWidth: true
          spacing: 6

          RowText {
            text: modelData.name || "Model"
            font.bold: true
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          MetaText { text: root.formatCount(pCount) + " prompts · " + root.formatCount(sCount) + " steps" }

          MetaText {
            text: Math.round(shareFrac * 100) + "%"
            color: root.foreground
            font.bold: true
          }
        }

        MeterBar {
          fraction: shareFrac
          fill: modelData.color || (modelCardRoot.provider ? modelCardRoot.provider.color : root.accent)
        }
      }
    }
  }

  component WeekCard: SectionCard {
    id: weekCardRoot
    property var provider: null
    // Newest first, so today is the top row.
    readonly property var days: provider ? (provider.recentDays || []).slice().reverse() : []
    function promptsFor(d) { return Number(d.prompts !== undefined ? d.prompts : (d.messageCount || 0)) }
    readonly property real maxCount: days.reduce(function(m, d) { return Math.max(m, promptsFor(d)) }, 1)
    readonly property bool hasActivity: days.some(function(d) { return promptsFor(d) > 0 })
    visible: root.cardsVisible(provider)
    title: "Last 7 Days"

    CardEmpty {
      visible: !weekCardRoot.hasActivity
      text: "No prompts recorded in the last 7 days."
    }

    Repeater {
      model: weekCardRoot.hasActivity ? weekCardRoot.days : []
      delegate: RowLayout {
        required property var modelData
        required property int index
        readonly property real count: weekCardRoot.promptsFor(modelData)
        Layout.fillWidth: true
        spacing: 6

        RowText {
          text: {
            if (index === 0) return "Today"
            var dt = new Date(modelData.date + "T00:00:00")
            if (isNaN(dt.getTime())) return ""
            var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return names[dt.getDay()] + " " + String(dt.getMonth() + 1).padStart(2, "0") + "/" + String(dt.getDate()).padStart(2, "0")
          }
          color: index === 0 ? root.foreground : root.dim
          font.bold: index === 0
          Layout.preferredWidth: 58
        }

        MeterBar {
          fraction: count / weekCardRoot.maxCount
          fill: root.weekBarColor
        }

        RowText {
          text: root.formatCount(count) + " prompts"
          font.bold: true
          horizontalAlignment: Text.AlignRight
          Layout.preferredWidth: 72
        }
      }
    }
  }

  component ToolsCard: SectionCard {
    id: toolsCard
    property var provider: null
    readonly property var tools: {
      var usage = provider ? (provider.toolUsage || {}) : {}
      var res = []
      for (var k in usage) res.push({ name: k, count: Number(usage[k] || 0) })
      res.sort(function(a, b) { return b.count - a.count })
      return res.slice(0, 6)
    }
    visible: root.cardsVisible(provider)
    title: "Top Tools"

    CardEmpty {
      visible: toolsCard.tools.length === 0
      text: "No tool calls recorded."
    }

    GridLayout {
      visible: toolsCard.tools.length > 0
      Layout.fillWidth: true
      columns: 2
      columnSpacing: 10
      rowSpacing: 4

      Repeater {
        model: toolsCard.tools
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          Layout.preferredWidth: 1
          spacing: 4

          RowText {
            text: modelData.name
            color: root.dim
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
          RowText {
            text: root.formatCount(modelData.count)
            font.bold: true
          }
        }
      }
    }
  }

  component RecentSessionsCard: SectionCard {
    id: recentSessionsCardRoot
    property var provider: null
    property bool expanded: false
    readonly property var sessions: provider ? (provider.recentSessions || []) : []
    visible: root.cardsVisible(provider)
    title: "Recent Sessions"
    subtitle: root.visibleSessionCount > 0 ? "Click or press 1-" + Math.min(5, root.visibleSessionCount) + " to resume" : ""

    onProviderChanged: expanded = false

    CardEmpty {
      visible: recentSessionsCardRoot.sessions.length === 0
      text: "No sessions yet. Press n to start " + (provider ? provider.providerName : "one") + "."
    }

    Repeater {
      id: sessionRepeater
      model: recentSessionsCardRoot.sessions.slice(0, recentSessionsCardRoot.expanded ? 10 : root.sessionLimit)
      delegate: ColumnLayout {
        required property var modelData
        required property int index
        Layout.fillWidth: true
        spacing: 2

        Rectangle {
          id: sessionItemCard
          Layout.fillWidth: true
          implicitHeight: sessionCol.implicitHeight + 8
          radius: 4
          readonly property bool isHovered: sessionMouseArea.containsMouse || killMouse.containsMouse
          color: isHovered ? root.cardHover : "transparent"

          Behavior on color { ColorAnimation { duration: 120 } }

          MouseArea {
            id: sessionMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.resumeSession(modelData.conversationId, modelData.workspace)
          }

          ColumnLayout {
            id: sessionCol
            anchors.fill: parent
            anchors.margins: 4
            spacing: 3

            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              MetaText {
                visible: index < 5
                text: "[" + (index + 1) + "]"
                color: sessionItemCard.isHovered ? root.accent : root.dim
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.preview || modelData.title || "Session"
                color: sessionItemCard.isHovered ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fsBody
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
              }

              Pill {
                visible: !!modelData.isActive && !!root.provider && root.provider.canKill
                text: ""
                color: killMouse.containsMouse ? root.urgent : root.track
                textColor: killMouse.containsMouse ? root.onAccent : root.foreground
                implicitWidth: 14

                Behavior on color { ColorAnimation { duration: 80 } }

                MouseArea {
                  id: killMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.killSession(modelData.conversationId)
                }
              }

              Pill {
                text: modelData.isActive ? "ACTIVE" : "IDLE"
                color: modelData.isActive ? root.accent : root.track
                textColor: modelData.isActive ? root.onAccent : root.dim
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              Pill {
                visible: !!modelData.workspaceName
                text: " " + (modelData.workspaceName || "")
                Layout.maximumWidth: 160
              }

              MetaText { text: root.formatAge(root.sessionActivityMs(modelData)) }

              MetaText {
                visible: Number(modelData.stepCount || 0) > 0
                text: "· " + root.formatCount(modelData.stepCount) + " steps"
              }
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
          strength: 0.12
          visible: index < (sessionRepeater.count - 1)
        }
      }
    }

    Item {
      visible: recentSessionsCardRoot.sessions.length > root.sessionLimit
      Layout.fillWidth: true
      implicitHeight: 18

      MetaText {
        anchors.centerIn: parent
        text: recentSessionsCardRoot.expanded ? "Show fewer ▴" : ("Show all (" + recentSessionsCardRoot.sessions.length + ") ▾")
        color: moreMouse.containsMouse ? root.accent : root.dim
        font.bold: true
      }

      MouseArea {
        id: moreMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: recentSessionsCardRoot.expanded = !recentSessionsCardRoot.expanded
      }
    }
  }

  // -------------------------------------------------------- Settings page
  // Label on the left; the control declared inside a SettingRow lands after it.
  component SettingRow: RowLayout {
    id: settingRow
    property string label: ""
    Layout.fillWidth: true
    spacing: 8

    RowText {
      Layout.fillWidth: true
      text: settingRow.label
      font.pixelSize: root.fsBody
    }
  }

  component SettingsContent: ColumnLayout {
    Layout.fillWidth: true
    spacing: 8

    readonly property bool editorActive: Boolean(
      (refreshIntervalField.field && refreshIntervalField.field.activeFocus)
      || (alertThresholdField.field && alertThresholdField.field.activeFocus)
      || (recentSessionsLimitField.field && recentSessionsLimitField.field.activeFocus)
      || terminalField.activeFocus
    )

    SectionCard {
      title: "Agents"
      subtitle: "Which agents appear as tabs and activity dots."

      Repeater {
        model: [
          { key: "enableCodex", label: "Codex" },
          { key: "enableGrok", label: "Grok" },
          { key: "enableAntigravity", label: "Antigravity" },
          { key: "enableClaude", label: "Claude Code" },
          { key: "enableCopilot", label: "Copilot" },
          { key: "enableCursor", label: "Cursor" }
        ]
        delegate: SettingRow {
          required property var modelData
          label: modelData.label

          // The switch does not flip itself: checked follows the saved
          // draft, and the click writes the opposite value.
          ToggleSwitch {
            checked: root.draftValue(modelData.key, true) !== false
            onToggled: root.updateSetting(modelData.key, !checked)
          }
        }
      }
    }

    SectionCard {
      title: "Refresh"
      subtitle: "Idle polling interval. Agents with a live session refresh every 10 seconds."

      NumberField {
        id: refreshIntervalField
        label: "Interval (seconds)"
        value: Number(root.draftValue("refreshIntervalSec", 60))
        from: 10
        to: 1800
        stepSize: 10
        fieldWidth: parent.width
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onModified: function(value) { root.updateSetting("refreshIntervalSec", value) }
      }
    }

    SectionCard {
      title: "Bar Badge"
      subtitle: "Number shown next to the bar icon."

      ButtonGroup {
        id: badgeModeButtonGroup
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: root.fsSmall
        options: [
          { value: "active", label: "Active sessions", tooltip: "Live sessions across all enabled agents" },
          { value: "prompts", label: "Today's prompts", tooltip: "Prompts sent today across all enabled agents" },
          { value: "off", label: "Off", tooltip: "Icon only" }
        ]
        value: root.draftValue("badgeMode", "active")
        onChanged: function(v) { root.updateSetting("badgeMode", v) }

        Connections {
          target: root
          function onDraftSettingsChanged() { badgeModeButtonGroup.value = String(root.draftValue("badgeMode", "active")) }
        }
      }
    }

    SectionCard {
      title: "Low Quota Alerts"
      subtitle: "Desktop notification when a reported allowance drops below the threshold."

      SettingRow {
        label: "Enable alerts"
        ToggleSwitch {
          checked: root.draftValue("enableQuotaAlerts", true) !== false
          onToggled: root.updateSetting("enableQuotaAlerts", !checked)
        }
      }

      NumberField {
        id: alertThresholdField
        label: "Threshold (% remaining)"
        value: Number(root.draftValue("quotaAlertThreshold", 15))
        from: 5
        to: 50
        stepSize: 5
        fieldWidth: parent.width
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        enabled: root.draftValue("enableQuotaAlerts", true) !== false
        opacity: enabled ? 1.0 : 0.45
        onModified: function(value) { root.updateSetting("quotaAlertThreshold", value) }
      }
    }

    SectionCard {
      title: "Terminal"
      subtitle: "Used to start and resume sessions. Leave blank for xdg-terminal-exec; foot, ghostty, kitty, alacritty, or a custom command also work."

      TextField {
        id: terminalField
        Layout.fillWidth: true
        placeholderText: "xdg-terminal-exec"
        text: String(root.draftValue("terminalCommand", ""))
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: root.fsBody
        onTextEdited: root.setDraftOnly("terminalCommand", text)
        onEditingFinished: root.updateSetting("terminalCommand", text)

        Connections {
          target: root
          function onDraftSettingsChanged() {
            if (!terminalField.activeFocus) terminalField.text = String(root.draftValue("terminalCommand", ""))
          }
        }
      }
    }

    SectionCard {
      title: "Recent Sessions"
      subtitle: "Rows shown before expanding."

      NumberField {
        id: recentSessionsLimitField
        label: "Rows (3-10)"
        value: Number(root.draftValue("recentSessionsLimit", 5))
        from: 3
        to: 10
        stepSize: 1
        fieldWidth: parent.width
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onModified: function(value) { root.updateSetting("recentSessionsLimit", value) }
      }
    }

    FooterText {
      text: (root.settingsStatusText ? root.settingsStatusText + " · " : "") + "Changes save automatically · s back · esc close"
    }
  }
}
