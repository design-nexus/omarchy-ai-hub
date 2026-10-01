import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

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

  LmStudioService {
    id: lmSvc
    settings: root.settings
    polling: root.showLmStudio
  }
  property alias lmstudio: lmSvc

  OllamaService {
    id: ollamaSvc
    settings: root.settings
    polling: root.showOllama
  }
  property alias ollama: ollamaSvc

  Loader {
    id: panelLoader
    active: true
    visible: false
    Component.onCompleted: setSource(Qt.resolvedUrl("Content.qml"), {
      "lmstudio": lmSvc,
      "ollama": ollamaSvc
    })
    onLoaded: {
      item.showLmStudio = Qt.binding(function() { return root.showLmStudio })
      item.showOllama = Qt.binding(function() { return root.showOllama })
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
