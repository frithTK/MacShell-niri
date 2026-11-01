import QtQuick
import QtQuick.Controls
import "Locale" as Language

Item {
    id: root
    required property var clock
    property bool darkMode: true
    readonly property var entries: {
        var source = clock && clock.snapshot && clock.snapshot.timing && clock.snapshot.timing.legacySnoozesRecovery;
        if (!source || typeof source.length !== "number") return [];
        var values = [];
        for (var i = 0; i < source.length; i++) values.push(source[i]);
        return values;
    }
    readonly property color foreground: darkMode ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: darkMode ? "#b6b6bb" : "#626269"
    readonly property color surface: darkMode ? "#303036" : "#f0f0f2"
    implicitHeight: content.implicitHeight
    visible: entries.length > 0

    function duration(ms) {
        var seconds = Math.ceil(Math.max(0, ms) / 1000);
        var minutes = Math.floor(seconds / 60), remainder = seconds % 60;
        return minutes + ":" + (remainder < 10 ? "0" : "") + remainder;
    }

    Column {
        id: content
        width: parent.width
        spacing: 12
        Text {
            width: parent.width; text: Language.I18n.text("clock.snooze_recovery_title")
            color: root.foreground; font.pixelSize: 19; font.weight: Font.DemiBold; wrapMode: Text.Wrap
        }
        Text {
            width: parent.width; text: Language.I18n.text("clock.snooze_recovery_description")
            color: root.secondary; font.pixelSize: 13; wrapMode: Text.Wrap
        }
        Repeater {
            model: root.entries
            delegate: Rectangle {
                id: row
                required property var modelData
                width: content.width; height: rowContent.implicitHeight + 24
                radius: 10; color: root.surface
                Column {
                    id: rowContent
                    x: 12; y: 12; width: parent.width - 24; spacing: 7
                    Text {
                        width: parent.width; text: row.modelData.label || Language.I18n.text("ui.t_f3b679573579")
                        color: root.foreground; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: Language.I18n.text("clock.snooze_recovery_saved", {
                            duration: root.duration(row.modelData.remainingMs),
                            date: Language.I18n.formatDateTime(new Date(row.modelData.capturedWallMs))
                        })
                        color: root.secondary; font.pixelSize: 12; wrapMode: Text.Wrap
                    }
                    Text {
                        visible: row.modelData.remainingMs === 0; width: parent.width
                        text: Language.I18n.text("clock.snooze_recovery_expired")
                        color: root.secondary; font.pixelSize: 12; wrapMode: Text.Wrap
                    }
                    Row {
                        spacing: 8
                        ClockRecoveryButton {
                            objectName: "snoozeResume-" + row.modelData.id
                            text: Language.I18n.text("clock.snooze_recovery_resume")
                            primary: true; darkMode: root.darkMode
                            enabled: !!root.clock && root.clock.ready && !root.clock.busy
                            onClicked: root.clock.submit("recover-snooze", {recoveryId: row.modelData.id, decision: "resume"})
                        }
                        ClockRecoveryButton {
                            objectName: "snoozeDiscard-" + row.modelData.id
                            text: Language.I18n.text("clock.snooze_recovery_discard")
                            darkMode: root.darkMode
                            enabled: !!root.clock && root.clock.ready && !root.clock.busy
                            onClicked: root.clock.submit("recover-snooze", {recoveryId: row.modelData.id, decision: "discard"})
                        }
                    }
                }
            }
        }
        Text {
            width: parent.width; visible: !!root.clock && !!root.clock.error && !root.clock.busy
            text: Language.I18n.text("clock.snooze_recovery_error")
            color: "#ff453a"; font.pixelSize: 12; wrapMode: Text.Wrap
        }
    }
}
