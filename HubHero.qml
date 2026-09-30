import QtQuick
import qs.Commons

// Page header in the AI Usage style, with PanelHero's API so hosted pages can
// swap it in by type name: icon, bold title with an optional status pill
// beside it, one dim sentence-case line under it, trailing control on the right.
Item {
  id: root

  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property string detail: ""
  property bool detailActive: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real iconSize: HubStyle.iconSize
  property real iconOpacity: 1.0
  property real metaOpacity: 1.0
  property Component trailingControl: null

  readonly property color dim: HubStyle.dimOf(foreground)
  readonly property real trailingInset: trailingLoader.item && trailingLoader.item.visible ? trailingLoader.width + Style.space(10) : 0

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(iconBox.height, labels.implicitHeight, trailingLoader.implicitHeight)

  Item {
    id: iconBox
    visible: root.iconComponent !== null
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: visible ? root.iconSize : 0
    height: root.iconSize

    Loader {
      anchors.centerIn: parent
      sourceComponent: root.iconComponent
      opacity: root.iconOpacity
    }
  }

  Column {
    id: labels
    anchors.left: iconBox.right
    anchors.leftMargin: iconBox.visible ? HubStyle.gap : 0
    anchors.right: parent.right
    anchors.rightMargin: root.trailingInset
    anchors.verticalCenter: parent.verticalCenter
    spacing: 1

    Row {
      width: parent.width
      spacing: 6

      Text {
        id: titleText
        textFormat: Text.PlainText
        text: root.title
        width: Math.min(implicitWidth, parent.width - (pill.visible ? pill.width + parent.spacing : 0))
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: HubStyle.fsTitle
        font.bold: true
        elide: Text.ElideRight
      }

      HubPill {
        id: pill
        anchors.verticalCenter: titleText.verticalCenter
        visible: root.detail !== ""
        text: root.detail
        active: root.detailActive
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      text: root.meta
      opacity: root.metaOpacity
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: HubStyle.fsSmall
      elide: Text.ElideRight
    }
  }

  Loader {
    id: trailingLoader
    sourceComponent: root.trailingControl
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
  }
}
