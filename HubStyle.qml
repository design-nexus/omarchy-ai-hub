pragma Singleton
import QtQuick
import qs.Commons

// The AI Usage page's type scale and surface colours, shared so every hosted
// page draws headers, sections and pills the same way.
QtObject {
  readonly property int fsTitle: Style.font.title
  readonly property int fsBody: Style.font.bodySmall
  readonly property int fsSmall: Style.font.caption
  readonly property int fsMeta: Style.font.caption - 1
  readonly property int gap: 8
  readonly property int iconSize: 18
  readonly property int cardPadding: 10

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function dimOf(c) { return Qt.darker(c, 1.45) }
  function track(c) { return alpha(c, 0.24) }
  function card(c) { return alpha(c, 0.055) }
  function cardHover(c) { return alpha(c, 0.085) }
  function cardBorder(c) { return alpha(c, 0.05) }
  function outline(c) { return alpha(c, 0.18) }
}
