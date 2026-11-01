import QtQuick
import QtQuick.Controls
import "Locale" as Language

Item {
    id: root
    required property var backend
    property string kind: "timer"
    property bool darkMode: true
    property double wallNow: Date.now()
    readonly property var entry: backend && backend.timing ? backend.timing[kind] : null
    readonly property color foreground: darkMode ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: darkMode ? "#b6b6bb" : "#626269"
    implicitHeight: content.implicitHeight
    visible: !!entry && entry.state === "recovery"
    Timer { interval: 60000; repeat: true; running: root.visible; onTriggered: root.wallNow = Date.now() }

    function duration(ms) {
        var seconds = Math.ceil(Math.max(0, ms) / 1000);
        var hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds / 60) % 60, remainder = seconds % 60;
        var mm = (minutes < 10 ? "0" : "") + minutes, ss = (remainder < 10 ? "0" : "") + remainder;
        return hours ? hours + ":" + mm + ":" + ss : mm + ":" + ss;
    }
    function savedCaption() {
        if (!entry || typeof entry.checkpointWallMs !== "number" || !isFinite(entry.checkpointWallMs))
            return Language.I18n.text("clock.recovery_time_unknown");
        var date = Language.I18n.formatDateTime(new Date(entry.checkpointWallMs));
        var ageMs = wallNow - entry.checkpointWallMs;
        if (ageMs < 0) return Language.I18n.text("clock.recovery_clock_changed", {date: date});
        var minutes = Math.floor(ageMs / 60000);
        var age = minutes ? Language.I18n.plural("clock.minutes_count", minutes) : Language.I18n.text("clock.recovery_less_than_minute");
        return Language.I18n.text("clock.recovery_saved_at", {date: date, age: age});
    }
    function invoke(action) {
        if (!backend || !backend.ready || backend.busy) return;
        if (kind === "timer") backend.timerAction(action);
        else backend.stopwatchAction(action);
    }
    Column {
        id: content
        width: parent.width; spacing: 12
        Text {
            width: parent.width
            text: Language.I18n.text(root.kind === "timer" ? "clock.timer_recovery_title" : "clock.stopwatch_recovery_title")
            color: root.foreground; font.pixelSize: 20; font.weight: Font.DemiBold; wrapMode: Text.Wrap
        }
        Text {
            width: parent.width; text: Language.I18n.text("clock.recovery_explanation")
            color: root.secondary; font.pixelSize: 13; wrapMode: Text.Wrap
        }
        Text {
            width: parent.width
            text: Language.I18n.text("clock.recovery_saved_value", {duration: root.duration(root.entry ? (root.kind === "timer" ? root.entry.remainingCheckpointMs : root.entry.elapsedCheckpointMs) : 0)})
            color: root.foreground; font.pixelSize: 15; font.weight: Font.DemiBold; wrapMode: Text.Wrap
        }
        Text { width: parent.width; text: root.savedCaption(); color: root.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
        Flow {
            width: parent.width; spacing: 8
            ClockRecoveryButton {
                objectName: "clockRecoveryResume"
                text: Language.I18n.text("clock.recovery_resume")
                primary: true; darkMode: root.darkMode
                enabled: !!root.backend && root.backend.ready && !root.backend.busy
                onClicked: root.invoke(root.kind === "timer" ? "recover-remainder" : "recover-resume")
            }
            ClockRecoveryButton {
                objectName: "clockRecoveryRestart"
                text: Language.I18n.text(root.kind === "timer" ? "clock.recovery_restart" : "clock.recovery_reset")
                darkMode: root.darkMode
                enabled: !!root.backend && root.backend.ready && !root.backend.busy
                onClicked: root.invoke(root.kind === "timer" ? "recover-restart" : "reset")
            }
            ClockRecoveryButton {
                objectName: "clockRecoveryCancel"
                visible: root.kind === "timer"
                text: Language.I18n.text("common.cancel")
                darkMode: root.darkMode
                enabled: !!root.backend && root.backend.ready && !root.backend.busy
                onClicked: root.invoke("cancel")
            }
        }
    }
}
