import QtQuick
import QtQuick.Controls
import "Locale" as Language

Dialog {
    id: root
    required property var client
    property bool darkMode: true
    property string family: "Inter"
    property string soundId: ""
    property string kind: "timer"
    property var original: ({})
    property int volume: 90
    property int fadeSeconds: 0
    property int startSeconds: 0
    property int durationSeconds: 0
    property bool repeats: true
    readonly property color foreground: darkMode ? "#f5f5f7" : "#1d1d1f"
    readonly property color surface: darkMode ? "#2c2c2e" : "#ffffff"
    signal applied(var value)
    objectName: "clockSoundOptions"
    modal: true; width: 400; padding: 12
    anchors.centerIn: parent
    title: Language.I18n.text("clock.sound_options")
    palette.window: root.surface; palette.base: root.surface; palette.text: root.foreground; palette.buttonText: root.foreground
    palette.button: root.darkMode ? "#454548" : "#ededf0"; palette.highlight: "#0a84ff"
    function openFor(options, id, alertKind) {
        original = options || ({}); soundId = id || ""; kind = alertKind;
        client.soundError = "";
        volume = original.volume === undefined ? 90 : original.volume;
        fadeSeconds = Math.round((original.fadeMs || 0) / 1000);
        startSeconds = Math.round((original.startMs || 0) / 1000);
        durationSeconds = Math.round((original.durationMs || 0) / 1000);
        repeats = original.repeat === undefined ? true : original.repeat;
        open();
    }
    function value() {
        return Object.assign({}, original, {volume: volume, fadeMs: fadeSeconds * 1000,
            startMs: startSeconds * 1000, durationMs: durationSeconds * 1000, repeat: repeats});
    }
    onClosed: if (client) client.stopPreview()
    background: Rectangle { color: root.surface; radius: 10; border.color: root.darkMode ? "#606066" : "#d0d0d4" }
    header: Label { padding: 14; text: root.title; color: root.foreground; font.family: root.family; font.bold: true }
    contentItem: Column {
        spacing: 8
        Row {
            spacing: 8
            Label { width: 155; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("audio.volume"); color: root.foreground; font.family: root.family }
            Slider { id: volumeSlider; objectName: "clockSoundVolume"; width: 145; from: 0; to: 100; stepSize: 1; value: root.volume; onMoved: root.volume = Math.round(value); Accessible.name: Language.I18n.text("audio.volume") }
            Label { anchors.verticalCenter: parent.verticalCenter; text: root.volume + "%"; color: root.foreground }
        }
        Row {
            spacing: 8
            Label { width: 155; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_fade"); color: root.foreground; font.family: root.family }
            SpinBox { objectName: "clockSoundFade"; from: 0; to: 60; value: root.fadeSeconds; onValueModified: root.fadeSeconds = value; Accessible.name: Language.I18n.text("clock.sound_fade") }
            Label { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_seconds"); color: root.foreground }
        }
        Row {
            spacing: 8
            Label { width: 155; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_start"); color: root.foreground; font.family: root.family }
            SpinBox { objectName: "clockSoundStart"; from: 0; to: 600; value: root.startSeconds; onValueModified: root.startSeconds = value; Accessible.name: Language.I18n.text("clock.sound_start") }
            Label { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_seconds"); color: root.foreground }
        }
        Row {
            spacing: 8
            Label { width: 155; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_duration"); color: root.foreground; font.family: root.family }
            SpinBox { objectName: "clockSoundDuration"; from: 0; to: 600; value: root.durationSeconds; onValueModified: root.durationSeconds = value; Accessible.name: Language.I18n.text("clock.sound_duration") }
            Label { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("clock.sound_seconds"); color: root.foreground }
        }
        Label { width: parent.width; text: Language.I18n.text("clock.sound_duration_hint"); wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: 11 }
        CheckBox { objectName: "clockSoundRepeat"; text: Language.I18n.text("clock.sound_repeat"); checked: root.repeats; onToggled: root.repeats = checked; contentItem: Text { text: parent.text; leftPadding: parent.indicator.width + 8; verticalAlignment: Text.AlignVCenter; color: root.foreground } }
        Label { width: parent.width; visible: !!root.client.soundError; text: Language.I18n.text("clock.sound_error"); wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: 11 }
    }
    footer: Item {
        implicitHeight: 48
        Row {
            anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 8
            ControlButton { objectName: "clockSoundOptionsPreview"; text: Language.I18n.text(root.client.previewId ? "clock.sound_stop" : "clock.sound_preview"); onClicked: root.client.previewId ? root.client.stopPreview() : root.client.previewSound(root.soundId, root.value(), root.kind) }
            ControlButton { text: Language.I18n.text("common.cancel"); onClicked: root.close() }
            ControlButton { objectName: "clockSoundOptionsSave"; primary: true; text: Language.I18n.text("ui.t_1509f561f241"); onClicked: { root.applied(root.value()); root.close(); } }
        }
    }
}
