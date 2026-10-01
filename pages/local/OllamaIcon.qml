import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Ollama's mark (Simple Icons, CC0) with LMStudioIcon's API and overlays:
// dimmed when stopped, crossed out when installed but stopped, a pulsing dot
// while a model is loaded, and a warning badge.
Item {
  id: root

  property real iconSize: 12
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property color activeModelColor: "#38bdf8"
  property bool running: false
  property int modelCount: 0
  property bool warning: false
  property bool crossed: false

  readonly property real containerSize: Math.max(18, Math.round(iconSize * 1.5))
  readonly property bool hasActiveModel: running && modelCount > 0
  readonly property real dotWidth: Math.max(3, Math.round(containerSize * (3 / 18)))

  width: containerSize
  height: containerSize
  implicitWidth: containerSize
  implicitHeight: containerSize

  Item {
    id: iconBox
    anchors.centerIn: parent
    width: root.iconSize
    height: root.iconSize

    Image {
      id: mark
      anchors.fill: parent
      source: Qt.resolvedUrl("assets/ollama.svg")
      sourceSize.width: Math.round(root.iconSize * 2 * (Screen.devicePixelRatio || 1))
      sourceSize.height: Math.round(root.iconSize * 2 * (Screen.devicePixelRatio || 1))
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: mark
      source: mark
      colorization: 1.0
      colorizationColor: root.running ? root.color : Qt.darker(root.color, 2.5)
      opacity: root.running ? 1.0 : 0.6
      Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    Rectangle {
      visible: root.crossed
      anchors.centerIn: parent
      width: parent.width * 1.3
      height: Math.max(2, parent.height * 0.12)
      radius: height / 2
      color: Qt.darker(root.color, 1.5)
      rotation: -45
      opacity: 0.7
    }
  }

  Rectangle {
    visible: root.hasActiveModel
    width: root.dotWidth
    height: root.dotWidth
    radius: width / 2
    color: root.activeModelColor
    x: 0
    y: parent.height - height

    SequentialAnimation on opacity {
      running: root.hasActiveModel
      loops: Animation.Infinite
      NumberAnimation { from: .25; to: 1; duration: 600; easing.type: Easing.InOutQuad }
      NumberAnimation { from: 1; to: .25; duration: 600; easing.type: Easing.InOutQuad }
    }
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, root.iconSize * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
