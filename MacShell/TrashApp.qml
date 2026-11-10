import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Locale" as Language
import "SettingsSearch.js" as SettingsSearch
import "TrashItems.js" as TrashItems

Scope {
    id: root
    property var hub: null
    property alias service: svc
    property alias window: win
    property var selected: null
    property string query: ""
    property bool emptyArmed: false
    property string banner: ""
    property string suggested: ""
    readonly property var tr: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color foreground: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: dark ? "#aaaab3" : "#686870"
    readonly property var visibleItems: TrashItems.visibleItems(svc.items, root.query)

    function open() {
        root.banner = "";
        root.suggested = "";
        root.emptyArmed = false;
        win.show();
        win.raise();
        win.requestActivate();
        svc.refresh();
    }

    function close() {
        root.emptyArmed = false;
        win.hide();
    }

    function select(item) {
        root.selected = item || null;
        root.banner = "";
        root.suggested = "";
        root.emptyArmed = false;
    }

    function current() {
        if (root.selected) {
            for (var i = 0; i < root.visibleItems.length; i++) {
                if (root.visibleItems[i].id === root.selected.id)
                    return root.visibleItems[i];
            }
        }
        return root.visibleItems.length ? root.visibleItems[0] : null;
    }

    function restore(asName) {
        var item = root.current();
        if (!item || !item.restore)
            return;
        svc.restore(item.id, asName || "");
    }

    function preview() {
        var item = root.current();
        if (!item || item.isDir || !hub || !hub.quickLook)
            return;
        hub.quickLook.open(item.path);
    }

    function reveal() {
        var item = root.current();
        var dir = item && SettingsSearch.isLocalPath(item.originalDir) ? item.originalDir : "";
        if (!dir)
            return;
        Quickshell.execDetached(["xdg-open", dir]);
    }

    function formatDeleted(value) {
        return TrashItems.formatDeleted(value);
    }

    function errorText(code) {
        if (code === "conflict")
            return root.tr.text("trash.conflict");
        if (code === "missing_dir")
            return root.tr.text("trash.missing_dir");
        if (code === "missing_volume")
            return root.tr.text("trash.missing_volume");
        if (code === "missing")
            return root.tr.text("trash.missing");
        if (code === "denied" || code === "invalid" || code === "cross_device" || code === "not_in_trash")
            return root.tr.text("trash.denied");
        return root.tr.text("trash.unavailable");
    }

    TrashService {
        id: svc
        onChanged: {
            var still = root.current();
            root.selected = still;
            if (!root.visibleItems.length)
                root.emptyArmed = false;
        }
        onRestored: (ok, error, suggested, item) => {
            if (ok) {
                root.banner = "";
                root.suggested = "";
                return;
            }
            root.suggested = suggested || "";
            root.banner = root.errorText(error);
        }
        onEmptied: (ok, removed, failed) => {
            root.emptyArmed = false;
            if (ok) {
                root.banner = "";
                return;
            }
            root.banner = root.tr.text("trash.partial", { removed: removed, failed: (failed || []).length });
        }
    }

    component TrashButton: Button {
        id: control
        implicitHeight: 32
        implicitWidth: Math.max(36, label.implicitWidth + 24)
        font.family: root.family
        font.pixelSize: 12
        contentItem: Text {
            id: label
            text: control.text
            color: root.foreground
            opacity: control.enabled ? 1 : 0.45
            font: control.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 8
            color: control.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : control.hovered ? (root.dark ? "#4c4c51" : "#eeeeef") : (root.dark ? "#3a3a3e" : "#ffffff")
            border.width: 1
            border.color: control.activeFocus ? (root.dark ? "#e8c35e" : "#b28618") : (root.dark ? "#525257" : "#d0d0d5")
            opacity: control.enabled ? 1 : 0.5
        }
    }

    Window {
        id: win
        title: root.tr.text("trash.title")
        width: 780
        height: 560
        minimumWidth: 560
        minimumHeight: 380
        visible: false
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.close(); }
        onVisibleChanged: if (visible) svc.refresh()
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: root.dark ? "#1c1c1e" : "#f7f7f8"
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
            title: root.tr.text("trash.title")
            controlObjectPrefix: "trashWindowControl_"
            closeLabel: root.tr.text("trash.close")
            minimizeLabel: root.tr.text("trash.minimize")
            maximizeLabel: root.tr.text("trash.maximize")
            onCloseRequested: root.close()
        }
        ColumnLayout {
            anchors { left: parent.left; right: parent.right; top: titlebar.bottom; bottom: parent.bottom; margins: 16 }
            spacing: 10
            Shortcut { sequence: "Escape"; enabled: win.visible && win.active; onActivated: root.close() }
            Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: root.close() }
            Shortcut { sequence: "Space"; enabled: win.visible && win.active && !search.activeFocus; onActivated: root.preview() }
            Shortcut { sequence: "Return"; enabled: win.visible && win.active && !search.activeFocus; onActivated: root.restore("") }
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: root.tr.text("trash.title")
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: 21
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                }
                Text {
                    visible: svc.count > 0
                    text: root.tr.text("trash.count", { count: svc.count })
                    color: root.secondary
                    font.family: root.family
                    font.pixelSize: 12
                }
            }
            AppSearchField {
                id: search
                objectName: "trashSearch"
                Layout.fillWidth: true
                placeholderText: root.tr.text("trash.search")
                dark: root.dark
                font.family: root.family
                Accessible.name: placeholderText
                onTextChanged: root.query = text
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 10
                color: root.dark ? "#29292c" : "#ffffff"
                border.width: 1
                border.color: root.dark ? "#424245" : "#d4d4d8"
                ListView {
                    id: list
                    objectName: "trashList"
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true
                    spacing: 2
                    model: root.visibleItems
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 56
                        radius: 8
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.name
                        color: root.current() && root.current().id === modelData.id ? (root.dark ? "#5c5238" : "#f9e8b3") : rowMouse.containsMouse ? (root.dark ? "#353538" : "#e4e4e7") : "transparent"
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.select(modelData)
                            onDoubleClicked: root.restore("")
                        }
                        Column {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                            spacing: 3
                            Text {
                                width: parent.width
                                text: modelData.name || ""
                                color: root.foreground
                                font.family: root.family
                                font.weight: Font.DemiBold
                                font.pixelSize: 13
                                elide: Text.ElideMiddle
                                textFormat: Text.PlainText
                            }
                            Text {
                                width: parent.width
                                text: (modelData.originalPath ? root.tr.text("trash.from", { path: modelData.originalPath }) : "")
                                      + (modelData.deletedAt ? " · " + root.formatDeleted(modelData.deletedAt) : "")
                                color: root.secondary
                                font.family: root.family
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                                textFormat: Text.PlainText
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !svc.loading && root.visibleItems.length === 0
                        text: svc.ready ? root.tr.text("trash.empty_state") : root.tr.text("trash.unavailable")
                        color: root.secondary
                        font.family: root.family
                        font.pixelSize: 14
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: svc.loading && root.visibleItems.length === 0
                        text: root.tr.text("trash.loading")
                        color: root.secondary
                        font.family: root.family
                        font.pixelSize: 14
                    }
                }
            }
            Text {
                visible: root.banner !== ""
                Layout.fillWidth: true
                text: root.banner
                color: root.dark ? "#f0c36a" : "#8a5a00"
                font.family: root.family
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TrashButton {
                    objectName: "trashRestore"
                    text: root.suggested ? root.tr.text("trash.restore_as", { name: root.suggested }) : root.tr.text("trash.restore")
                    enabled: !!root.current() && root.current().restore && !svc.mutating
                    onClicked: root.restore(root.suggested)
                }
                TrashButton {
                    objectName: "trashQuickLook"
                    text: root.tr.text("spotlight.quick_look")
                    enabled: !!root.current() && !root.current().isDir && !svc.mutating
                    onClicked: root.preview()
                }
                TrashButton {
                    objectName: "trashReveal"
                    text: root.tr.text("trash.show_original")
                    enabled: !!root.current() && SettingsSearch.isLocalPath(root.current().originalDir)
                    onClicked: root.reveal()
                }
                Item { Layout.fillWidth: true }
                TrashButton {
                    objectName: "trashEmpty"
                    text: root.emptyArmed ? root.tr.text("trash.empty_confirm") : root.tr.text("trash.empty")
                    enabled: svc.count > 0 && !svc.mutating
                    onClicked: {
                        if (!root.emptyArmed) {
                            root.emptyArmed = true;
                            return;
                        }
                        svc.empty();
                    }
                }
            }
        }
    }
}
