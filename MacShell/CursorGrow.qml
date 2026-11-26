import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "CursorGrow.js" as Grow

// A fast circle makes the pointer large for a moment, so it can be found on a big screen.
Scope {
    id: root
    property var samples: []
    property real pointerX: 0
    property real pointerY: 0
    property real grow: 1
    property string image: ""
    property real hotX: 4
    property real hotY: 2
    property real sourceSize: 24
    property real nominal: 24

    function scriptPath() {
        var path = Qt.resolvedUrl("cursor-pointer.sh").toString()
        return decodeURIComponent(path.replace(/^file:\/\//, ""))
    }

    function ingest(line) {
        var text = ("" + line).trim()
        if (text.indexOf("image ") === 0) {
            var parts = text.split(" ")
            if (parts.length < 6) return
            root.image = parts[1] === "-" ? "" : parts[1]
            root.hotX = parseFloat(parts[2]) || 0
            root.hotY = parseFloat(parts[3]) || 0
            root.sourceSize = parseFloat(parts[4]) || 24
            root.nominal = parseFloat(parts[5]) || 24
            return
        }
        if (text.indexOf("move ") !== 0) return
        var point = text.split(" ")
        var x = parseFloat(point[1])
        var y = parseFloat(point[2])
        if (isNaN(x) || isNaN(y)) return
        root.pointerX = x
        root.pointerY = y
        var step = Grow.sample(root.samples, Date.now(), x, y)
        root.samples = step.samples
        if (step.spin) {
            root.grow = 4
            hold.restart()
        }
    }

    Timer {
        id: hold
        interval: 560
        onTriggered: root.grow = 1
    }
    Behavior on grow { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Process {
        id: watch
        running: true
        command: ["sh", root.scriptPath()]
        stdout: SplitParser { onRead: data => root.ingest(data) }
        stderr: SplitParser { onRead: data => { var t = ("" + data).trim(); if (t !== "") console.log("cursor-grow:", t) } }
        onExited: retry.restart()
    }
    Timer {
        id: retry
        interval: 4000
        onTriggered: if (!watch.running) watch.running = true
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: growWindow
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            visible: root.grow > 1.05
            mask: Region {}
            WlrLayershell.namespace: "macshell-cursor"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            readonly property real side: root.nominal * root.grow
            readonly property real factor: root.sourceSize > 0 ? side / root.sourceSize : 1
            Image {
                source: root.image !== "" ? "file://" + root.image : Qt.resolvedUrl("assets/cursor-grow.svg")
                x: root.pointerX - growWindow.modelData.x - root.hotX * growWindow.factor
                y: root.pointerY - growWindow.modelData.y - root.hotY * growWindow.factor
                width: growWindow.side
                height: growWindow.side
                smooth: true
                mipmap: true
                asynchronous: true
                fillMode: Image.PreserveAspectFit
            }
        }
    }
}
