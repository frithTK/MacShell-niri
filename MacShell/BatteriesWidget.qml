// A read-only view of the existing laptop and Bluetooth battery sources.
import QtQuick
import "Locale" as Language
import QtQuick.Effects
import "WidgetCatalog.js" as Catalog
import "BatteriesData.js" as Data

Item {
    id: w
    property string style: "liquid"
    property string size: "small"
    property string fam: "Inter Variable"
    property real textScale: 1
    property var settings: ({})
    property var entries: []
    property bool preview: false
    property bool editing: false
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
    readonly property bool dark: darkGlass
    readonly property bool isSmall: size === "small"
    readonly property bool isLarge: size === "large"
    readonly property real radiusPx: 28
    readonly property real tint: Math.min(.92, dark ? .25 + glassOpacity * .8 : .45 + glassOpacity * .9)
    readonly property bool glassOn: style === "liquid" && glassReady && !preview && wallUrl != ""
    readonly property color fg: dark ? "#f5f5f7" : "#202025"
    readonly property color fgSub: dark ? "#b9b9c4" : "#60606c"
    readonly property var devices: Data.rows(entries, settings)
    readonly property int capacity: isSmall ? 2 : isLarge ? 6 : 4
    readonly property var shownDevices: devices.slice(0, capacity)
    readonly property int columns: isSmall ? 1 : isLarge ? Math.min(2, Math.max(1, shownDevices.length)) : Math.max(1, shownDevices.length)
    readonly property int rows: Math.max(1, Math.ceil(shownDevices.length / columns))
    readonly property string summary: devices.map(row => row.label + ": " + Data.value(row) + " " + Data.status(row) + " " + row.detail).join("; ")
    implicitWidth: Catalog.dimensions(size)[0]
    implicitHeight: Catalog.dimensions(size)[1]
    width: implicitWidth; height: implicitHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: Language.I18n.text("ui.t_bc3cf30c0726")
    Accessible.description: summary || Language.I18n.text("ui.t_91bc36f20032")

    // ───────────────────────── background ─────────────────────────
    // Normal: solid card
    Rectangle {
        anchors.fill: parent
        visible: w.style === "normal"
        radius: w.radiusPx
        gradient: Gradient {
            GradientStop { position: 0.0; color: w.dark ? "#3A3A3D" : "#FFFFFF" }
            GradientStop { position: 1.0; color: w.dark ? "#2A2A2D" : "#EFEFF3" }
        }
    }

    // Liquid fallback / gallery preview: frosted card (while the shader builds, if it fails, and in Settings)
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

    // Liquid Glass: wallpaper crop → blur → refraction shader (the same maths as the Dock and the Weather widget)
    Loader {
        id: glassLoader
        anchors.fill: parent
        active: w.glassOn
        sourceComponent: Item {
            id: gl
            readonly property real margin: 72           // backdrop captured around the widget (blur + refraction reach)
            readonly property real padPx: 10            // shader item padding (soft shadow)
            readonly property real ds: w.glassBlur >= 8 ? 0.5 : 1.0
            readonly property real bn: Math.min(1.0, w.glassBlur * 1.4 * ds / 64.0)

            // the part of the wallpaper behind the widget, laid out exactly like the screen
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
                    width: w.screenW
                    height: w.screenH
                    source: w.wallUrl
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: w.screenW
                    smooth: true
                }
            }
            ShaderEffectSource {
                id: bsrc
                sourceItem: backdrop
                hideSource: true
                live: true
                visible: false
                textureSize: Qt.size(Math.max(1, Math.round(backdrop.width * gl.ds)),
                                     Math.max(1, Math.round(backdrop.height * gl.ds)))
            }
            MultiEffect {
                id: blurFx
                source: bsrc
                width: backdrop.width * gl.ds
                height: backdrop.height * gl.ds
                blurEnabled: true
                blurMax: 64
                blur: gl.bn
                autoPaddingEnabled: false
                visible: false
            }
            ShaderEffectSource {
                id: blurred
                sourceItem: blurFx
                live: true
                visible: false
            }
            ShaderEffect {
                x: -gl.padPx
                y: -gl.padPx
                width: w.width + 2 * gl.padPx
                height: w.height + 2 * gl.padPx
                fragmentShader: w.shaderUrl
                onStatusChanged: if (status === ShaderEffect.Error) w.glassFailed()

                property variant src: blurred
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(w.width, w.height)
                property vector2d srcSize: Qt.vector2d(backdrop.width, backdrop.height)
                property vector2d srcOffset: Qt.vector2d(gl.margin, gl.margin)
                property real pad: gl.padPx
                property real radius: w.radiusPx
                property real bezel: Math.min(Math.min(w.width, w.height) * 0.36, 26)
                property real thickness: 30 * w.glassLiquid
                property real dispersion: 0.06 * w.glassLiquid
                property real magnify: 0.08 * w.glassLiquid * Math.min(1, 90 / w.height)
                property real rim: w.glassRim
                property real grain: w.glassGrain * 0.15   // much finer / quieter than the Dock's noise
                property real blurPx: 1.0            // tiny residual smoothing; the real blur is the MultiEffect pre-pass
                property real tintMix: w.tint
                property real saturation: 1.25
                property real dark: w.dark ? 1 : 0   // this widget's own light / dark mode, not the shell's
                property real debug: 0
                property real shadowAmt: 1
                property real flatInner: 0
                property real rimTint: 1             // rim + border follow the glass's own colour
                property real ringW: 1               // thin 1 px border
            }
        }
    }

    // thin border (Normal style and the frosted fallback). The Liquid Glass border is drawn by the shader itself.
    Rectangle {
        anchors.fill: parent
        visible: !w.glassOn
        radius: w.radiusPx
        color: "transparent"
        border.width: 1
        border.color: w.dark ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.09)
    }

    Text {
        x: 16; y: 13; width: parent.width - 32; height: 22
        text: Language.I18n.text("ui.t_bc3cf30c0726"); color: w.fg; font.family: w.fam; font.pixelSize: 14 * w.textScale; font.weight: Font.DemiBold
        elide: Text.ElideRight
    }
    Item {
        id: grid
        x: 16; y: 42; width: w.width - 32; height: w.height - y - 28
        readonly property real gap: w.isLarge ? 12 : 8
        readonly property real tileWidth: (width - (w.columns - 1) * gap) / w.columns
        readonly property real tileHeight: (height - (w.rows - 1) * gap) / w.rows
        Repeater {
            model: w.shownDevices
            delegate: Item {
                id: tile
                required property var modelData
                required property int index
                objectName: "batteryDevice_" + modelData.id
                x: index % w.columns * (grid.tileWidth + grid.gap)
                y: Math.floor(index / w.columns) * (grid.tileHeight + grid.gap)
                width: grid.tileWidth; height: grid.tileHeight
                readonly property bool horizontal: w.isSmall || w.isLarge
                readonly property real circleSize: w.isLarge ? 42 : w.isSmall ? (w.rows === 1 ? 54 : 34) : 52
                readonly property real textX: horizontal ? circleSize + 8 : 0
                readonly property real textY: horizontal ? Math.max(0, (height - 53) / 2) : circleSize + 6
                readonly property real textWidth: width - textX
                readonly property color tint: !modelData.connected || modelData.percentage < 0 ? w.fgSub
                    : modelData.percentage <= 10 ? (w.dark ? "#ff786f" : "#c23532")
                    : modelData.percentage <= 20 ? (w.dark ? "#f2c46d" : "#a56c13") : (w.dark ? "#5dd9a3" : "#157a55")
                Canvas {
                    id: circle
                    x: tile.horizontal ? 0 : (tile.width - width) / 2
                    y: tile.horizontal ? (tile.height - height) / 2 : 0
                    width: tile.circleSize; height: width
                    readonly property var device: tile.modelData
                    readonly property color tint: tile.tint
                    readonly property bool dark: w.dark
                    onDeviceChanged: requestPaint()
                    onTintChanged: requestPaint()
                    onDarkChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onAvailableChanged: if (available) requestPaint()
                    onPaint: {
                        var c = getContext("2d"), line = width > 40 ? 4 : 3, radius = (width - line) / 2;
                        c.reset(); c.clearRect(0, 0, width, height); c.lineWidth = line;
                        c.strokeStyle = dark ? "#50505a" : "#d1d1d9";
                        c.beginPath(); c.arc(width / 2, height / 2, radius, 0, 2 * Math.PI); c.stroke();
                        if (device.connected && device.percentage > 0) {
                            c.strokeStyle = tint; c.lineCap = "round"; c.beginPath();
                            c.arc(width / 2, height / 2, radius, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * device.percentage / 100); c.stroke();
                        }
                    }
                    ShellGlyph {
                        anchors.centerIn: parent; width: parent.width * .48; height: width
                        kind: tile.modelData.kind; color: tile.modelData.connected ? w.fg : w.fgSub
                    }
                    ShellGlyph {
                        visible: tile.modelData.charging
                        x: parent.width - 12; y: parent.height - 12; width: 12; height: 12
                        kind: "bolt"; color: tile.tint
                    }
                }
                Text {
                    objectName: "batteryName_" + tile.modelData.id
                    x: tile.textX; y: tile.textY; width: tile.textWidth; height: 16
                    text: tile.modelData.id === "laptop" ? Language.I18n.legacy(tile.modelData.label) : tile.modelData.label; textFormat: Text.PlainText
                    horizontalAlignment: tile.horizontal ? Text.AlignLeft : Text.AlignHCenter
                    color: w.fgSub; font.family: w.fam; font.pixelSize: (w.isLarge ? 12 : 10) * w.textScale; elide: Text.ElideRight
                }
                Text {
                    objectName: "batteryValue_" + tile.modelData.id
                    x: tile.textX; y: tile.textY + 17; width: tile.textWidth; height: 22
                    text: Data.value(tile.modelData)
                    horizontalAlignment: tile.horizontal ? Text.AlignLeft : Text.AlignHCenter
                    color: w.fg; font.family: w.fam; font.pixelSize: (w.isLarge ? 23 : 19) * w.textScale
                    font.weight: Font.DemiBold; fontSizeMode: Text.Fit; minimumPixelSize: 10
                }
                Text {
                    objectName: "batteryStatus_" + tile.modelData.id
                    x: tile.textX; y: tile.textY + 40; width: tile.textWidth; height: 15
                    text: Language.I18n.legacy(Data.status(tile.modelData))
                    horizontalAlignment: tile.horizontal ? Text.AlignLeft : Text.AlignHCenter
                    color: w.fgSub; font.family: w.fam; font.pixelSize: 10 * w.textScale; elide: Text.ElideRight
                }
            }
        }
        Column {
            anchors.centerIn: parent; width: parent.width; spacing: 8; visible: w.devices.length === 0
            Text {
                objectName: "batteriesEmpty"; width: parent.width
                text: w.settings.mode === "selected" ? Language.I18n.text("ui.t_91927f54813b") : Language.I18n.text("ui.t_91bc36f20032")
                color: w.fg; font.family: w.fam; font.pixelSize: 12 * w.textScale; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            }
            Text {
                width: parent.width; text: Language.I18n.text("ui.t_d118eceeb054")
                color: w.fgSub; font.family: w.fam; font.pixelSize: 10 * w.textScale; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            }
        }
    }
    Text {
        objectName: "batteriesFooter"
        x: 16; y: parent.height - 23; width: parent.width - 32; height: 16
        text: w.devices.length > w.capacity ? Language.I18n.plural("devices.more", w.devices.length - w.capacity)
            : w.settings.mode === "selected" ? Language.I18n.text("ui.t_70f7773f1cf6") : Language.I18n.text("ui.t_d461a493a375")
        color: w.fgSub; font.family: w.fam; font.pixelSize: 10 * w.textScale; elide: Text.ElideRight
    }
}
