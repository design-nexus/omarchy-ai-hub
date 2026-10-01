import QtQuick
import qs.Commons
import qs.Ui

// The hub's own settings (the gear in the tab row): which tabs show, and
// which servers the Local tab shows. Changes save at once to the hub's
// shell.json entry. ↑/↓ move, Enter or Space flips, Tab leaves, Esc closes.
FocusScope {
  id: root

  property var hub: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: HubStyle.dimOf(foreground)

  // Every switch, in drawing order.
  readonly property var rows: {
    var list = []
    for (var i = 0; i < hub.pageKeys.length; i++) {
      var key = hub.pageKeys[i]
      list.push({ group: "tabs", key: key, label: hub.pageTitles[key] })
    }
    list.push({ group: "local", key: "showLmStudio", label: "LM Studio" })
    list.push({ group: "local", key: "showOllama", label: "Ollama" })
    return list
  }
  property int cursor: -1

  function isOn(row) {
    if (row.group === "tabs") return hub.tabShown(row.key)
    return hub.localSettings[row.key] !== false
  }

  // The last visible tab cannot be hidden.
  function isLocked(row) {
    return row.group === "tabs" && isOn(row) && hub.visibleKeys.length <= 1
  }

  function flip(row) {
    if (!row || isLocked(row)) return
    if (row.group === "tabs") hub.savePageSetting("tabs", row.key, !isOn(row))
    else hub.savePageSetting("local", row.key, !isOn(row))
  }

  implicitHeight: column.implicitHeight + Style.space(12) * 2
  height: implicitHeight
  focus: true

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) hub.close()
    else if (event.key === Qt.Key_Tab) hub.cyclePage(1)
    else if (event.key === Qt.Key_Backtab) hub.cyclePage(-1)
    else if (event.key === Qt.Key_Down || event.text === "j") cursor = Math.min(rows.length - 1, cursor + 1)
    else if (event.key === Qt.Key_Up || event.text === "k") cursor = Math.max(0, cursor - 1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) flip(rows[cursor])
    else return
    event.accepted = true
  }

  onVisibleChanged: if (visible) cursor = -1

  Column {
    id: column
    x: Style.space(12)
    y: Style.space(4)
    width: parent.width - Style.space(24)
    spacing: HubStyle.gap

    HubSection {
      width: parent.width
      title: "Tabs"
      foreground: root.foreground
      fontFamily: root.fontFamily

      Note { text: "Hidden tabs are not loaded, so they stop polling and leave the bar icon." }

      Repeater {
        model: root.rows.filter(function(row) { return row.group === "tabs" })
        delegate: SettingRow { required property var modelData; row: modelData }
      }
    }

    HubSection {
      width: parent.width
      title: "Local"
      foreground: root.foreground
      fontFamily: root.fontFamily

      Note { text: "Model servers shown on the Local tab, LM Studio above Ollama." }

      Repeater {
        model: root.rows.filter(function(row) { return row.group === "local" })
        delegate: SettingRow { required property var modelData; row: modelData }
      }
    }

    Note {
      horizontalAlignment: Text.AlignHCenter
      text: "Changes save automatically · ↑/↓ move · ↵ toggle · esc close"
    }
  }

  component Note: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: HubStyle.fsSmall
    wrapMode: Text.WordWrap
  }

  component SettingRow: Item {
    id: settingRow
    property var row: ({})
    readonly property int rowIndex: root.rows.findIndex(function(r) { return r.group === settingRow.row.group && r.key === settingRow.row.key })
    readonly property bool locked: root.isLocked(row)

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(label.implicitHeight, toggle.implicitHeight) + Style.space(4)

    Text {
      id: label
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.row.label + (settingRow.locked ? "  (last tab)" : "")
      color: root.foreground
      opacity: settingRow.locked ? 0.6 : 1
      font.family: root.fontFamily
      font.pixelSize: HubStyle.fsBody
    }

    // The switch does not flip itself: checked follows the saved setting,
    // and a click writes the opposite.
    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: root.isOn(settingRow.row)
      enabled: !settingRow.locked
      opacity: enabled ? 1 : 0.45
      hasCursor: root.cursor === settingRow.rowIndex
      foreground: root.foreground
      onHovered: function(on) { if (on) root.cursor = settingRow.rowIndex }
      onToggled: root.flip(settingRow.row)
    }
  }
}
