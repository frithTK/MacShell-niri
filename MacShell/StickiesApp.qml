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
    property int serial: 0
    property bool restorePending: !!hub
    property bool sessionDirty: false
    property int sessionRequest: 0
    property string sessionAction: ""
    readonly property bool sessionEnabled: !!hub && (restorePending || sessionDirty || sessionRequest !== 0)
    function tr(key) { return Texts.text(translations.activeLanguage, key); }
    function open() { createWindow(""); }
    function openNote(id) {
        if (!id) return;
        var found = windows.find(window => window.noteId === id);
        if (found) { found.show(); found.raise(); found.requestActivate(); }
        else createWindow(id);
    }
    function createWindow(id, saved, restoring) {
        var item = stickyWindow.createObject(root, {noteId: id || "", createNew: !id,
            savedGeometry: saved || {}, mappingTitle: "Stickies [" + (++serial) + "]"});
        if (item) {
            windows = windows.concat([item]); item.show();
            if (!restoring) { item.raise(); item.requestActivate(); }
            scheduleSave();
        }
    }
    function release(window) {
        scheduleSave();
        windows = windows.filter(item => item !== window);
        window.destroy();
    }
    function scheduleSave() {
        if (!hub) return;
        sessionDirty = true;
        saveDelay.restart();
    }
    function sendSession() {
        if (!hub || !hub.notesService || !hub.notesService.ready || sessionRequest) return;
        if (restorePending) {
            sessionAction = "list-stickies";
            sessionRequest = hub.notesService.send(sessionAction, {});
        } else if (sessionDirty) {
            if (windows.some(w => w.createNew && !w.noteId)) return;
            var entries = windows.filter(w => !!w.noteId).map(w => Object.assign({}, w.savedGeometry, {id: w.noteId}));
            sessionAction = "save-stickies";
            sessionRequest = hub.notesService.send(sessionAction, {windows: entries});
            if (sessionRequest > 0) sessionDirty = false;
        }
        if (sessionRequest < 0) { sessionRequest = 0; sessionDirty = true; }
    }
    Timer { id: saveDelay; interval: 350; onTriggered: root.sendSession() }
    Connections {
        target: root.hub ? root.hub.notesService : null
        function onConnected() { root.sessionRequest = 0; root.sendSession(); }
        function onReadyChanged() { if (!root.hub.notesService.ready && root.sessionRequest) { root.sessionRequest = 0; root.sessionDirty = true; } }
        function onReceived(message) {
            if (message.type !== "result" || !root.sessionRequest || message.id !== root.sessionRequest) return;
            var action = root.sessionAction; root.sessionRequest = 0;
            if (!message.success) {
                console.warn("[Stickies] " + (message.error || "Could not save window layout"));
                if (action === "save-stickies") { root.sessionDirty = true; saveRetry.restart(); }
                return;
            }
            if (action === "list-stickies") {
                for (var entry of message.result || [])
                    if (!root.windows.some(w => w.noteId === entry.id)) root.createWindow(entry.id, entry, true);
                root.restorePending = false;
            }
            if (root.sessionDirty) saveDelay.restart();
        }
    }
    Timer { id: saveRetry; interval: 5000; onTriggered: root.sendSession() }
    function syncWindows() {
        for (var item of windows) {
            var window = item.niriId ? Niri.windowMap[String(item.niriId)] : Niri.toplevels.values.find(w =>
                w.title === item.mappingTitle && Number(w.data.pid) === Quickshell.processId);
            if (!window) continue;
            if (!item.niriId) {
                item.niriId = window.id;
                var saved = item.savedGeometry, workspace = Niri.workspaces.values.find(w =>
                    w.output === saved.output && (w.idx === saved.workspace || w.name === saved.workspaceName));
                if (!workspace && saved.output) workspace = Niri.workspaces.values.find(w => w.output === saved.output && w.active);
                var actions = [];
                if (!window.data.floating) actions.push({Action: {MoveWindowToFloating: {id: window.id}}});
                if (workspace) actions.push({Action: {MoveWindowToWorkspace: {window_id: window.id, reference: {Id: workspace.id}, focus: false}}});
                actions.push({Action: {SetWindowWidth: {id: window.id, change: {SetFixed: Math.max(260, Math.min(10000, saved.width || 340))}}}});
                actions.push({Action: {SetWindowHeight: {id: window.id, change: {SetFixed: Math.max(200, Math.min(10000, saved.height || 300))}}}});
                if (typeof saved.x === "number" && typeof saved.y === "number" && (!saved.output || Niri.monitorData.some(m => m.name === saved.output)))
                    actions.push({Action: {MoveFloatingWindow: {id: window.id, x: {SetFixed: saved.x}, y: {SetFixed: saved.y}}}});
                Niri.request(actions); item.title = "Stickies"; item.placementAttempts = 1; item.geometryDelay.restart();
                continue;
            }
            if (!item.geometryDelay.running && window.data.geometryKnown && window.data.floating) {
                if (item.placementAttempts > 0) {
                    var targetWidth = Math.max(260, Math.min(10000, item.savedGeometry.width || 340));
                    var targetHeight = Math.max(200, Math.min(10000, item.savedGeometry.height || 300));
                    if (item.placementAttempts < 3 && (Math.abs(window.data.size[0] - targetWidth) > 2 || Math.abs(window.data.size[1] - targetHeight) > 2)) {
                        item.placementAttempts++;
                        Niri.request([{Action: {SetWindowWidth: {id: window.id, change: {SetFixed: targetWidth}}}},
                                      {Action: {SetWindowHeight: {id: window.id, change: {SetFixed: targetHeight}}}}]);
                        item.geometryDelay.restart(); continue;
                    }
                    item.placementAttempts = 0;
                }
                var monitor = Niri.monitorData.find(m => m.name === window.data.output);
                var ws = Niri.workspaces.values.find(w => w.id === window.data.workspace_id);
                var next = {width: Math.round(window.data.size[0]), height: Math.round(window.data.size[1]),
                    x: Math.round(window.data.at[0] - (monitor ? monitor.x : 0)), y: Math.round(window.data.at[1] - (monitor ? monitor.y : 0)),
                    output: window.data.output || "", workspace: ws ? ws.idx : null, workspaceName: ws ? ws.name : ""};
                if (next.width >= 260 && next.height >= 200 && JSON.stringify(next) !== JSON.stringify(item.savedGeometry)) {
                    item.savedGeometry = next; scheduleSave();
                }
            }
        }
    }
    Connections { target: Niri; function onUpdated() { root.syncWindows(); } }
    Component.onCompleted: if (hub) Qt.callLater(root.sendSession)
    Component {
        id: stickyWindow
        Window {
            id: win
            property string noteId: ""
            property bool createNew: false
            property bool closePending: false
            property string mappingTitle: ""
            property double niriId: 0
            property int placementAttempts: 0
            property var savedGeometry: ({})
            readonly property alias geometryDelay: geometryDelay
            readonly property alias controller: controller
            title: mappingTitle; width: 340; height: 300; minimumWidth: 260; minimumHeight: 200
            color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
            Timer { id: geometryDelay; interval: 1000; onTriggered: root.syncWindows() }
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
                onSelectedIdChanged: if (selectedId) { win.noteId = selectedId; win.createNew = false; root.scheduleSave(); }
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
