import QtQuick
import qs.Commons
import qs.Commons as Commons

// The AI Usage status pill ("Working"): small, bold, filled.
Rectangle {
  id: root

  property string text: ""
  property bool active: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  implicitWidth: label.implicitWidth + 10
  implicitHeight: label.implicitHeight + 3
  width: implicitWidth
  height: implicitHeight
  radius: 3
  color: active ? Commons.Color.accent : HubStyle.track(foreground)

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.active ? (Commons.Color.popups && Commons.Color.popups.background ? Commons.Color.popups.background : Commons.Color.background) : root.foreground
    font.family: root.fontFamily
    font.pixelSize: HubStyle.fsMeta
    font.bold: true
  }
}
