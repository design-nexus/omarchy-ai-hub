import QtQuick
import qs.Commons
import qs.Ui

// The AI Usage section card: faint fill, hairline border, a bold section title.
BorderSurface {
  id: root

  property string title: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property Component headerAccessory: null
  default property alias content: body.data

  width: parent ? parent.width : implicitWidth
  color: HubStyle.card(foreground)
  borderSpec: Border.flat(HubStyle.cardBorder(foreground), 1)
  padding: HubStyle.cardPadding
  radius: Style.cornerRadius
  implicitHeight: column.implicitHeight + contentTopInset + contentBottomInset

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.contentTopInset
    anchors.leftMargin: root.contentLeftInset
    anchors.rightMargin: root.contentRightInset
    spacing: 6

    Item {
      visible: root.title !== "" || root.headerAccessory !== null
      width: parent.width
      height: Math.max(heading.implicitHeight, accessory.implicitHeight)

      PanelSectionHeader {
        id: heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: HubStyle.fsBody
      }

      Loader {
        id: accessory
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: root.headerAccessory
      }
    }

    Column {
      id: body
      width: parent.width
      spacing: 6
    }
  }
}
