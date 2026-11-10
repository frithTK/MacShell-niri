import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import "Locale" as Language
import "DropTools.js" as DropTools
import "QuickLook.js" as QuickLook
import "SettingsSearch.js" as SettingsSearch

Scope {
    id: root
    property var hub: null
    property var files: []
    property var actions: []
    property var results: []
    property string stage: "drop"
    property string banner: ""
    property var pending: []
    property int listId: 0
    property int runId: 0
    property int done: 0
    property int total: 0
    property alias window: win
    readonly property var translations: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color foreground: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: dark ? "#aaaab3" : "#686870"
    readonly property var dests: DropTools.dests(results)

    function openDrop() {
        root.files = [];
        root.actions = [];
        root.results = [];
        root.stage = "drop";
        root.banner = "";
        root.done = 0;
        root.total = 0;
        win.show();
        win.raise();
        win.requestActivate();
        Qt.callLater(function () { radial.forceActiveFocus(); });
    }

    function openFilesFromText(text) {
        var raw = String(text || "").trim();
        var paths = DropTools.parseUriList(raw);
        if (paths.length === 0 && DropTools.isLocalPath(raw))
            paths = [raw];
        openFiles(paths);
    }

    function openFiles(paths) {
        var local = DropTools.localPaths(paths);
        if (local.length === 0) {
            openDrop();
            return;
        }
        root.files = local.map(function (path) {
            return { path: path, name: QuickLook.fileName(path), kind: "", actions: [] };
        });
        root.actions = [];
        root.results = [];
        root.stage = "inspect";
        root.banner = "";
        win.show();
        win.raise();
        win.requestActivate();
        listNow(local);
    }

    function listNow(paths) {
        if (!svc.ready) {
            root.pending = paths;
            return;
        }
        root.pending = [];
        root.listId = svc.send("list", { paths: paths });
        if (root.listId < 0)
            root.banner = root.translations.text("droptools.unavailable");
    }

    function runOp(id) {
        var paths = root.files.map(function (row) { return row.path; });
        if (!id || paths.length === 0)
            return;
        root.stage = "run";
        root.banner = "";
        root.done = 0;
        root.total = paths.length;
        root.runId = svc.send("run", { paths: paths, op: id });
        if (root.runId < 0) {
            root.stage = "choose";
            root.banner = root.translations.text("droptools.unavailable");
        }
    }

    function cancelRun() {
        svc.send("cancel", {});
    }

    function close() {
        if (root.stage === "run")
            cancelRun();
        root.files = [];
        root.actions = [];
        root.results = [];
        root.stage = "drop";
        win.hide();
    }

    function openDest(path) {
        if (!DropTools.isLocalPath(path))
            return;
        Quickshell.execDetached(["xdg-open", path]);
    }

    function revealDest(path) {
        var dir = SettingsSearch.parentDir(path);
        if (dir)
            Quickshell.execDetached(["xdg-open", dir]);
    }

    function labeledActions(rows) {
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            out.push({
                id: rows[i].id,
                available: rows[i].available !== false,
                missing: rows[i].missing || "",
                label: root.translations.text(DropTools.actionKey(rows[i].id))
            });
        }
        return out;
    }

    JsonService {
        id: svc
        launcher: "drop-tools.sh"
        enabled: true
        onConnected: {
            if (root.pending && root.pending.length)
                root.listNow(root.pending);
        }
        onReceived: message => {
            if (!message)
                return;
            if (message.type === "progress" && message.runId === root.runId) {
                root.done = Number(message.done || 0);
                root.total = Number(message.total || root.total);
                return;
            }
            if (message.type !== "result")
                return;
            if (message.id === root.listId && Array.isArray(message.files)) {
                root.files = message.files;
                root.actions = root.labeledActions(DropTools.commonActions(message.files));
                if (root.actions.length === 0) {
                    root.stage = "choose";
                    root.banner = root.translations.text("droptools.unsupported");
                } else {
                    root.stage = "choose";
                    root.banner = "";
                    Qt.callLater(function () { radial.forceActiveFocus(); });
                }
                return;
            }
            if (message.id === root.runId) {
                root.results = message.results || [];
                root.stage = "done";
                root.banner = root.translations.text(DropTools.resultKey(message));
            }
        }
        onLastErrorChanged: {
            if (svc.lastError)
                root.banner = root.translations.text("droptools.unavailable");
        }
    }

    Window {
        id: win
        title: root.translations.text("droptools.title")
        visible: false
        width: 460
        height: 520
        minimumWidth: 380
        minimumHeight: 420
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.close(); }
        onVisibleChanged: if (visible) Qt.callLater(function () { radial.forceActiveFocus(); })

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: root.dark ? "#1c1c1e" : "#f2f2f7"
            border.width: 1
            border.color: root.dark ? "#49494f" : "#c8c8ce"
        }
        AppTitlebar {
            id: titlebar
            x: 1
            width: parent.width - 2
            window: win
            dark: root.dark
            family: root.family
            title: root.translations.text("droptools.title")
            titleObjectName: "dropToolsTitle"
            controlObjectPrefix: "dropToolsWindowControl_"
            closeLabel: root.translations.text("droptools.close")
            minimizeLabel: root.translations.text("droptools.minimize")
            maximizeLabel: root.translations.text("droptools.maximize")
            onCloseRequested: root.close()
        }
        DropArea {
            id: drop
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titlebar.bottom
            anchors.bottom: parent.bottom
            keys: ["text/uri-list"]
            onDropped: event => {
                var paths = [];
                if (event.hasUrls) {
                    for (var i = 0; i < event.urls.length; i++)
                        paths.push(event.urls[i].toString());
                } else if (event.hasText) {
                    paths = DropTools.parseUriList(event.text);
                }
                event.acceptProposedAction();
                if (paths.length)
                    root.openFiles(paths);
            }

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 24
                width: parent.width - 48
                spacing: 12
                visible: root.stage === "drop" || root.stage === "inspect"
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root.stage === "inspect" ? root.translations.text("droptools.loading") : root.translations.text("droptools.drop_hint")
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: 15
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    visible: root.banner !== ""
                    text: root.banner
                    color: root.secondary
                    font.family: root.family
                    font.pixelSize: 12
                }
            }

            DropRadial {
                id: radial
                visible: root.stage === "choose" && root.actions.length > 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 28
                actions: root.actions
                family: root.family
                foreground: root.foreground
                fill: root.dark ? "#3a3a3e" : "#ffffff"
                muted: root.secondary
                onChosen: id => root.runOp(id)
                onCancelled: root.close()
            }

            Text {
                visible: root.stage === "choose"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 88
                width: parent.width - 48
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: root.banner !== "" ? root.banner : root.translations.text("droptools.convert")
                color: root.secondary
                font.family: root.family
                font.pixelSize: 12
            }

            Column {
                visible: root.stage === "run" || root.stage === "done"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 36
                width: parent.width - 48
                spacing: 10
                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: root.stage === "run" ? root.translations.text("droptools.working") : root.banner
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: 14
                }
                Repeater {
                    model: root.stage === "done" ? root.results : []
                    delegate: Text {
                        required property var modelData
                        width: parent.width
                        wrapMode: Text.Wrap
                        elide: Text.ElideMiddle
                        text: modelData.success ? QuickLook.fileName(modelData.dest) : root.translations.text(DropTools.errorKey(modelData.error))
                        color: modelData.success ? root.foreground : root.secondary
                        font.family: root.family
                        font.pixelSize: 12
                    }
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 18
                spacing: 8
                Button {
                    visible: root.stage === "run"
                    implicitHeight: 28
                    implicitWidth: 96
                    text: root.translations.text("droptools.cancel")
                    onClicked: root.cancelRun()
                    contentItem: Text {
                        text: parent.text
                        color: root.foreground
                        font.family: root.family
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: 8
                        color: parent.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : (root.dark ? "#3a3a3e" : "#ffffff")
                        border.width: 1
                        border.color: root.dark ? "#525257" : "#d0d0d5"
                    }
                }
                Button {
                    visible: root.stage === "done" && root.dests.length > 0
                    implicitHeight: 28
                    implicitWidth: 96
                    text: root.translations.text("droptools.open")
                    onClicked: root.openDest(root.dests[0])
                    contentItem: Text {
                        text: parent.text
                        color: root.foreground
                        font.family: root.family
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: 8
                        color: parent.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : (root.dark ? "#3a3a3e" : "#ffffff")
                        border.width: 1
                        border.color: root.dark ? "#525257" : "#d0d0d5"
                    }
                }
                Button {
                    visible: root.stage === "done" && root.dests.length > 0
                    implicitHeight: 28
                    implicitWidth: 132
                    text: root.translations.text("droptools.show_in_folder")
                    onClicked: root.revealDest(root.dests[0])
                    contentItem: Text {
                        text: parent.text
                        color: root.foreground
                        font.family: root.family
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: 8
                        color: parent.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : (root.dark ? "#3a3a3e" : "#ffffff")
                        border.width: 1
                        border.color: root.dark ? "#525257" : "#d0d0d5"
                    }
                }
            }
        }
        MouseArea {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: 10
            height: 10
            cursorShape: Qt.SizeFDiagCursor
            onPressed: win.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
        }
        Shortcut { sequence: "Escape"; enabled: win.visible && win.active; onActivated: root.stage === "choose" ? radial.cancelled() : root.close() }
        Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: root.close() }
        Shortcut { sequence: "Ctrl+Q"; enabled: win.visible && win.active; onActivated: root.close() }
    }
}
