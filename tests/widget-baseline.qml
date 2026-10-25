import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 850; height: 240; visible: true
    color: "#1e1e1e"
    readonly property string scenario: {
        var args = Qt.application.arguments, index = args.indexOf("--scenario");
        return index >= 0 ? args[index + 1] : "none";
    }
    Loader {
        id: widgets
        x: 15; y: 15
        active: window.scenario !== "none"
        visible: window.scenario !== "fullscreen"
        sourceComponent: Row {
            spacing: 15
            Port.WeatherWidget { style: "normal"; size: "small"; hasData: true; city: "Demo"; temp: 18; cond: "Cloudy"; kind: "cloud" }
            Port.CalendarWidget { style: "normal"; mode: "dark"; size: "small" }
            Port.ClockWidget { style: "dark"; size: "small" }
            Port.PlayerWidget { style: "dark"; size: "small"; preview: true }
        }
    }
    Timer { interval: 1000; running: window.scenario === "removed"; onTriggered: widgets.active = false }
}
