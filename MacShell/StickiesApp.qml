import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Locale" as Language
import "StickiesText.js" as Texts

Scope {
    id: root
    property var hub: null
    readonly property var translations: hub && hub.translations ? hub.translations : Language.I18n
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property string storePath: (Quickshell.env("MACSHELL_NOTES_DATA_HOME") || Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/macshell/notes/notes.sqlite3"
    property var windows: []
    property var floated: ({})
    function tr(key) { return Texts.text(translations.activeLanguage, key); }
    function open() { createWindow(""); }
    function openNote(id) {
        if (!id) return;
        var found = windows.find(window => window.noteId === id);
        if (found) { found.show(); found.raise(); found.requestActivate(); }
        else createWindow(id);
    }
    function createWindow(id) {
        var item = stickyWindow.createObject(root, {noteId: id || "", createNew: !id});
        if (item) { windows = windows.concat([item]); item.show(); item.raise(); item.requestActivate(); }
    }
    function release(window) {
        windows = windows.filter(item => item !== window);
        if (!windows.length) floated = ({});
        window.destroy();
    }
    function floatNewWindows() {
        if (!windows.length) return;
        var seen = Object.assign({}, floated), changed = false;
        for (var window of Niri.toplevels.values) {
            if (window.title !== "Stickies" || Number(window.data.pid) !== Quickshell.processId || seen[window.id]) continue;
            seen[window.id] = true; changed = true;
            if (!window.data.floating) Niri.action(["move-window-to-floating", "--id", String(window.id)]);
        }
        if (changed) floated = seen;
    }
    Connections { target: Niri; function onUpdated() { root.floatNewWindows(); } }
    Component {
        id: stickyWindow
        Window {
            id: win
            property string noteId: ""
            property bool createNew: false
            property bool closePending: false
            readonly property alias controller: controller
            title: "Stickies"; width: 340; height: 300; minimumWidth: 260; minimumHeight: 200
            color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
            function requestClose() {
                if (!controller.dirty && !controller.busy) { finishClose(); return; }
                closePending = true; controller.flush();
            }
            function finishClose() { hide(); Qt.callLater(() => root.release(win)); }
            onClosing: close => { close.accepted = false; requestClose(); }
            NotesController {
                id: controller
                storePath: root.storePath
                sharedService: root.hub ? root.hub.notesService : null
                enabled: win.visible || win.closePending || busy || dirty
                autoRefresh: true; selectFirst: false; initialId: win.noteId
                onSelectedIdChanged: if (selectedId) { win.noteId = selectedId; win.createNew = false; }
                onClean: {
                    if (win.closePending && !dirty && !busy) { win.closePending = false; win.finishClose(); }
                    else if (win.createNew && !selectedId && !busy && ready && error === "") create();
                }
            }
            Rectangle { anchors.fill: parent; radius: 12; color: "#fff1ad"; border.width: 1; border.color: "#c9ad61" }
            AppTitlebar {
                id: toolbar; x: 1; width: parent.width - 2
                window: win; dark: false; barColor: "#efd984"; titleColor: "#574b22"; family: root.family
                title: root.tr("title"); closeLabel: root.tr("close"); minimizeLabel: root.tr("minimize"); maximizeLabel: root.tr("maximize")
                controlObjectPrefix: "stickyWindowControl_"
                onCloseRequested: win.requestClose()
            }
            ColumnLayout {
                anchors { top: toolbar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    Text { Layout.fillWidth: true; text: !controller.ready ? root.tr("unavailable") : controller.busy || controller.dirty ? root.tr("saving") : root.tr("saved"); color: "#756737"; font.family: root.family; font.pixelSize: 11; elide: Text.ElideRight }
                    AppIconButton { objectName: "stickyNew"; glyph: "plus"; label: root.tr("newNote"); dark: false; iconColor: "#6e5d27"; implicitWidth: 32; implicitHeight: 28; onClicked: root.open() }
                }
                RowLayout {
                    visible: controller.error !== ""; Layout.fillWidth: true
                    Text { Layout.fillWidth: true; text: controller.error === "Note no longer exists." ? root.tr("cannotOpen") : controller.error; color: "#8e2c20"; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    ControlButton { objectName: "stickySaveCopy"; visible: controller.dirty; text: root.tr("saveCopy"); palette.button: "#ead899"; palette.buttonText: "#42391b"; enabled: controller.ready && !controller.busy; onClicked: controller.saveCopy() }
                    ControlButton { visible: !controller.dirty && controller.ready; text: root.tr("retry"); palette.button: "#ead899"; palette.buttonText: "#42391b"; enabled: !controller.busy; onClicked: controller.reload() }
                }
                ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                    TextArea {
                        objectName: "stickyEditor"; text: controller.body; enabled: !!controller.selectedId
                        placeholderText: root.tr("placeholder"); color: "#302b1b"; placeholderTextColor: "#958456"
                        font.family: root.family; font.pixelSize: 16; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                        onTextChanged: if (text !== controller.body) controller.edit(text)
                        background: Rectangle { color: "transparent" }
                    }
                }
            }
            MouseArea { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 10; height: 10; cursorShape: Qt.SizeFDiagCursor; onPressed: win.startSystemResize(Qt.RightEdge | Qt.BottomEdge) }
            Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: win.requestClose() }
            Shortcut { sequence: "Ctrl+N"; enabled: win.visible && win.active; onActivated: root.open() }
        }
    }
}
