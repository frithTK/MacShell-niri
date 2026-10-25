import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port

ShellRoot {
    QtObject {
        id: measurements
        property bool stale: false
        property string error: ""
        property var sample: history[history.length - 1]
        property var history: {
            var result = [];
            for (var i = 0; i <= 60; i++) result.push({time: i, gap: false, cpu: Math.round((20 + Math.sin(i / 8) * 10) * 10) / 10,
                memory: {used: 8 * 1073741824, total: 16 * 1073741824, swapUsed: 0}, cores: {}, temperature: 48,
                interface: "eth0", network: [700000 + Math.sin(i / 5) * 100000, 240000],
                device: "nvme0n1p2", disk: [i < 30 ? 0 : 1000000 + Math.sin(i / 7) * 400000, 2200000 + Math.sin(i / 4) * 1800000],
                diskLabel: "Root filesystem block layer", capacity: {free: 120 * 1073741824}});
            return result;
        }
        function gib(value) { return ((value || 0) / 1073741824).toFixed(1); }
        function rate(value) { return value == null ? "—" : value >= 1000000 ? (value / 1000000).toFixed(1) + "M" : value >= 1000 ? (value / 1000).toFixed(0) + "K" : value.toFixed(0) + "B"; }
    }
    Window {
        id: win
        readonly property bool dark: Quickshell.env("MACSHELL_STATS_PREVIEW_LIGHT") !== "1"
        width: 440; height: 560; visible: true; color: dark ? "#24252b" : "#fafafb"
        Rectangle { anchors.fill: parent; color: win.color }
        Port.SystemStatsMenu { anchors.fill: parent; anchors.margins: 20; controller: measurements; foreground: win.dark ? "#f5f5f7" : "#1d1d1f" }
        Timer {
            interval: 700; running: true
            onTriggered: win.contentItem.grabToImage(result => { result.saveToFile(Quickshell.env("MACSHELL_STATS_PREVIEW_CAPTURE")); Qt.quit(); })
        }
    }
}
