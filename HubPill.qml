import QtQuick
import qs.Commons

// The AI Usage status pill ("Working"): small, bold, filled.
Rectangle {
  id: root

  property string text: ""
  property bool active: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitWidth: label.implicitWidth + 10
  implicitHeight: label.implicitHeight + 3
  width: implicitWidth
  height: implicitHeight
  radius: 3
  color: active ? Color.accent : HubStyle.track(foreground)

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.active ? (Color.popups && Color.popups.background ? Color.popups.background : Color.background) : root.foreground
    font.family: root.fontFamily
    font.pixelSize: HubStyle.fsMeta
    font.bold: true
  }
}
