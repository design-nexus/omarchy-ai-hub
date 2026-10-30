import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../.."

// The Local page: LM Studio and Ollama, each switchable in the hub settings.
// Its settings live under the hub entry's `local` key: showLmStudio,
// showOllama, lmsPath, refreshIntervalSec (LM Studio), ollamaUrl,
// ollamaRefreshSec and terminalCommand (for Ollama's Chat button).
BarWidget {
  id: root
  moduleName: "design-nexus.ai-hub.local"

  readonly property bool showLmStudio: !settings || settings.showLmStudio !== false
  readonly property bool showOllama: !settings || settings.showOllama !== false

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // Either enabled server is up, for the hub's bar ring and tab dot.
  readonly property bool active: (showLmStudio && lmstudio.active) || (showOllama && ollama.active)

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function refresh() {
    if (showLmStudio) lmstudio.refresh()
    if (showOllama) ollama.refresh()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = root
    panelLoader.item.hostWidget = root
  }

  implicitWidth: 0
  implicitHeight: 0

  onBarChanged: injectPanel()

  // Shared by every bar; HubServices polls them once for the whole shell.
  readonly property var lmstudio: HubServices.lmstudio
  readonly property var ollama: HubServices.ollama

  Loader {
    id: panelLoader
    active: true
    visible: false
    Component.onCompleted: setSource(Qt.resolvedUrl("Content.qml"), {
      "lmstudio": root.lmstudio,
      "ollama": root.ollama
    })
    onLoaded: {
      item.showLmStudio = Qt.binding(function() { return root.showLmStudio })
      item.showOllama = Qt.binding(function() { return root.showOllama })
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
