import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Locale" as Language
import "StickiesText.js" as StickiesText

Scope {
    id: root
    property var hub: null
    readonly property var tr: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color foreground: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: dark ? "#aaaab3" : "#686870"
    property bool closePending: false
    property alias controller: controller
    property alias window: win
    function open() { closePending = false; win.show(); win.raise(); win.requestActivate(); }
    function requestClose() {
        if (!controller.dirty && !controller.busy) { win.hide(); return; }
        closePending = true; controller.flush();
    }
    component NotesButton: Button {
        id: control
        implicitHeight: 32; implicitWidth: Math.max(36, label.implicitWidth + 24)
        font.family: root.family; font.pixelSize: 12
        contentItem: Text {
            id: label; text: control.text; color: root.foreground; opacity: control.enabled ? 1 : .45
            font: control.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 8; color: control.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : control.hovered ? (root.dark ? "#4c4c51" : "#eeeeef") : (root.dark ? "#3a3a3e" : "#ffffff")
            border.width: 1; border.color: control.activeFocus ? (root.dark ? "#e8c35e" : "#b28618") : (root.dark ? "#525257" : "#d0d0d5")
            opacity: control.enabled ? 1 : .5
        }
    }
    NotesController {
        id: controller
        enabled: win.visible || root.closePending || busy || dirty
        autoRefresh: win.visible
        sharedService: root.hub ? root.hub.notesService : null
        storePath: (Quickshell.env("MACSHELL_NOTES_DATA_HOME") || Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/macshell/notes/notes.sqlite3"
        onClean: if (root.closePending) { root.closePending = false; win.hide(); }
    }
    Window {
        id: win
        title: "Notes"; width: 940; height: 680; minimumWidth: 650; minimumHeight: 440
        visible: false; color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.requestClose(); }
        Rectangle { anchors.fill: parent; radius: 12; color: root.dark ? "#1c1c1e" : "#f7f7f8"; border.width: 1; border.color: root.dark ? "#49494f" : "#c8c8ce" }
        AppTitlebar {
            id: titlebar; x: 1; width: parent.width - 2
            window: win; dark: root.dark; family: root.family; title: root.tr.text("notes.title")
            controlObjectPrefix: "notesWindowControl_"
            closeLabel: root.tr.text("notes.close"); minimizeLabel: root.tr.text("notes.minimize"); maximizeLabel: root.tr.text("notes.maximize")
            onCloseRequested: root.requestClose()
        }
        Loader {
            anchors { left: parent.left; right: parent.right; top: titlebar.bottom; bottom: parent.bottom; margins: 1 }
            active: win.visible
            sourceComponent: RowLayout {
                spacing: 0
                Shortcut { sequence: "Ctrl+F"; enabled: win.visible && win.active; onActivated: { search.forceActiveFocus(); search.selectAll(); } }
                Rectangle {
                    Layout.fillHeight: true; Layout.preferredWidth: 255; color: root.dark ? "#29292c" : "#eeeeef"
                    Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: root.dark ? "#424245" : "#d4d4d8" }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 12; spacing: 9
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: root.tr.text("notes.title"); color: root.foreground; font.family: root.family; font.pixelSize: 21; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            NotesButton { objectName: "notesNew"; text: "+"; font.pixelSize: 19; Accessible.name: root.tr.text("notes.new"); enabled: controller.ready && !controller.busy && !controller.dirty; onClicked: controller.create() }
                        }
                        AppSearchField {
                            id: search; objectName: "notesSearch"; Layout.fillWidth: true; placeholderText: root.tr.text("notes.search")
                            dark: root.dark; font.family: root.family; Accessible.name: placeholderText
                        }
                        ListView {
                            id: list; objectName: "notesList"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                            model: controller.notes.filter(n => !search.text || n.body.toLocaleLowerCase().indexOf(search.text.toLocaleLowerCase()) >= 0)
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width; height: 68; radius: 9
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.body.split("\n")[0].trim() || root.tr.text("notes.untitled")
                                border.width: activeFocus ? 1 : 0; border.color: root.dark ? "#f5ce67" : "#9e7400"
                                Keys.onReturnPressed: if (!controller.busy && !controller.dirty) controller.select(modelData.id)
                                Keys.onSpacePressed: if (!controller.busy && !controller.dirty) controller.select(modelData.id)
                                color: controller.selectedId === modelData.id ? (root.dark ? "#5c5238" : "#f9e8b3") : noteMouse.containsMouse ? (root.dark ? "#353538" : "#e4e4e7") : "transparent"
                                Rectangle { x: 0; y: 12; width: 3; height: parent.height - 24; radius: 2; color: root.dark ? "#ffd05d" : "#c28b00"; visible: controller.selectedId === modelData.id }
                                Column {
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                                    spacing: 4
                                    Text { width: parent.width; text: modelData.body.split("\n")[0].trim() || root.tr.text("notes.untitled"); color: root.foreground; font.family: root.family; font.weight: Font.DemiBold; font.pixelSize: 13; elide: Text.ElideRight; textFormat: Text.PlainText }
                                    Text { width: parent.width; text: modelData.body.replace(/\n/g, " ").trim() || root.tr.text("notes.empty"); color: root.secondary; font.family: root.family; font.pixelSize: 11; elide: Text.ElideRight; textFormat: Text.PlainText }
                                }
                                MouseArea { id: noteMouse; anchors.fill: parent; hoverEnabled: true; enabled: !controller.busy && !controller.dirty; cursorShape: Qt.PointingHandCursor; onClicked: controller.select(parent.modelData.id) }
                            }
                            Text { anchors.centerIn: parent; visible: list.count === 0; width: parent.width - 20; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; text: root.tr.text("notes.no_notes"); color: root.secondary; font.family: root.family }
                        }
                        NotesButton {
                            objectName: "notesTrash"; Layout.fillWidth: true
                            text: root.tr.text("notes.recently_deleted") + (controller.deletedNotes.length ? " (" + controller.deletedNotes.length + ")" : "")
                            enabled: controller.ready && !controller.busy && !controller.dirty
                            onClicked: trashDialog.open()
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; color: "transparent"
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 16; spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; color: root.secondary; font.family: root.family; font.pixelSize: 12; text: !controller.ready ? root.tr.text("notes.unavailable") : controller.dirty || controller.busy ? root.tr.text("notes.saving") : root.tr.text("notes.saved") }
                            NotesButton { objectName: "notesUndoDelete"; visible: !!controller.deletedNote; text: root.tr.text("notes.undo_delete"); enabled: controller.ready && !controller.busy && !controller.dirty; onClicked: controller.undoDelete() }
                            AppIconButton { objectName: "notesPin"; visible: !!(root.hub && root.hub.stickies); glyph: "pin"; label: StickiesText.text(root.tr.activeLanguage, "pin"); dark: root.dark; enabled: !!controller.selectedId && controller.ready && !controller.busy && !controller.dirty; onClicked: root.hub.stickies.openNote(controller.selectedId) }
                            AppIconButton { objectName: "notesDelete"; glyph: "trash"; label: root.tr.text("notes.delete"); dark: root.dark; enabled: !!controller.selectedId && controller.ready && !controller.busy && !controller.dirty; onClicked: controller.remove() }
                        }
                        RowLayout {
                            visible: controller.error !== ""; Layout.fillWidth: true
                            Text { Layout.fillWidth: true; color: root.dark ? "#ffb3a8" : "#a32618"; text: root.tr.text("notes.save_error") + " " + controller.error; wrapMode: Text.Wrap; font.family: root.family; textFormat: Text.PlainText }
                            NotesButton { objectName: "notesSaveCopy"; visible: controller.dirty; text: root.tr.text("notes.save_copy"); enabled: controller.ready && !controller.busy; onClicked: controller.saveCopy() }
                            NotesButton { text: root.tr.text("notes.retry"); enabled: controller.ready && !controller.busy; onClicked: if (controller.dirty) controller.flush(); else controller.reload() }
                        }
                        ScrollView {
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                            TextArea {
                                objectName: "notesEditor"; text: controller.body; enabled: !!controller.selectedId
                                placeholderText: controller.selectedId ? root.tr.text("notes.write") : root.tr.text("notes.select")
                                wrapMode: TextEdit.Wrap; selectByMouse: true; color: root.foreground; font.family: root.family; font.pixelSize: 16
                                textFormat: TextEdit.PlainText
                                onTextChanged: if (text !== controller.body) controller.edit(text)
                                background: Rectangle { color: "transparent" }
                            }
                        }
                    }
                }
                Dialog {
                    id: trashDialog; objectName: "notesTrashDialog"; parent: Overlay.overlay
                    modal: true; anchors.centerIn: parent; implicitWidth: 460
                    closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        implicitWidth: 420; spacing: 12
                        Text { text: root.tr.text("notes.recently_deleted"); color: root.foreground; font.family: root.family; font.pixelSize: 17; font.weight: Font.DemiBold }
                        ListView {
                            id: deletedList; objectName: "notesDeletedList"; Layout.fillWidth: true; Layout.preferredHeight: 260; clip: true; spacing: 4
                            model: controller.deletedNotes
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width; height: 48; radius: 8; color: root.dark ? "#414146" : "#e1e1e6"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                                    Text { Layout.fillWidth: true; text: modelData.body.split("\n")[0].trim() || root.tr.text("notes.untitled"); color: root.foreground; font.family: root.family; elide: Text.ElideRight; textFormat: Text.PlainText }
                                    NotesButton { objectName: "notesRestore_" + modelData.id; text: root.tr.text("notes.restore"); enabled: controller.ready && !controller.busy && !controller.dirty; onClicked: controller.restore(modelData) }
                                }
                            }
                            Text { anchors.centerIn: parent; visible: deletedList.count === 0; text: root.tr.text("notes.deleted_empty"); color: root.secondary; font.family: root.family }
                        }
                        Text { Layout.fillWidth: true; visible: !!controller.error; text: controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        NotesButton { objectName: "notesTrashDone"; Layout.alignment: Qt.AlignRight; text: root.tr.text("notes.done"); enabled: !controller.busy; onClicked: trashDialog.close() }
                    }
                }
            }
        }
        MouseArea { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 10; height: 10; cursorShape: Qt.SizeFDiagCursor; onPressed: win.startSystemResize(Qt.RightEdge | Qt.BottomEdge) }
        Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: root.requestClose() }
        Shortcut { sequence: "Ctrl+N"; enabled: win.visible && win.active && controller.ready && !controller.busy && !controller.dirty; onActivated: controller.create() }
    }
}
