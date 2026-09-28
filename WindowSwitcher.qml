import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

// macOS Cmd+Tab-style HUD. Purely a passive display: it doesn't grab
// keyboard focus (WlrKeyboardFocus.None) or run the actual switching logic
// itself — hypr-cycle-window.sh does the real work (cycling focus, moving
// workspaces) and writes this plugin's whole state to a JSON file on every
// Tab press. This file just watches that file and renders it.
Item {
  id: root

  property string home: Quickshell.env("HOME")
  property bool visiblePanel: false
  property var apps: []
  property int selected: 0

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  property int cellSize: Style.space(96)
  property int iconSize: Style.space(48)

  function applyState(raw) {
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      return
    }
    root.apps = parsed.apps || []
    root.selected = parsed.selected || 0
    root.visiblePanel = !!parsed.visible && root.apps.length > 0
    if (root.visiblePanel) watchdog.restart()
  }

  FileView {
    id: stateFile
    path: root.home + "/.local/state/omarchy/window-switcher/state.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.visiblePanel = false
  }

  // The HUD is meant to hide the instant Alt is released (see
  // hypr-cycle-window-end.sh, bound to Alt_L/Alt_R release). That binding
  // can miss its moment — e.g. a Hyprland config reload while Alt is held
  // resets the compositor's press-tracking, so the release event that
  // should fire the unbind script never comes — which would otherwise leave
  // this HUD stuck on screen indefinitely. This timer is the backstop: if
  // no Tab press refreshes the state file for a bit, hide regardless.
  Timer {
    id: watchdog
    interval: 2500
    onTriggered: root.visiblePanel = false
  }

  PanelWindow {
    id: panel
    visible: root.visiblePanel
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-window-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(root.apps.length * root.cellSize + Style.space(32), parent.width - Style.space(64))
      height: root.cellSize + Style.space(64)
      radius: root.cornerRadius
      color: root.background

      Row {
        anchors.centerIn: parent
        spacing: Style.space(8)

        Repeater {
          model: root.apps

          Rectangle {
            id: cell
            required property int index
            required property var modelData
            readonly property bool isSelected: index === root.selected

            width: root.cellSize
            height: root.cellSize
            radius: root.cornerRadius
            color: isSelected ? root.selectedBackground : "transparent"
            scale: isSelected ? 1.08 : 1.0

            Behavior on scale { NumberAnimation { duration: 90 } }
            Behavior on color { ColorAnimation { duration: 90 } }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.iconSize
                height: root.iconSize
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                asynchronous: true
                source: {
                  var name = cell.modelData.icon || ""
                  var themed = Quickshell.iconPath(name, true)
                  return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: cell.isSelected
                text: cell.modelData.class || ""
                color: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: root.cellSize
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }
    }
  }
}
