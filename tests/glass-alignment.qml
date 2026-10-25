import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property int phase: 0
    FloatingWindow {
        title: "MacShell Glass Alignment"
        implicitWidth: 1900; implicitHeight: 1040
        Canvas {
            id: grid
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections { target: root; function onPhaseChanged() { grid.requestPaint(); } }
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                for (var y = 0; y < height; y += 48) {
                    for (var x = 0; x < width; x += 48) {
                        ctx.fillStyle = root.phase ? "#e8357a" : Qt.hsla(x / Math.max(1, width), .75, (Math.floor(x / 48) + Math.floor(y / 48)) % 2 ? .5 : .3, 1);
                        ctx.fillRect(x, y, 48, 48);
                    }
                }
            }
        }
        Text { anchors.centerIn: parent; text: "Glass alignment · 48 px grid"; color: "white"; font.pixelSize: 36 }
    }
    IpcHandler {
        target: "probe"
        function phase(value: int): void { root.phase = value; }
    }
}
