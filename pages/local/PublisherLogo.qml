import QtQuick
import qs.Commons
import "Model.js" as Model

// Publisher brand logo for a model card, mirroring LM Studio's model
// picker: renders the publisher's Simple Icons glyph (CC0) fetched from
// cdn.simpleicons.org the first time the panel is opened, and falls back
// to a deterministic colored initial tile while loading, offline, or for
// publishers without an icon. Only the slug is sent to the CDN.
Item {
  id: root

  property string publisher: ""
  property string label: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool loadRemote: true

  readonly property string slug: Model.publisherLogoSlug(publisher)
  readonly property url logoSource: loadRemote && slug !== ""
    ? "https://cdn.simpleicons.org/" + slug + Model.logoColorSuffix(slug)
    : ""

  Image {
    id: logo
    anchors.centerIn: parent
    width: Math.round(parent.width * 0.55)
    height: width
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    cache: true
    source: root.logoSource
    sourceSize: Qt.size(128, 128)
    visible: status === Image.Ready
  }

  Rectangle {
    id: fallbackTile
    anchors.fill: parent
    radius: Style.cornerRadius
    visible: logo.status !== Image.Ready
    color: Qt.hsla(Model.avatarHue(root.publisher) / 360, 0.5, 0.55, 1)

    Text {
      anchors.centerIn: parent
      text: Model.avatarInitial(root.label, root.publisher)
      color: "#ffffff"
      font.family: root.fontFamily
      font.bold: true
      font.pixelSize: Math.round(parent.height * 0.45)
    }
  }
}
