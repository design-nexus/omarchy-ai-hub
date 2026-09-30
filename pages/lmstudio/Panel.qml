import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "design-nexus.lmstudio"

  // Color/theme functions - handle bar being undefined initially
  function barForeground() { return (bar && bar.foreground) ? bar.foreground : Color.foreground }
  function urgent() { return (bar && bar.urgent) ? bar.urgent : Color.urgent }
  function barIconColor() { return lmstudio.active ? barForeground() : Qt.darker(barForeground(), 1.55) }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Service {
    id: svc
    settings: root.settings
  }
  property alias lmstudio: svc

  Loader {
    id: panelLoader
    active: true
    visible: false
    Component.onCompleted: setSource(Qt.resolvedUrl("PanelContent.qml"), { "lmstudio": svc })
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { lmstudio.refresh(); return "ok" }
    function startServer(): string { lmstudio.startServer(); return "ok" }
    function stopServer(): string { lmstudio.stopServer(); return "ok" }
    function status(): string { return lmstudio.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        LMStudioIcon {
          anchors.centerIn: parent
          iconSize: 12
          color: root.barIconColor()
          badgeColor: root.urgent()
          running: lmstudio.active
          modelCount: lmstudio.modelCount
          warning: lmstudio.serverError !== "" || lmstudio.lastError !== ""
          crossed: lmstudio.installed && !lmstudio.active
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) lmstudio.toggleServer()
      else if (buttonCode === Qt.MiddleButton) lmstudio.refresh()
      else root.toggle()
    }
  }
}