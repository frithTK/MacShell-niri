import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port

ShellRoot {
    id: root
    readonly property string scenario: Quickshell.env("MACSHELL_ACTIVITY_SCENARIO") || "none"
    property bool mounted: true
    Timer { interval: 100; running: root.scenario === "removed"; onTriggered: root.mounted = false }
    Port.SystemStats { id: stats; enabled: scenario === "sampler" || scenario === "widgets" }
    Window {
        width: 820; height: 1070; visible: true
        Rectangle { anchors.fill: parent; color: "#202128" }
        Text { x: 20; y: 4; text: "Activity · shared sampler"; color: "white"; font.family: "Inter Variable"; font.pixelSize: 14 }
        // The existing desktop already has widget effects, text and card material.
        // Keep this card in every phase to measure Activity's incremental cost.
        Port.CalendarWidget { x: 20; y: 30; width: 185; height: 185; style: "normal"; fam: "Inter Variable"; preview: true; now: new Date(2026, 9, 26) }
        Repeater {
            model: root.mounted && scenario !== "none" && scenario !== "sampler" ? 4 : 0
            Port.ActivityWidget {
                required property int index
                x: 20 + index % 2 * 395; y: 240 + Math.floor(index / 2) * 395
                size: "large"; style: "normal"; settings: ({view: index % 2 ? "graphs" : "rings"})
                sample: stats.sample; history: stats.history; stale: stats.stale
                visible: scenario !== "hidden"
            }
        }
    }
}
