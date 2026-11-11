// Desktop Reminders card. It never starts a reminders service; WidgetVisual feeds hub.reminders.
import QtQuick
import QtQuick.Effects
import "GlassTheme.js" as GlassTheme
import "Locale" as Language
import "WidgetCatalog.js" as Catalog

Item {
    id: w
    property string style: "liquid"
    property string size: "small"
    property string fam: "Inter Variable"
    property real textScale: 1
    property var tasks: []
    property bool ready: false
    property bool preview: false
    property bool editing: false
    property bool interactive: false
    property real screenX: x
    property real screenY: y
    property real screenW: 1920
    property real screenH: 1080
    property bool glassReady: false
    property url shaderUrl: ""
    property url wallUrl: ""
    property real glassOpacity: .42
    property real glassBlur: 5
    property real glassLiquid: 1
    property real glassRim: .45
    property real glassGrain: .03
    property bool darkGlass: true
    property bool adding: false
    property var previewDone: ({})
    signal glassFailed()
    signal openRequested()
    signal toggleRequested(var task)
    signal addRequested(string title)
    signal deleteRequested(var task)
    readonly property bool dark: darkGlass
    readonly property real radiusPx: 28
    readonly property real tint: GlassTheme.cardShaderTint(dark, glassOpacity)
    readonly property bool glassOn: style === "liquid" && glassReady && !preview && wallUrl != ""
    readonly property color fg: dark ? "#f5f5f7" : "#202025"
    readonly property color fgSub: dark ? "#b9b9c4" : "#60606c"
    readonly property color blue: "#0A84FF"
    readonly property var localTasks: {
        var rows = [], source = tasks;
        if (!source || source.length === undefined) return rows;
        for (var i = 0; i < source.length; i++) {
            var task = source[i];
            if (!task) continue;
            if (preview && previewDone[task.id] !== undefined) {
                var copy = Object.assign({}, task);
                copy.done = previewDone[task.id];
                rows.push(copy);
            } else rows.push(task);
        }
        return rows;
    }
    readonly property var openTasks: localTasks.filter(function (task) { return !task.done; })
    readonly property int visibleCount: size === "small" ? 4 : (size === "large" ? 10 : 6)
    implicitWidth: Catalog.dimensions(size)[0]
    implicitHeight: Catalog.dimensions(size)[1]
    width: implicitWidth; height: implicitHeight
    Accessible.role: Accessible.List
    Accessible.name: Language.I18n.text("reminders_widget.title")
    Accessible.description: String(openTasks.length)
    function toggle(task) {
        if (preview) {
            var next = Object.assign({}, previewDone);
            next[task.id] = !((previewDone[task.id] === undefined) ? task.done : previewDone[task.id]);
            previewDone = next;
            return;
        }
        if (interactive) toggleRequested(task);
    }
    function removeTask(task) {
        if (interactive && !preview) deleteRequested(task);
    }
    function addTask(title) {
        var value = String(title || "").trim();
        if (value && interactive && !preview) addRequested(value);
    }

    Rectangle {
        anchors.fill: parent
        visible: w.style === "normal"
        radius: w.radiusPx
        gradient: Gradient {
            GradientStop { position: 0.0; color: w.dark ? "#3A3A3D" : "#FFFFFF" }
            GradientStop { position: 1.0; color: w.dark ? "#2A2A2D" : "#EFEFF3" }
        }
    }
    Rectangle {
        anchors.fill: parent
        visible: w.style === "liquid" && !w.glassOn
        radius: w.radiusPx
        gradient: Gradient {
            GradientStop { position: 0.0; color: w.dark ? Qt.rgba(0.22, 0.22, 0.25, 0.82) : Qt.rgba(1.0, 1.0, 1.0, 0.88) }
            GradientStop { position: 1.0; color: w.dark ? Qt.rgba(0.13, 0.13, 0.15, 0.82) : Qt.rgba(0.92, 0.92, 0.95, 0.88) }
        }
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, w.dark ? 0.10 : 0.35) }
                GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, 0.0) }
            }
        }
    }
    Loader {
        id: glassLoader
        anchors.fill: parent
        active: w.glassOn
        sourceComponent: Item {
            id: gl
            readonly property real margin: 72
            readonly property real padPx: 10
            readonly property real ds: w.glassBlur >= 8 ? 0.5 : 1.0
            readonly property real bn: Math.min(1.0, w.glassBlur * 1.4 * ds / 64.0)
            Item {
                id: backdrop
                width: w.width + 2 * (gl.padPx + gl.margin)
                height: w.height + 2 * (gl.padPx + gl.margin)
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#2f6bff" }
                        GradientStop { position: 0.5; color: "#b44cff" }
                        GradientStop { position: 1.0; color: "#ff8a3d" }
                    }
                }
                Image {
                    x: -(w.screenX - gl.padPx - gl.margin)
                    y: -(w.screenY - gl.padPx - gl.margin)
                    width: w.screenW; height: w.screenH
                    source: w.wallUrl; fillMode: Image.PreserveAspectCrop
                    asynchronous: true; sourceSize.width: w.screenW; smooth: true
                }
            }
            ShaderEffectSource {
                id: bsrc; sourceItem: backdrop; hideSource: true; live: true; visible: false
                textureSize: Qt.size(Math.max(1, Math.round(backdrop.width * gl.ds)),
                                     Math.max(1, Math.round(backdrop.height * gl.ds)))
            }
            MultiEffect {
                id: blurFx; source: bsrc; width: backdrop.width * gl.ds; height: backdrop.height * gl.ds
                blurEnabled: true; blurMax: 64; blur: gl.bn; autoPaddingEnabled: false; visible: false
            }
            ShaderEffectSource { id: blurred; sourceItem: blurFx; live: true; visible: false }
            ShaderEffect {
                x: -gl.padPx; y: -gl.padPx; width: w.width + 2 * gl.padPx; height: w.height + 2 * gl.padPx
                fragmentShader: w.shaderUrl
                onStatusChanged: if (status === ShaderEffect.Error) w.glassFailed()
                property variant src: blurred
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(w.width, w.height)
                property vector2d srcSize: Qt.vector2d(backdrop.width, backdrop.height)
                property vector2d srcOffset: Qt.vector2d(gl.margin, gl.margin)
                property real pad: gl.padPx; property real radius: w.radiusPx
                property real bezel: Math.min(Math.min(w.width, w.height) * 0.36, 26)
                property real thickness: 30 * w.glassLiquid; property real dispersion: 0.06 * w.glassLiquid
                property real magnify: 0.08 * w.glassLiquid * Math.min(1, 90 / w.height)
                property real rim: w.glassRim; property real grain: w.glassGrain * 0.15
                property real blurPx: 1.0; property real tintMix: w.tint; property real saturation: 1.25
                property real dark: w.dark ? 1 : 0; property real debug: 0; property real shadowAmt: 1
                property real flatInner: 0; property real rimTint: 1; property real ringW: 1
            }
        }
    }
    Rectangle {
        anchors.fill: parent; visible: !w.glassOn; radius: w.radiusPx; color: "transparent"
        border.width: 1; border.color: w.dark ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.09)
    }

    Item {
        id: rHead
        x: 16; y: 12; width: parent.width - 32; height: 24
        Text {
            objectName: "remindersWidgetTitle"
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - cnt.width - 8; elide: Text.ElideRight
            text: Language.I18n.text("reminders_widget.title"); color: w.blue
            font.family: w.fam; font.pixelSize: 14 * w.textScale; font.weight: Font.Bold
        }
        Text {
            id: cnt
            objectName: "remindersWidgetCount"
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: String(w.openTasks.length); color: w.blue
            font.family: w.fam; font.pixelSize: 22 * w.textScale; font.weight: Font.Bold
        }
        MouseArea {
            objectName: "remindersWidgetOpen"
            anchors.fill: parent; enabled: w.interactive; cursorShape: Qt.PointingHandCursor
            onClicked: w.openRequested()
        }
    }
    Column {
        id: remCol
        x: 16; y: rHead.y + rHead.height + 6; width: parent.width - 32
        height: parent.height - y - 14
        spacing: 7; clip: true
        Text {
            objectName: "remindersWidgetEmpty"
            width: parent.width; visible: w.localTasks.length === 0
            text: !w.ready && !w.preview ? Language.I18n.text("notes.unavailable") : Language.I18n.text("reminders_widget.empty")
            color: w.fgSub; font.family: w.fam; font.pixelSize: 13 * w.textScale; wrapMode: Text.Wrap
        }
        Repeater {
            model: w.localTasks.slice(0, w.visibleCount)
            delegate: Row {
                id: remRow
                required property var modelData
                required property int index
                objectName: "remindersWidgetRow_" + modelData.id
                spacing: 8; width: remCol.width
                Rectangle {
                    id: tick
                    objectName: "remindersWidgetTick_" + remRow.modelData.id
                    width: 16; height: 16; radius: 8
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property bool done: !!remRow.modelData.done
                    color: done ? w.blue : "transparent"
                    border.width: 1.5; border.color: done ? w.blue : w.fgSub
                    Text { anchors.centerIn: parent; visible: tick.done; text: "✓"; color: "white"; font.pixelSize: 10; font.bold: true }
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -4
                        enabled: w.interactive || w.preview; cursorShape: Qt.PointingHandCursor
                        onClicked: w.toggle(remRow.modelData)
                    }
                }
                Text {
                    width: parent.width - 24; elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                    text: remRow.modelData.title || ""; font.strikeout: !!remRow.modelData.done
                    color: remRow.modelData.done ? w.fgSub : w.fg
                    font.family: w.fam; font.pixelSize: 13 * w.textScale
                }
            }
        }
    }
}
