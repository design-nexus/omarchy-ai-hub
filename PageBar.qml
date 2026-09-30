import QtQuick
import qs.Commons

// The bar facade handed to one hosted page. Presentation state mirrors the
// real bar; everything that would make the page act like a bar widget of its
// own (click targets, popout ownership, tooltips) is swallowed, and panel
// switching and settings writes are routed to the hub.
QtObject {
  id: api

  property var realBar: null
  property var pageHost: null
  property string pageKey: ""
  property var pageEntry: null

  readonly property color foreground: realBar ? realBar.foreground : Color.foreground
  readonly property color barForeground: realBar ? realBar.barForeground : Color.foreground
  readonly property color background: realBar ? realBar.background : Color.background
  readonly property color urgent: realBar ? realBar.urgent : Color.urgent
  readonly property string fontFamily: realBar ? realBar.fontFamily : Style.font.family
  readonly property string position: realBar ? realBar.position : "top"
  readonly property bool vertical: realBar ? realBar.vertical : false
  readonly property int barSize: realBar ? realBar.barSize : Style.bar.sizeHorizontal
  readonly property bool transparent: realBar ? realBar.transparent : false
  readonly property bool foregroundAnimationEnabled: realBar ? realBar.foregroundAnimationEnabled : true
  readonly property bool centerSectionRevealHeld: false
  readonly property bool centerHoverRevealSuppressed: false
  readonly property var layoutConfig: realBar ? realBar.layoutConfig : ({})
  property var activePopout: null
  property var clickTargets: []
  property string tooltipText: ""

  readonly property var _realShell: realBar ? realBar.shell : null

  property QtObject shell: QtObject {
    readonly property var appLibrary: api._realShell ? api._realShell.appLibrary : null
    readonly property var barConfig: api._realShell ? api._realShell.barConfig : ({})
    readonly property var idleConfig: api._realShell ? api._realShell.idleConfig : ({})

    function serviceFor(id) { return api._realShell ? api._realShell.serviceFor(id) : null }
    function firstPartyServiceFor(id) { return api._realShell ? api._realShell.firstPartyServiceFor(id) : null }
    function summon(id, payloadJson) { return api._realShell ? api._realShell.summon(id, payloadJson) : false }
    function hide(id) { return api._realShell ? api._realShell.hide(id) : false }
    function toggle(id, payloadJson) { return api._realShell ? api._realShell.toggle(id, payloadJson) : false }
    function isPluginOpen(id) { return api._realShell ? api._realShell.isPluginOpen(id) : false }
    function mutateShellConfig(mutator) { return api._realShell ? api._realShell.mutateShellConfig(mutator) : false }
    // Pages save their whole settings entry; it lands under their key in the hub's entry.
    function updateEntryInline(id, settings) {
      return api.pageHost ? api.pageHost.savePageSettings(api.pageKey, settings) : false
    }
  }

  function setCenterHoverRevealSuppressed(value) {}
  function showTooltip(target, text) {}
  function hideTooltip(target) {}
  function registerClickTarget(target) {}
  function unregisterClickTarget(target) {}
  function requestPopout(owner) {}
  function releasePopout(owner) {}
  function targetBelongsToWindow(target, window) { return false }

  function switchPanelFrom(owner, direction) {
    return pageHost ? pageHost.cyclePage(direction) : false
  }

  function moduleWidgets(id) {
    return pageEntry ? [pageEntry] : []
  }

  function run(command) {
    if (realBar) realBar.run(command)
  }
}
