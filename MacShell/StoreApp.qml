import QtQuick
import QtQuick.Window
import Quickshell
import "Locale" as Language

Scope {
    id: root
    property var hub: null
    readonly property var tr: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color ink: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color ink2: dark ? "#a1a1a6" : "#6e6e73"
    readonly property color card: dark ? "#2c2c2e" : "#ffffff"
    readonly property color line: dark ? "#3a3a3c" : "#e5e5ea"
    property bool applying: false
    property bool shelly: false
    property string source: "standard"
    property string query: ""
    property var rows: []
    property var updates: ({ standard: [], flatpak: [], appimage: [], aur: [] })
    property var errors: ({})
    property string notice: ""
    property var pending: null
    property string inflight: ""
    readonly property bool browsing: query.trim().length >= 2

    function text(key, parameters) { return root.tr.text(key, parameters || ({})); }
    function explain(error) {
        if (!error) return root.text("store.failed");
        if (error === "shelly") return root.text("store.missing");
        if (error === "Source changed") return root.text("store.source_changed");
        if (error === "busy") return root.text("store.busy");
        return String(error);
    }
    function samePending(action, row) {
        var want = root.pending;
        if (!want || want.action !== action) return false;
        if (!row) return want.name === "";
        return want.name === row.name && want.version === (row.version || "") && want.repo === (row.repo || "");
    }
    function ask(action, row) {
        if (root.applying || (root.hub && root.hub.desktopSource && root.hub.desktopSource.applying)) {
            root.notice = root.text("store.busy");
            return;
        }
        var picked = {
            action: action,
            source: row && row.source ? row.source : root.source,
            name: row ? row.name : "",
            version: row ? (row.version || "") : "",
            repo: row ? (row.repo || "") : "",
            scope: row ? (row.scope || "") : ""
        };
        if (root.samePending(action, row)) {
            root.inflight = "apply";
            root.applying = true;
            root.notice = root.text("store.working");
            var sent = svc.send("apply", picked);
            if (sent < 0) {
                root.applying = false;
                root.inflight = "";
                root.notice = root.text("store.busy");
            }
            return;
        }
        root.pending = picked;
        var fields = { name: picked.name, version: picked.version, repo: picked.repo };
        if (action === "upgrade" && picked.source === "standard") root.notice = root.text("store.confirm_system");
        else if (action === "upgrade" && picked.source === "appimage") root.notice = root.text("store.confirm_appimage");
        else if (action === "install" && picked.source === "standard") root.notice = root.text("store.confirm_install", fields);
        else if (action === "remove") root.notice = root.text("store.confirm_remove", fields);
        else root.notice = root.text("store.confirm_update", fields);
    }
    function refresh() {
        if (!svc.ready || !root.shelly || root.applying) return;
        root.inflight = "updates";
        svc.send("updates", {});
    }
    function searchNow() {
        if (!root.browsing || !svc.ready || !root.shelly || root.applying) return;
        root.inflight = "search";
        svc.send("search", { source: root.source, query: root.query.trim() });
    }
    function open() {
        storeWindow.show();
        storeWindow.raise();
        storeWindow.requestActivate();
        if (svc.ready && root.shelly) root.refresh();
    }

    JsonService {
        id: svc
        launcher: "store.sh"
        enabled: storeWindow.visible || root.applying
        serializeRequests: true
        onConnected: svc.send("hello", {})
        onReceived: message => {
            if (!message) return;
            if (message.shelly !== undefined) {
                root.shelly = message.shelly === true;
                if (!root.shelly) root.notice = root.text("store.missing");
                else if (storeWindow.visible) root.refresh();
                return;
            }
            if (message.type === "status") {
                root.notice = root.text("store.working");
                return;
            }
            if (message.type !== "result") return;
            if (root.inflight === "apply") {
                var ok = message.success === true;
                var error = ok ? "" : root.explain(message.error);
                root.applying = false;
                root.inflight = "";
                root.pending = null;
                root.notice = ok ? "" : error;
                Quickshell.execDetached(["notify-send", "-a", "MacShell", root.text("store.title"), ok ? root.text("store.done") : error]);
                if (ok && storeWindow.visible) root.refresh();
                return;
            }
            if (root.inflight === "updates") {
                root.inflight = "";
                if (message.success === false) {
                    root.notice = root.explain(message.error);
                    return;
                }
                root.updates = {
                    standard: message.standard || [],
                    flatpak: message.flatpak || [],
                    appimage: message.appimage || [],
                    aur: message.aur || []
                };
                root.errors = message.errors || ({});
                return;
            }
            if (root.inflight === "search") {
                root.inflight = "";
                root.rows = message.success === true ? (message.rows || []) : [];
                root.notice = message.success === true ? "" : root.explain(message.error);
            }
        }
    }
    Timer { id: typing; interval: 300; onTriggered: root.searchNow() }
    onQueryChanged: { root.pending = null; if (root.browsing) typing.restart(); else root.rows = []; }
    onSourceChanged: { root.pending = null; root.rows = []; if (root.browsing) root.searchNow(); }

    Window {
        id: storeWindow
        title: "App Store"
        visible: false
        width: 560
        height: 680
        minimumWidth: 460
        minimumHeight: 480
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint
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
            window: storeWindow
            dark: root.dark
            family: root.family
            title: root.text("store.title")
            closeLabel: root.text("store.close")
            minimizeLabel: root.text("store.minimize")
            maximizeLabel: root.text("store.maximize")
            onCloseRequested: storeWindow.hide()
        }
        Column {
            x: 18
            y: titlebar.height + 12
            width: parent.width - 36
            spacing: 10
            Rectangle {
                width: parent.width
                height: 36
                radius: 10
                color: root.card
                TextInput {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: Text.AlignVCenter
                    color: root.ink
                    font.family: root.family
                    font.pixelSize: 14
                    clip: true
                    selectByMouse: true
                    onTextChanged: root.query = text
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.query === ""
                    text: root.text("store.search")
                    color: root.ink2
                    font.family: root.family
                    font.pixelSize: 14
                }
            }
            Row {
                spacing: 8
                Repeater {
                    model: [
                        { id: "standard", label: root.text("store.source_standard") },
                        { id: "flatpak", label: root.text("store.source_flatpak") },
                        { id: "aur", label: root.text("store.source_aur") }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: label.width + 22
                        height: 28
                        radius: 14
                        color: root.source === modelData.id ? (root.dark ? "#0a84ff" : "#007aff") : root.card
                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: modelData.label
                            color: root.source === modelData.id ? "white" : root.ink
                            font.family: root.family
                            font.pixelSize: 13
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.source = modelData.id }
                    }
                }
            }
            Row {
                spacing: 8
                visible: root.shelly
                Rectangle {
                    width: systemLabel.width + 22
                    height: 30
                    radius: 8
                    color: root.card
                    Text { id: systemLabel; anchors.centerIn: parent; text: root.text("store.update_system"); color: root.ink; font.family: root.family; font.pixelSize: 13 }
                    MouseArea { anchors.fill: parent; enabled: !root.applying; onClicked: root.ask("upgrade", { source: "standard", name: "", version: "", repo: "", scope: "" }) }
                }
                Rectangle {
                    visible: (root.updates.appimage || []).length > 0
                    width: imageLabel.width + 22
                    height: 30
                    radius: 8
                    color: root.card
                    Text { id: imageLabel; anchors.centerIn: parent; text: root.text("store.update_appimage"); color: root.ink; font.family: root.family; font.pixelSize: 13 }
                    MouseArea { anchors.fill: parent; enabled: !root.applying; onClicked: root.ask("upgrade", { source: "appimage", name: "", version: "", repo: "", scope: "" }) }
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                visible: text !== ""
                text: !root.shelly && svc.ready ? root.text("store.missing")
                      : (root.notice !== "" ? root.notice : (root.source === "aur" ? root.text("store.aur_note") : ""))
                color: root.ink2
                font.family: root.family
                font.pixelSize: 13
            }
            Flickable {
                width: parent.width
                height: Math.max(120, storeWindow.height - titlebar.height - 210)
                contentWidth: width
                contentHeight: listCol.height
                clip: true
                flickableDirection: Flickable.VerticalFlick
                Column {
                    id: listCol
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: root.browsing ? root.rows : (root.source === "aur" ? (root.updates.aur || []) : (root.source === "flatpak" ? (root.updates.flatpak || []) : (root.updates.standard || [])))
                        delegate: Rectangle {
                            id: rowCard
                            required property var modelData
                            width: listCol.width
                            height: 64
                            radius: 12
                            color: root.card
                            readonly property string verb: {
                                if (root.source === "aur") return "";
                                if (!root.browsing) return root.source === "flatpak" ? "update" : "";
                                if (root.source === "flatpak" && !modelData.installed && !modelData.scope) return "";
                                return modelData.installed ? "remove" : "install";
                            }
                            Column {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 150
                                Text { width: parent.width; elide: Text.ElideRight; text: modelData.name || ""; color: root.ink; font.family: root.family; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: (modelData.version || "") + (modelData.newVersion ? " → " + modelData.newVersion : "") + (modelData.repo ? " · " + modelData.repo : "")
                                    color: root.ink2
                                    font.family: root.family
                                    font.pixelSize: 12
                                }
                            }
                            Rectangle {
                                visible: rowCard.verb !== ""
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: verbText.width + 18
                                height: 28
                                radius: 8
                                color: root.dark ? "#3a3a3c" : "#e5e5ea"
                                Text {
                                    id: verbText
                                    anchors.centerIn: parent
                                    text: rowCard.verb === "install" ? root.text("store.install") : (rowCard.verb === "update" ? root.text("store.update") : root.text("store.remove"))
                                    color: root.ink
                                    font.family: root.family
                                    font.pixelSize: 13
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !root.applying
                                    onClicked: root.ask(rowCard.verb, {
                                        source: root.source,
                                        name: modelData.name,
                                        version: modelData.version || "",
                                        repo: modelData.repo || "",
                                        scope: modelData.scope || ""
                                    })
                                }
                            }
                        }
                    }
                    Repeater {
                        model: !root.browsing && root.source === "standard" ? (root.updates.appimage || []) : []
                        delegate: Rectangle {
                            required property var modelData
                            width: listCol.width
                            height: 64
                            radius: 12
                            color: root.card
                            Column {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 150
                                Text { width: parent.width; elide: Text.ElideRight; text: modelData.name || ""; color: root.ink; font.family: root.family; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text { width: parent.width; elide: Text.ElideRight; text: modelData.version || ""; color: root.ink2; font.family: root.family; font.pixelSize: 12 }
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: imageVerb.width + 18
                                height: 28
                                radius: 8
                                color: root.dark ? "#3a3a3c" : "#e5e5ea"
                                Text { id: imageVerb; anchors.centerIn: parent; text: root.text("store.remove"); color: root.ink; font.family: root.family; font.pixelSize: 13 }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !root.applying
                                    onClicked: root.ask("remove", { source: "appimage", name: modelData.name, version: modelData.version || "", repo: "", scope: "" })
                                }
                            }
                        }
                    }
                    Text {
                        visible: root.browsing && root.rows.length === 0 && root.notice === "" && root.shelly
                        text: root.text("store.empty")
                        color: root.ink2
                        font.family: root.family
                        font.pixelSize: 13
                    }
                }
            }
        }
        Shortcut { sequence: "Ctrl+W"; enabled: storeWindow.visible && storeWindow.active; onActivated: storeWindow.hide() }
    }
}
