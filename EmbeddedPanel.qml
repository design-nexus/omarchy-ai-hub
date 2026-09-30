import QtQuick
import qs.Commons

// Stand-in for qs.Ui.KeyboardPanel inside a hosted page. The copied plugins
// keep their popup body untouched; instead of mapping a layer-shell window of
// their own, the body is parented into the hub popup's page area.
//
// The host is found through the page's proxy bar (PageBar.pageHost), which
// also names the page, so no page file needs to know it is being hosted.
Item {
  id: root

  // KeyboardPanel API subset the pages actually use.
  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: null
  property bool centerOnBar: false
  property bool open: false
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: true
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var host: bar && bar.pageHost ? bar.pageHost : null
  readonly property string pageKey: bar && bar.pageKey ? bar.pageKey : ""
  readonly property real availableCardWidth: host ? host.availablePageWidth : 0
  readonly property real availableCardHeight: host ? host.availablePageHeight : 0
  readonly property real verticalContentInset: padding * 2

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  parent: host ? host.pageArea : null
  visible: open && !!host && host.currentKey === pageKey
  width: parent ? parent.width : contentWidth
  height: parent ? parent.height : contentHeight

  // host and pageKey both derive from `bar`, which lazily loaded pages inject
  // after creation; register once both have settled, whichever lands last.
  function tryRegister() { if (host && pageKey) host.registerPanel(root) }
  onHostChanged: tryRegister()
  onPageKeyChanged: tryRegister()
  onOpenChanged: if (host) host.pageOpenChanged(root)
  Component.onCompleted: tryRegister()

  Item {
    id: contentHolder
    anchors.fill: parent
    anchors.margins: root.padding
  }
}
