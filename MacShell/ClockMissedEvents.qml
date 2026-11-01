import QtQuick
import "Locale" as Language

Item {
    id: root
    required property var backend
    property bool darkMode: true
    readonly property color foreground: darkMode ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: darkMode ? "#b6b6bb" : "#626269"
    readonly property color surface: darkMode ? "#303036" : "#f0f0f2"
    readonly property var entries: {
        var timing = backend && backend.timing, values = [];
        if (!timing) return values;
        var alarms = timing.missedAlarms || [], snoozes = timing.missedSnoozes || [];
        for (var i = 0; i < alarms.length; i++) values.push({kind: "alarm", id: alarms[i].eventId, label: alarms[i].label});
        for (var j = 0; j < snoozes.length; j++) values.push({kind: "snooze", id: snoozes[j].id, label: snoozes[j].label});
        return values;
    }
    visible: entries.length > 0
    implicitHeight: visible ? content.implicitHeight + 12 : 0
    Column {
        id: content
        width: parent.width; spacing: 8
        Text { width: parent.width; text: Language.I18n.text("clock.missed_title"); color: root.foreground; font.pixelSize: 16; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        Repeater {
            model: root.entries
            delegate: Rectangle {
                id: row
                required property var modelData
                width: content.width; height: rowContent.implicitHeight + 20; radius: 10; color: root.surface
                Column {
                    id: rowContent
                    x: 10; y: 10; width: parent.width - 20; spacing: 6
                    Text { width: parent.width; text: row.modelData.label || Language.I18n.text("ui.t_f3b679573579"); color: root.foreground; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight }
                    Text { width: parent.width; text: Language.I18n.text(row.modelData.kind === "alarm" ? "clock.missed_alarm" : "clock.missed_snooze"); color: root.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
                    ClockRecoveryButton {
                        objectName: "clockMissedDismiss-" + row.modelData.id
                        text: Language.I18n.text("clock.missed_dismiss"); darkMode: root.darkMode
                        enabled: !!root.backend && root.backend.ready && !root.backend.busy
                        onClicked: root.backend.submit("ack-missed", {kind: row.modelData.kind, eventId: row.modelData.id})
                    }
                }
            }
        }
    }
}
