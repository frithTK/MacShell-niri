// Desktop Notes card. It never starts a notes service; WidgetVisual feeds hub.notes.
import QtQuick
import QtQuick.Effects
import "Locale" as Language
import "WidgetCatalog.js" as Catalog

Item {
    id: w
    property string style: "liquid"
    property string size: "small"
    property string fam: "Inter Variable"
    property real textScale: 1
    property var notes: []
    property string body: ""
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
    signal glassFailed()
    signal openRequested()
    readonly property bool dark: darkGlass
    readonly property real radiusPx: 28
    readonly property real tint: Math.min(.92, dark ? .25 + glassOpacity * .8 : .45 + glassOpacity * .9)
    readonly property bool glassOn: style === "liquid" && glassReady && !preview && wallUrl != ""
    readonly property color fg: dark ? "#f5f5f7" : "#202025"
    readonly property color fgSub: dark ? "#b9b9c4" : "#60606c"
    readonly property color accent: "#FFD60A"
    readonly property var shown: notes && notes.length ? notes[0] : null
    readonly property string titleText: {
        var source = body !== "" ? body : (shown ? String(shown.body || "") : "");
        var line = source.split("\n")[0].trim();
        return line || Language.I18n.text("notes.untitled");
    }
    readonly property string bodyText: {
        var source = body !== "" ? body : (shown ? String(shown.body || "") : "");
        if (!ready && !preview) return Language.I18n.text("notes.unavailable");
        if (!source.trim()) return Language.I18n.text("notes.no_notes");
        return source.replace(/^#+\s*/gm, "");
    }
    implicitWidth: Catalog.dimensions(size)[0]
    implicitHeight: Catalog.dimensions(size)[1]
    width: implicitWidth; height: implicitHeight
    Accessible.role: Accessible.Button
    Accessible.name: Language.I18n.text("notes.title")
    Accessible.description: titleText
    Accessible.onPressAction: if (w.interactive) w.openRequested()

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

    Row {
        id: nHead
        x: 16; y: 13; width: parent.width - 32; height: 22; spacing: 6
        Rectangle {
            width: 18; height: 18; radius: 5; color: w.accent; anchors.verticalCenter: parent.verticalCenter
            Rectangle { x: 3; y: 4; width: 12; height: 1.6; color: "white" }
        }
        Text {
            objectName: "notesWidgetTitle"
            width: parent.width - 24; elide: Text.ElideRight
            text: Language.I18n.text("notes.title"); color: w.accent
            font.family: w.fam; font.pixelSize: 14 * w.textScale; font.weight: Font.Bold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    Text {
        objectName: "notesWidgetBody"
        x: 16; y: nHead.y + nHead.height + 8
        width: parent.width - 32; height: parent.height - y - 16
        clip: true; wrapMode: Text.Wrap; elide: Text.ElideRight; textFormat: Text.PlainText
        text: w.bodyText; color: w.fg; font.family: w.fam; font.pixelSize: 13 * w.textScale; lineHeight: 1.12
    }
    MouseArea {
        objectName: "notesWidgetOpen"
        anchors.fill: parent; enabled: w.interactive; cursorShape: Qt.PointingHandCursor
        onClicked: w.openRequested()
    }
}
