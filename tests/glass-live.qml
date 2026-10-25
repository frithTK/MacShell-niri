import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property int phase: 0
    FloatingWindow {
        title: "MacShell Glass Verification"
        implicitWidth: 1800; implicitHeight: 980
        color: root.phase === 0 ? "#1255ff" : "#e8357a"
        Repeater {
            model: 14
            Rectangle {
                required property int index
                x: index * 140; width: 34; height: parent.height
                color: index % 2 ? "#99ffcc" : "#ffffcc"; opacity: .55
            }
        }
        Text {
            anchors.centerIn: parent
            text: "MacShell · Live Glass\n" + (root.phase === 0 ? "BLUE" : "PINK")
            color: "white"; font.pixelSize: 48; horizontalAlignment: Text.AlignHCenter
        }
    }
    IpcHandler {
        target: "probe"
        function phase(value: int): void { root.phase = value; }
    }
}
