import QtQuick
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property color accent: t ? t.accent : "#0a84ff"
    readonly property color secondSeries: dark ? "#b5a0f4" : "#7144aa"
    signal settingsRequested()
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: "Activity"; foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; text: root.controller.stale ? "Waiting for fresh data…" : "Last 60 seconds · one selected interface and block device"; color: root.foreground; opacity: .6; font.pixelSize: 10; width: parent.width; wrapMode: Text.Wrap }
        Repeater {
            model: ["CPU", "Memory", "Network", "Disk"]
            delegate: Column {
                required property string modelData
                width: root.width; spacing: 4
                readonly property var s: root.controller.sample
                Text { font.family: root.font.family;
                    width: parent.width; color: root.foreground; font.pixelSize: 12
                    text: modelData === "CPU" ? "CPU   " + (s.cpu === null || s.cpu === undefined ? "—" : s.cpu + "%") + (s.temperature ? " · " + s.temperature + " °C" : "")
                        : modelData === "Memory" ? "Memory   " + root.controller.gib(s.memory && s.memory.used) + " / " + root.controller.gib(s.memory && s.memory.total) + " GiB"
                        : modelData === "Network" ? "Network · " + (s.interface || "No interface") + "   ↓ " + root.controller.rate(s.network && s.network[0]) + "/s   ↑ " + root.controller.rate(s.network && s.network[1]) + "/s"
                        : "Disk · " + (s.device || "Select device") + "   R " + root.controller.rate(s.disk && s.disk[0]) + "/s   W " + root.controller.rate(s.disk && s.disk[1]) + "/s"
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                }
                Row {
                    spacing: 12; visible: modelData === "Disk" || modelData === "Network"
                    Text { text: modelData === "Disk" ? "Read" : "Download"; color: root.accent; font.family: root.font.family; font.pixelSize: 10 }
                    Text { text: modelData === "Disk" ? "Write" : "Upload"; color: root.secondSeries; font.family: root.font.family; font.pixelSize: 10 }
                }
                StatsGraph {
                    objectName: "statsGraph_" + modelData.toLowerCase()
                    width: parent.width; height: 34
                    history: root.controller.history; metric: modelData.toLowerCase()
                    primaryColor: root.accent; secondaryColor: root.secondSeries
                }
            }
        }
        Text { font.family: root.font.family;
            width: parent.width; wrapMode: Text.Wrap; color: root.foreground; opacity: .6; font.pixelSize: 10
            text: "Swap: " + root.controller.gib(controller.sample.memory && controller.sample.memory.swapUsed) + " GiB · Root free: " + root.controller.gib(controller.sample.capacity && controller.sample.capacity.free) + " GiB\n" + (controller.sample.diskLabel || "") + "\nRates: decimal B/s, K = kB/s, M = MB/s. Memory: GiB."
        }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: root.foreground; opacity: .6; font.pixelSize: 10; text: Object.keys(controller.sample.cores || {}).map(k => k + " " + (controller.sample.cores[k] === null ? "—" : controller.sample.cores[k] + "%")).join("   ") }
        ControlButton { text: "Monitoring settings"; onClicked: root.settingsRequested() }
    }
}
