import QtQuick
import QtQuick.Layouts
import qs.Commons

// One resource reading: icon, label and value on a line, with an optional
// usage bar under it (fraction 0..1; below 0 hides the bar).
Column {
  id: cell

  property string iconText: ""
  property string label: ""
  property string value: ""
  property real fraction: -1
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)

  // Equal preferred widths so a two-column grid splits evenly; the
  // cell's own implicit width is 0 (its row follows its width).
  Layout.fillWidth: true
  Layout.preferredWidth: 100
  spacing: Style.spacing.labelGap

  Row {
    width: parent.width
    spacing: Style.space(6)

    Text {
      id: cellIcon
      text: cell.iconText
      color: cell.dim
      font.family: cell.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: Math.max(0, parent.width - cellIcon.width - cellValue.width - parent.spacing * 2)
      textFormat: Text.PlainText
      text: cell.label
      color: cell.dim
      font.family: cell.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: cellValue
      textFormat: Text.PlainText
      text: cell.value
      color: cell.foreground
      font.family: cell.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Item {
    visible: cell.fraction >= 0
    width: parent.width
    height: Style.space(4)

    Rectangle {
      id: track
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(cell.foreground.r, cell.foreground.g, cell.foreground.b, 0.12)
    }

    Rectangle {
      anchors.left: track.left
      anchors.verticalCenter: track.verticalCenter
      height: track.height
      radius: track.radius
      width: Math.max(track.height, track.width * Math.min(1.0, Math.max(0.0, cell.fraction)))
      color: cell.foreground

      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }
  }
}
