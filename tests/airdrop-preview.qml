import QtQuick
import Quickshell
import "../MacShell" as Port

ShellRoot {
    id: root
    readonly property bool blocked: Quickshell.env("MACSHELL_PREVIEW_BLOCKED") === "1"
    QtObject {
        id: demo
        property var state: ({configured: true, canStart: !root.blocked, mode: root.blocked ? "exclusive" : "shared", status: root.blocked ? "off" : "ready", notice: "", files: root.blocked ? [] : [{name: "Holiday photo.jpg", size: 2400000}], devices: root.blocked ? [] : [{key: "demo", name: "iPhone"}], pending: null, receiving: !root.blocked, scanning: false, transfer: "idle", progress: {sent: 0, total: 0}, results: [], folder: "Downloads/AirDrop"})
        property string receiverName: "MacShell"
        property string error: ""
        property bool active: !root.blocked
        property bool transferring: false
        property bool airplayBusy: false
        property string label: root.blocked ? "Unavailable" : "Everyone · 10 min"
        signal showRequested()
        function refresh() {}
        function stop() {}
        function start() {}
        function setFiles(paths) {}
        function sendFiles(key) {}
        function answer(key, accept) {}
        function cancel() {}
    }
    Port.AirDropWindow {
        id: window; controller: demo
        foreground: Quickshell.env("MACSHELL_PREVIEW_LIGHT") === "1" ? "#1d1d1f" : "#f5f5f7"
        visible: true
    }
    Timer {
        interval: 700; running: true
        onTriggered: window.contentItem.grabToImage(result => { result.saveToFile(Quickshell.env("MACSHELL_PREVIEW_CAPTURE")); Qt.quit(); })
    }
}
