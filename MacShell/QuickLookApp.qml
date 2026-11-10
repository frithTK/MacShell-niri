import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import "Locale" as Language
import "QuickLook.js" as QuickLook
import "SettingsSearch.js" as SettingsSearch

Scope {
    id: root
    property var hub: null
    property string path: ""
    property var inspect: emptyInspect()
    property int inspectId: 0
    property string pending: ""
    property bool loading: false
    property real zoom: 1
    property alias window: win
    readonly property var translations: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property string kind: inspect && inspect.kind ? String(inspect.kind) : ""
    readonly property string displayName: (inspect && inspect.name) ? inspect.name : QuickLook.fileName(path)
    readonly property color foreground: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color secondary: dark ? "#aaaab3" : "#686870"

    function emptyInspect() {
        return { kind: "", path: "", name: "", size: 0, mime: "", truncated: false, text: "" };
    }

    function open(value) {
        var local = QuickLook.localPath(value);
        root.path = local || String(value || "");
        root.inspect = emptyInspect();
        root.loading = true;
        root.zoom = 1;
        root.pending = "";
        win.show();
        win.raise();
        win.requestActivate();
        if (!local) {
            root.inspect = { kind: "invalid", path: root.path, name: QuickLook.fileName(root.path), size: 0, mime: "", truncated: false, text: "" };
            root.loading = false;
            return;
        }
        root.inspect = { kind: "", path: local, name: QuickLook.fileName(local), size: 0, mime: "", truncated: false, text: "" };
        inspectNow(local);
    }

    function inspectNow(local) {
        if (!svc.ready) {
            root.pending = local;
            return;
        }
        root.inspectId = svc.send("inspect", { path: local });
        if (root.inspectId < 0)
            root.pending = local;
    }

    function close() {
        root.path = "";
        root.pending = "";
        root.inspect = emptyInspect();
        root.loading = false;
        root.zoom = 1;
        root.inspectId = 0;
        image.source = "";
        win.hide();
    }

    function openDefault() {
        var local = QuickLook.localPath(root.path);
        if (!local)
            return;
        Quickshell.execDetached(["xdg-open", local]);
    }

    function nudgeZoom(direction) {
        var next = root.zoom + (direction > 0 ? 0.25 : -0.25);
        root.zoom = Math.max(0.25, Math.min(8, Math.round(next * 100) / 100));
    }

    function messageFor(kind) {
        if (kind === "missing") return root.translations.text("quicklook.missing");
        if (kind === "denied") return root.translations.text("quicklook.denied");
        if (kind === "too_large") return root.translations.text("quicklook.too_large");
        if (kind === "invalid") return root.translations.text("quicklook.invalid");
        if (kind === "unavailable") return root.translations.text("quicklook.unavailable");
        return root.translations.text("quicklook.unsupported");
    }

    JsonService {
        id: svc
        launcher: "preview.sh"
        enabled: true
        onConnected: {
            if (!root.pending)
                return;
            var local = root.pending;
            root.pending = "";
            inspectNow(local);
        }
        onReceived: message => {
            if (!message || message.type !== "result" || message.id !== root.inspectId)
                return;
            root.loading = false;
            var payload = message.inspect;
            if (message.success === false || !payload) {
                root.inspect = { kind: "unavailable", path: root.path, name: QuickLook.fileName(root.path), size: 0, mime: "", truncated: false, text: "" };
                return;
            }
            root.inspect = payload;
            if (payload.path)
                root.path = payload.path;
        }
    }

    Window {
        id: win
        title: "Quick Look"
        visible: false
        width: 740
        height: 580
        minimumWidth: 420
        minimumHeight: 320
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.close(); }
        onVisibleChanged: if (!visible) { image.source = ""; root.zoom = 1; }

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
            title: root.displayName || root.translations.text("quicklook.title")
            titleObjectName: "quickLookTitle"
            controlObjectPrefix: "quickLookWindowControl_"
            closeLabel: root.translations.text("quicklook.close")
            minimizeLabel: root.translations.text("quicklook.minimize")
            maximizeLabel: root.translations.text("quicklook.maximize")
            onCloseRequested: root.close()
        }
        Item {
            id: pane
            anchors.fill: parent
            anchors.margins: 1
            anchors.topMargin: titlebar.height
            anchors.bottomMargin: footer.height + 1
            clip: true

            Flickable {
                id: imageFlick
                anchors.fill: parent
                visible: root.kind === "image"
                contentWidth: Math.max(width, image.width)
                contentHeight: Math.max(height, image.height)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Image {
                    id: image
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectFit
                    source: imageFlick.visible && win.visible ? QuickLook.fileUrl(root.path) : ""
                    width: imageFlick.width * root.zoom
                    height: imageFlick.height * root.zoom
                }
            }
            Text {
                anchors.centerIn: parent
                visible: root.kind === "image" && image.status === Image.Error
                width: parent.width - 48
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: root.secondary
                font.family: root.family
                font.pixelSize: 14
                text: root.translations.text("quicklook.image_error")
            }
            Loader {
                id: pdfLoader
                anchors.fill: parent
                active: win.visible && root.kind === "pdf"
                source: "QuickLookPdf.qml"
                onLoaded: if (item) item.source = QuickLook.fileUrl(root.path)
            }
            Connections {
                target: root
                function onPathChanged() {
                    if (pdfLoader.item)
                        pdfLoader.item.source = root.kind === "pdf" ? QuickLook.fileUrl(root.path) : "";
                }
                function onKindChanged() {
                    if (pdfLoader.item)
                        pdfLoader.item.source = root.kind === "pdf" ? QuickLook.fileUrl(root.path) : "";
                }
            }
            Text {
                anchors.centerIn: parent
                visible: pdfLoader.status === Loader.Error && root.kind === "pdf"
                width: parent.width - 48
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: root.secondary
                font.family: root.family
                font.pixelSize: 14
                text: root.translations.text("quicklook.pdf_unavailable")
            }
            Text {
                anchors.centerIn: parent
                visible: pdfLoader.item && root.kind === "pdf" && pdfLoader.item.error
                width: parent.width - 48
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: root.secondary
                font.family: root.family
                font.pixelSize: 14
                text: root.translations.text("quicklook.pdf_error")
            }
            Flickable {
                id: textFlick
                anchors.fill: parent
                visible: root.kind === "text"
                contentWidth: width
                contentHeight: textBody.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: textBody
                    width: textFlick.width - 36
                    x: 18
                    y: 14
                    text: (root.inspect && root.inspect.text) ? String(root.inspect.text) : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: 13
                }
            }
            Text {
                anchors.centerIn: parent
                visible: root.loading && root.kind === ""
                color: root.secondary
                font.family: root.family
                font.pixelSize: 14
                text: root.translations.text("quicklook.loading")
            }
            Text {
                anchors.centerIn: parent
                visible: !root.loading && ["unsupported", "missing", "denied", "too_large", "invalid", "unavailable"].indexOf(root.kind) >= 0
                width: parent.width - 48
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: root.secondary
                font.family: root.family
                font.pixelSize: 14
                text: root.messageFor(root.kind)
            }
            WheelHandler {
                enabled: root.kind === "image" && win.visible
                acceptedModifiers: Qt.ControlModifier
                onWheel: event => {
                    root.nudgeZoom(event.angleDelta.y > 0 ? 1 : -1);
                    event.accepted = true;
                }
            }
        }
        Rectangle {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 1
            height: 46
            color: root.dark ? "#303033" : "#e9e9ec"
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: root.dark ? "#454548" : "#d0d0d4"
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - openButton.width - 40
                elide: Text.ElideRight
                color: root.secondary
                font.family: root.family
                font.pixelSize: 12
                text: {
                    var parts = [];
                    if (root.inspect && root.inspect.size)
                        parts.push(QuickLook.formatSize(root.inspect.size));
                    if (root.kind === "image")
                        parts.push(Math.round(root.zoom * 100) + "%");
                    if (root.kind === "pdf" && pdfLoader.item && pdfLoader.item.pageCount > 0)
                        parts.push(root.translations.text("quicklook.page", {
                            current: pdfLoader.item.currentPage + 1,
                            count: pdfLoader.item.pageCount
                        }));
                    if (root.inspect && root.inspect.truncated)
                        parts.push(root.translations.text("quicklook.truncated"));
                    return parts.join(" · ");
                }
            }
            Button {
                id: openButton
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: 28
                implicitWidth: Math.max(72, openLabel.implicitWidth + 20)
                enabled: SettingsSearch.isLocalPath(QuickLook.localPath(root.path) || root.path)
                onClicked: root.openDefault()
                background: Rectangle {
                    radius: 8
                    color: openButton.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : openButton.hovered ? (root.dark ? "#4c4c51" : "#eeeeef") : (root.dark ? "#3a3a3e" : "#ffffff")
                    border.width: 1
                    border.color: root.dark ? "#525257" : "#d0d0d5"
                    opacity: openButton.enabled ? 1 : 0.5
                }
                contentItem: Text {
                    id: openLabel
                    text: root.translations.text("quicklook.open")
                    color: root.foreground
                    opacity: openButton.enabled ? 1 : 0.45
                    font.family: root.family
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
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
        Shortcut { sequence: "Escape"; enabled: win.visible && win.active; onActivated: root.close() }
        Shortcut { sequence: "Space"; enabled: win.visible && win.active; onActivated: root.close() }
        Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: root.close() }
        Shortcut { sequence: "Ctrl+Q"; enabled: win.visible && win.active; onActivated: root.close() }
        Shortcut { sequence: "Ctrl+O"; enabled: win.visible && win.active; onActivated: root.openDefault() }
        Shortcut { sequence: "Ctrl++"; enabled: win.visible && win.active && root.kind === "image"; onActivated: root.nudgeZoom(1) }
        Shortcut { sequence: "Ctrl+="; enabled: win.visible && win.active && root.kind === "image"; onActivated: root.nudgeZoom(1) }
        Shortcut { sequence: "Ctrl+-"; enabled: win.visible && win.active && root.kind === "image"; onActivated: root.nudgeZoom(-1) }
        Shortcut { sequence: "Ctrl+0"; enabled: win.visible && win.active && root.kind === "image"; onActivated: root.zoom = 1 }
        Shortcut { sequence: "Left"; enabled: win.visible && win.active && root.kind === "pdf"; onActivated: if (pdfLoader.item) pdfLoader.item.goPrev() }
        Shortcut { sequence: "Right"; enabled: win.visible && win.active && root.kind === "pdf"; onActivated: if (pdfLoader.item) pdfLoader.item.goNext() }
        Shortcut { sequence: "PgUp"; enabled: win.visible && win.active && root.kind === "pdf"; onActivated: if (pdfLoader.item) pdfLoader.item.goPrev() }
        Shortcut { sequence: "PgDown"; enabled: win.visible && win.active && root.kind === "pdf"; onActivated: if (pdfLoader.item) pdfLoader.item.goNext() }
    }
}
