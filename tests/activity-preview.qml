import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 800; height: 558; visible: true
    readonly property bool dark: Qt.application.arguments.indexOf("--light") < 0
    readonly property color foreground: dark ? "#f7f7fa" : "#1d1d1f"
    color: dark ? "#16171b" : "#e9eaee"
    component Measurements: QtObject {
        property var sample
        property bool stale: false
        function gib(v) { return (v / 1073741824).toFixed(1); }
        function rate(v) {
            if (v === null || v === undefined) return "—";
            return v >= 1000000 ? (v / 1000000).toFixed(1) + "M" : v >= 1000 ? (v / 1000).toFixed(0) + "K" : v + "B";
        }
    }
    function measurements(cpu, memory, network, disk) {
        return {cpu: cpu, memory: {used: memory, total: 100}, network: network, disk: disk};
    }
    Measurements { id: everyday; sample: window.measurements(24, 50, [428000, 72000], [2400000, 120000]) }
    Measurements { id: busy; sample: window.measurements(78, 83, [20000000, 4000000], [160000000, 20000000]) }
    Measurements { id: high; sample: window.measurements(96, 94, [60000000, 24000000], [400000000, 100000000]) }
    Measurements { id: waiting; sample: everyday.sample; stale: true }
    Rectangle { anchors.fill: parent; color: window.color }
    Text {
        x: 28; y: 24; text: "Activity · menu bar"
        color: window.foreground; font.pixelSize: 25; font.weight: Font.DemiBold
    }
    Text {
        x: 28; y: 62; text: "Native icons, live color and a quiet activity indicator · demonstration data"
        color: window.foreground; opacity: .55; font.pixelSize: 12
    }
    Column {
        x: 28; y: 102; width: 744; spacing: 17
        Repeater {
            model: [
                {label: "Everyday · CPU 24% · Memory 50%", source: everyday, budget: 120},
                {label: "Busy · CPU 78% · Memory 83%", source: busy, budget: 120},
                {label: "High load · CPU 96% · Memory 94%", source: high, budget: 120},
                {label: "Waiting for fresh data", source: waiting, budget: 120},
                {label: "Less space · compact spacing", source: everyday, budget: 92},
                {label: "Full menu bar · combined Activity icon", source: high, budget: 26}
            ]
            delegate: Column {
                required property var modelData
                width: 744; spacing: 6
                Text { text: modelData.label; color: window.foreground; opacity: .6; font.pixelSize: 11 }
                Rectangle {
                    width: parent.width; height: 32; radius: 8
                    color: window.dark ? "#2a2b30" : "#fafafb"
                    border.color: window.dark ? "#3b3c42" : "#d8d9df"
                    Text {
                        x: 12; anchors.verticalCenter: parent.verticalCenter
                        text: "MacShell"; color: window.foreground; font.pixelSize: 12; font.weight: Font.DemiBold
                    }
                    Text {
                        x: 91; anchors.verticalCenter: parent.verticalCenter
                        text: "File    Edit    View"; color: window.foreground; opacity: .6; font.pixelSize: 12
                    }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Port.SystemStatsBar { controller: modelData.source; foreground: window.foreground; budget: modelData.budget }
                        Port.ShellGlyph { anchors.verticalCenter: parent.verticalCenter; kind: "wifi"; color: window.foreground }
                        Port.ShellGlyph { anchors.verticalCenter: parent.verticalCenter; kind: "speaker"; color: window.foreground }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "9:41"; color: window.foreground; font.pixelSize: 12 }
                    }
                }
            }
        }
    }
    Text {
        x: 28; y: 527; text: "Hover for exact values · Click for graphs · Network and disk color shows activity"
        color: window.foreground; opacity: .5; font.pixelSize: 11
    }
    Timer {
        interval: 600; running: true
        onTriggered: window.contentItem.grabToImage(result => {
            var target = Qt.application.arguments.filter(arg => arg.indexOf("--capture=") === 0)[0];
            result.saveToFile(target ? target.slice(10) : "/tmp/macshell-activity-" + (window.dark ? "dark" : "light") + ".png");
            Qt.quit();
        })
    }
}
