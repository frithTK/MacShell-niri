import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property bool passed: false
    Component.onCompleted: { Port.Niri.windowMap = {"1": {id: 1}}; }
    Image {
        id: image
        source: Port.NiriCapture.frames["1"] ? Port.NiriCapture.frames["1"].url : ""
        asynchronous: true
        onStatusChanged: if (status === Image.Ready) { root.passed = true; console.log("CAPTURE_RUST_QML_PASS"); Qt.exit(0); }
    }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: Port.NiriCapture.request({id: 1})
    }
    Timer { interval: 9000; running: true; onTriggered: if (!root.passed) { console.error("CAPTURE_RUST_QML_FAIL"); Qt.exit(1); } }
}
