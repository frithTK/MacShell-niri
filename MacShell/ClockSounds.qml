import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import "Locale" as Language

Rectangle {
    id: root
    required property var client
    required property var importer
    property bool darkMode: true
    property string family: "Inter"
    property real availableHeight: 430
    signal dismissed()
    width: 480; height: Math.min(430, availableHeight); radius: 14
    color: darkMode ? "#2c2c2e" : "#ffffff"
    border.width: 1; border.color: darkMode ? "#555558" : "#d6d6da"
    property color foreground: darkMode ? "#f5f5f7" : "#1d1d1f"
    property color secondary: darkMode ? "#b0b0b5" : "#64646a"
    property color control: darkMode ? "#454548" : "#ededf0"
    readonly property var filtered: client.sounds.filter(sound => {
        var category = filters.currentIndex >= 0 ? filters.model[filters.currentIndex].key : "all";
        var matchesFilter = category === "all" || (category === "favorites" && sound.favorite === true) ||
                            (category === "custom" && sound.id.startsWith("user-")) || sound.category === category;
        return matchesFilter && displayName(sound).toLowerCase().indexOf(search.text.toLowerCase().trim()) >= 0;
    })
    function displayName(sound) {
        if (!sound.id || !sound.id.startsWith("builtin-")) return sound.name || "";
        var key = ({chime: "clock.sound_chime", melody: "clock.sound_melody", gentle: "clock.sound_gentle", urgent: "clock.sound_urgent"})[sound.category];
        return (key ? Language.I18n.text(key) : sound.name) + " " + Number(sound.id.slice(-2));
    }
    function displayDuration(ms) {
        if (typeof ms !== "number" || ms <= 0) return "";
        var seconds = Math.ceil(ms / 1000), minutes = Math.floor(seconds / 60);
        return minutes + ":" + String(seconds % 60).padStart(2, "0");
    }
    component SoundButton: ControlButton {
        palette.button: root.control; palette.buttonText: root.foreground
        palette.highlight: "#0a84ff"; font.family: root.family
    }
    Component.onCompleted: { client.refreshSounds(); importer.probeCodecs(); }
    Text { x: 16; y: 14; text: Language.I18n.text("clock.sound_library"); color: root.foreground; font.family: root.family; font.pixelSize: 16; font.weight: Font.DemiBold }
    SoundButton { anchors.right: parent.right; anchors.rightMargin: 12; y: 8; text: Language.I18n.text("common.done"); onClicked: root.dismissed() }
    TextField {
        id: search; objectName: "clockSoundSearch"
        x: 16; y: 51; width: parent.width - filters.width - 40; height: 34
        placeholderText: Language.I18n.text("clock.sound_search"); color: root.foreground; font.family: root.family
        background: Rectangle { radius: 7; color: root.control; border.color: search.activeFocus ? "#0a84ff" : "transparent" }
    }
    ControlComboBox {
        id: filters; objectName: "clockSoundFilter"
        anchors.right: parent.right; anchors.rightMargin: 16; y: 51; width: 170; height: 34
        palette.base: root.control; palette.buttonText: root.foreground; palette.text: root.foreground
        palette.window: root.color; palette.highlight: "#0a84ff"; font.family: root.family
        Accessible.name: Language.I18n.text("clock.sound_filter")
        textRole: "label"
        model: [{key: "all", label: Language.I18n.text("clock.sound_all")},
                {key: "favorites", label: Language.I18n.text("clock.sound_favorites")},
                {key: "custom", label: Language.I18n.text("clock.sound_custom")},
                {key: "chime", label: Language.I18n.text("clock.sound_chime")},
                {key: "melody", label: Language.I18n.text("clock.sound_melody")},
                {key: "gentle", label: Language.I18n.text("clock.sound_gentle")},
                {key: "urgent", label: Language.I18n.text("clock.sound_urgent")}]
    }
    ScrollView {
        id: scroll; x: 16; y: 92; width: parent.width - 32; height: Math.max(50, parent.height - 191)
        clip: true; contentWidth: availableWidth
        Column {
            width: scroll.availableWidth; spacing: 4
            Repeater {
                model: root.filtered
                delegate: Rectangle {
                    required property var modelData
                    width: scroll.availableWidth; height: 39; radius: 7; color: root.control
                    Text { x: 10; anchors.verticalCenter: parent.verticalCenter; width: favorite.x - 65; text: root.displayName(parent.modelData); textFormat: Text.PlainText; elide: Text.ElideRight; color: root.foreground; font.family: root.family; font.pixelSize: 13 }
                    Text { anchors.right: favorite.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: root.displayDuration(parent.modelData.durationMs); color: root.secondary; font.family: root.family; font.pixelSize: 11 }
                    SoundButton {
                        id: favorite; objectName: "clockSoundFavorite"; width: 36
                        anchors.right: play.left; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                        text: parent.modelData.favorite ? "★" : "☆"
                        Accessible.name: Language.I18n.text(parent.modelData.favorite ? "clock.sound_unfavorite" : "clock.sound_favorite") + ": " + root.displayName(parent.modelData)
                        enabled: root.client.ready
                        onClicked: root.client.favoriteSound(parent.modelData.id, !parent.modelData.favorite)
                    }
                    SoundButton {
                        id: play; objectName: "clockSoundPreview"; anchors.right: rename.visible ? rename.left : parent.right; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                        text: root.client.previewId === parent.modelData.id ? Language.I18n.text("clock.sound_stop") : Language.I18n.text("clock.sound_preview")
                        Accessible.name: text + ": " + root.displayName(parent.modelData)
                        enabled: root.client.ready
                        onClicked: root.client.previewId === parent.modelData.id ? root.client.stopPreview() : root.client.previewSound(parent.modelData.id)
                    }
                    SoundButton {
                        id: rename; objectName: "clockSoundRename"; width: 36
                        anchors.right: remove.left; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                        visible: remove.visible; enabled: root.client.ready && !root.importer.busy
                        text: "✎"; Accessible.name: Language.I18n.text("clock.sound_rename") + ": " + root.displayName(parent.modelData)
                        onClicked: { renameDialog.soundId = parent.modelData.id; renameInput.text = parent.modelData.name; renameDialog.open(); renameInput.forceActiveFocus(); renameInput.selectAll(); }
                    }
                    SoundButton {
                        id: remove; objectName: "clockSoundDelete"; width: 36
                        anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter
                        visible: parent.modelData.id.startsWith("user-"); enabled: root.client.ready && !root.importer.busy && !root.client.busy
                        text: "×"; Accessible.name: Language.I18n.text("clock.sound_delete") + ": " + root.displayName(parent.modelData)
                        onClicked: { confirm.soundId = parent.modelData.id; confirm.soundName = root.displayName(parent.modelData); confirm.open(); }
                    }
                }
            }
        }
    }
    Text {
        x: 16; anchors.bottom: status.top; anchors.bottomMargin: 3; width: parent.width - 32
        text: Language.I18n.text("clock.sound_library_help"); color: root.secondary; font.family: root.family; font.pixelSize: 12; elide: Text.ElideRight
    }
    Text {
        id: status
        x: 16; anchors.bottom: buttons.top; anchors.bottomMargin: 3; width: parent.width - 32
        height: implicitHeight; text: root.client.soundError === "Sound is in use" ? Language.I18n.text("clock.sound_in_use") :
                                   root.client.soundError === "Sound file cleanup failed" ? Language.I18n.text("clock.sound_cleanup_failed") :
                                   root.importer.error || root.client.soundError ? Language.I18n.text("clock.sound_error") :
                                   root.importer.cancelled ? Language.I18n.text("clock.sound_import_cancelled") :
                                   (root.importer.importedCount || root.importer.duplicateCount) ? Language.I18n.text("clock.sound_import_added") + " " + root.importer.importedCount + " · " + Language.I18n.text("clock.sound_import_duplicate") + " " + root.importer.duplicateCount : ""
        color: root.secondary; font.family: root.family; font.pixelSize: 12; elide: Text.ElideRight
    }
    Row {
        id: buttons; x: 16; anchors.bottom: parent.bottom; anchors.bottomMargin: 13; spacing: 8
        SoundButton {
            objectName: "clockSoundImport"; text: root.importer.busy ? Language.I18n.text("clock.sound_importing") : Language.I18n.text("clock.sound_import")
            enabled: !root.importer.busy; onClicked: picker.open()
        }
        SoundButton { objectName: "clockSoundCancelImport"; visible: root.importer.busy; text: Language.I18n.text("common.cancel"); onClicked: root.importer.cancel() }
        SoundButton {
            objectName: "clockSoundBuiltinVisibility"
            text: Language.I18n.text(root.client.showBuiltins ? "clock.sound_hide_builtin" : "clock.sound_show_builtin")
            enabled: root.client.ready && !root.importer.busy
            onClicked: root.client.setBuiltinsVisible(!root.client.showBuiltins)
        }
    }
    FileDialog {
        id: picker; objectName: "clockSoundFileDialog"; title: Language.I18n.text("clock.sound_import"); fileMode: FileDialog.OpenFiles
        nameFilters: [Language.I18n.text("clock.sound_files") + " (*.wav *.flac *.mp3 *.ogg" + (root.importer.aacSupported ? " *.m4a *.aac" : "") + ")"]
        onAccepted: root.importer.importFiles(selectedFiles)
    }
    Dialog {
        id: confirm; objectName: "clockSoundDeleteConfirmation"
        property string soundId: ""; property string soundName: ""
        parent: root; anchors.centerIn: parent; width: Math.min(400, root.width - 32); modal: true
        title: Language.I18n.text("clock.sound_delete_title")
        header: Label { padding: 14; text: confirm.title; color: root.foreground; font.family: root.family; font.bold: true }
        contentItem: Text {
            text: Language.I18n.text("clock.sound_delete_question") + "\n" + confirm.soundName
            textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.family: root.family
        }
        background: Rectangle { radius: 10; color: root.color; border.color: root.secondary }
        footer: Item {
            implicitHeight: 48
            Row {
                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                SoundButton { text: Language.I18n.text("common.cancel"); onClicked: confirm.close() }
                SoundButton { objectName: "clockSoundConfirmDelete"; text: Language.I18n.text("clock.sound_delete"); enabled: root.client.ready && !root.importer.busy && !root.client.busy; onClicked: { var id = confirm.soundId; confirm.close(); root.client.deleteSound(id); } }
            }
        }
    }
    Dialog {
        id: renameDialog; objectName: "clockSoundRenameDialog"
        property string soundId: ""
        parent: root; anchors.centerIn: parent; width: Math.min(400, root.width - 32); modal: true
        title: Language.I18n.text("clock.sound_rename")
        header: Label { padding: 14; text: renameDialog.title; color: root.foreground; font.family: root.family; font.bold: true }
        contentItem: TextField { id: renameInput; objectName: "clockSoundRenameInput"; maximumLength: 200; color: root.foreground; font.family: root.family; Accessible.name: Language.I18n.text("clock.sound_name"); background: Rectangle { radius: 7; color: root.control } }
        background: Rectangle { radius: 10; color: root.color; border.color: root.secondary }
        footer: Item {
            implicitHeight: 48
            Row {
                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                SoundButton { text: Language.I18n.text("common.cancel"); onClicked: renameDialog.close() }
                SoundButton { objectName: "clockSoundConfirmRename"; text: Language.I18n.text("ui.t_1509f561f241"); enabled: renameInput.text.trim() !== ""; onClicked: { var id = renameDialog.soundId, name = renameInput.text; renameDialog.close(); root.client.renameSound(id, name); } }
            }
        }
    }
}
