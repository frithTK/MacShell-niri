import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port

ShellRoot {
    id: root
    readonly property string scenario: Quickshell.env("MACSHELL_BATTERIES_SCENARIO") || "none"
    property bool mounted: true
    property int charge: 84
    Timer { interval: 100; running: root.scenario === "removed"; onTriggered: root.mounted = false }
    // Deterministic changes stress the view without querying devices or scanning.
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.charge = (root.charge + 1) % 101 }
    QtObject { id: laptop; readonly property var widgetData: ({present: true, ready: true, percentage: root.charge, charging: true}) }
    QtObject {
        id: bluetooth
        property bool stateReady: true
        property bool available: true
        property bool enabled: true
        property var devices: [
            {address: "AA:00:00:00:00:01", name: "Headphones", icon: "audio-headphones", connected: true, adapterEnabled: true, battery: 67},
            {address: "AA:00:00:00:00:02", name: "Mouse", icon: "input-mouse", connected: true, adapterEnabled: true, battery: 0},
            {address: "AA:00:00:00:00:03", name: "Keyboard", icon: "input-keyboard", connected: true, adapterEnabled: true, battery: 100},
            {address: "AA:00:00:00:00:04", name: "Speaker", icon: "audio-card", connected: true, adapterEnabled: true, battery: -1},
            {address: "AA:00:00:00:00:05", name: "Controller", icon: "input-gaming", connected: true, adapterEnabled: true, battery: 42}
        ]
    }
    Port.BatteriesModel {
        id: source; battery: laptop; bluetooth: bluetooth
        active: root.mounted && (root.scenario === "widgets" || root.scenario === "removed")
    }
    Window {
        width: 820; height: 1070; visible: true
        Rectangle { anchors.fill: parent; color: "#202128" }
        Text { x: 20; y: 4; text: "Batteries · shared data"; color: "white"; font.family: "Inter Variable"; font.pixelSize: 14 }
        Port.CalendarWidget { x: 20; y: 30; width: 185; height: 185; style: "normal"; fam: "Inter Variable"; preview: true; now: new Date(2026, 9, 26) }
        Repeater {
            model: root.mounted && root.scenario !== "none" ? 4 : 0
            Port.BatteriesWidget {
                required property int index
                x: 20 + index % 2 * 395; y: 240 + Math.floor(index / 2) * 395
                size: "large"; style: "normal"; entries: source.entries
                visible: root.scenario !== "hidden"
            }
        }
    }
}
