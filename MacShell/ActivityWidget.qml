// Desktop Activity is a view of the shell's shared SystemStats, never a sampler.
import QtQuick
import "Locale" as Language
import QtQuick.Effects
import "WidgetCatalog.js" as Catalog
import "ActivityWidgetData.js" as Data

Item {
    id: w
    property string style: "liquid"
    property string size: "small"
    property string fam: "Inter Variable"
    property real textScale: 1
    property var settings: ({})
    property var sample: ({})
    property var history: []
    property bool stale: true
    property var appearance: ({})
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
    function requestOpen() { if (interactive && !preview && !editing) openRequested(); }
    readonly property bool dark: darkGlass
    readonly property bool isSmall: size === "small"
    readonly property bool isLarge: size === "large"
    readonly property real s: 1
    readonly property real radiusPx: 28
    readonly property real tint: Math.min(.92, dark ? .25 + glassOpacity * .8 : .45 + glassOpacity * .9)
    readonly property bool glassOn: style === "liquid" && glassReady && !preview && wallUrl != ""
    readonly property color fg: dark ? "#f5f5f7" : "#202025"
    readonly property color fgSub: dark ? "#b9b9c4" : "#60606c"
    readonly property var shownMetrics: Data.selected(settings)
    readonly property int columns: isSmall || isLarge ? Math.min(2, shownMetrics.length) : shownMetrics.length
    readonly property int rows: Math.ceil(shownMetrics.length / columns)
    readonly property bool graphs: settings.view === "graphs"
    readonly property string status: stale ? (sample.time === undefined ? Language.I18n.text("ui.t_7e901627a888") : Language.I18n.text("ui.t_6968b7fa682b"))
        : sample.gap ? Language.I18n.text("ui.t_a1f421df5e50") : Language.I18n.text("ui.t_854a37928e47")
    readonly property string summary: shownMetrics.map(key => Data.labels[key] + ": " + Data.values(sample, key, stale, appearance.speedUnit === "binary").join(" ")
        + " · " + Data.hint(sample, key, stale)).join("; ")
    implicitWidth: Catalog.dimensions(size)[0]
    implicitHeight: Catalog.dimensions(size)[1]
    width: implicitWidth; height: implicitHeight
    Accessible.role: Accessible.Button
    Accessible.name: Language.I18n.text("ui.t_38da1505ca83")
    Accessible.description: summary
    Accessible.onPressAction: requestOpen()
    activeFocusOnTab: interactive && !preview && !editing
    Keys.onReturnPressed: requestOpen()
    Keys.onEnterPressed: requestOpen()
    Keys.onSpacePressed: requestOpen()

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
        text: Language.I18n.text("ui.t_38da1505ca83"); color: w.fg; font.family: w.fam; font.pixelSize: 14 * w.textScale; font.weight: Font.DemiBold
        elide: Text.ElideRight
    }
    Item {
        id: grid
        x: 16; y: 42; width: w.width - 32; height: w.height - y - 28
        readonly property real gap: w.isLarge ? 14 : 8
        readonly property real tileWidth: (width - (w.columns - 1) * gap) / w.columns
        readonly property real tileHeight: (height - (w.rows - 1) * gap) / w.rows
        Repeater {
            model: w.shownMetrics
            delegate: Item {
                id: tile
                required property string modelData
                required property int index
                objectName: "activityTile_" + modelData
                x: index % w.columns * (grid.tileWidth + grid.gap)
                y: Math.floor(index / w.columns) * (grid.tileHeight + grid.gap)
                width: grid.tileWidth; height: grid.tileHeight
                readonly property bool pressure: modelData === "cpu" || modelData === "memory"
                readonly property bool ring: pressure && !w.graphs
                readonly property real amount: w.stale ? -1 : Data.percent(w.sample, modelData)
                readonly property var values: Data.values(w.sample, modelData, w.stale, w.appearance.speedUnit === "binary")
                readonly property string hint: Data.hint(w.sample, modelData, w.stale)
                readonly property color tint: Data.color(modelData, w.sample, w.stale, w.appearance, w.dark)
                readonly property real ringSize: w.isLarge ? 54 : w.isSmall && w.rows > 1 ? 21 : 30
                readonly property real valueY: w.isLarge ? 26 : 18
                Text {
                    width: parent.width; height: 16
                    text: Language.I18n.legacy(Data.labels[tile.modelData]); color: w.fgSub; font.family: w.fam
                    font.pixelSize: (w.isLarge ? 12 : 10) * w.textScale; font.weight: Font.Medium; elide: Text.ElideRight
                }
                Loader {
                    id: ring
                    active: tile.ring
                    x: 0; y: tile.valueY; width: tile.ringSize; height: width
                    sourceComponent: Canvas {
                        anchors.fill: parent
                        readonly property real amount: tile.amount
                        readonly property color tint: tile.tint
                        onAmountChanged: requestPaint()
                        onTintChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onAvailableChanged: if (available) requestPaint()
                        onPaint: {
                            var c = getContext("2d"), line = width > 40 ? 5 : 3, radius = (width - line) / 2;
                            c.reset(); c.clearRect(0, 0, width, height); c.lineWidth = line;
                            c.strokeStyle = w.dark ? "#4a4a52" : "#d1d1d9";
                            c.beginPath(); c.arc(width / 2, height / 2, radius, 0, 2 * Math.PI); c.stroke();
                            if (amount > 0) {
                                c.strokeStyle = tint; c.lineCap = "round"; c.beginPath();
                                c.arc(width / 2, height / 2, radius, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * amount / 100); c.stroke();
                            }
                        }
                    }
                }
                Text {
                    objectName: "activityValue_" + tile.modelData
                    x: tile.ring ? tile.ringSize + 5 : 0; y: tile.valueY
                    width: parent.width - x; height: tile.ring ? tile.ringSize : w.isLarge ? 26 : 16
                    verticalAlignment: Text.AlignVCenter
                    text: tile.values[0]; color: w.fg; font.family: w.fam
                    font.pixelSize: (w.isLarge ? 22 : tile.pressure ? 13 : 11) * w.textScale
                    font.weight: Font.DemiBold; fontSizeMode: Text.Fit; minimumPixelSize: 8
                }
                Text {
                    objectName: "activitySecondary_" + tile.modelData
                    x: 0; y: tile.valueY + (tile.ring ? tile.ringSize + 5 : w.isLarge ? 30 : 16)
                    width: parent.width; height: w.isLarge ? 19 : 15
                    visible: !tile.pressure || w.isLarge || w.rows === 1
                    text: !tile.pressure && tile.hint !== w.sample[tile.modelData === "network" ? "interface" : "device"] ? tile.hint
                        : tile.values[1] || tile.hint
                    color: w.fgSub; font.family: w.fam
                    font.pixelSize: (w.isLarge ? 12 : 10) * w.textScale; fontSizeMode: Text.Fit; minimumPixelSize: 8
                }
                Loader {
                    x: 0; y: w.isLarge ? 83 : tile.pressure ? 39 : 51
                    width: parent.width; height: Math.max(0, parent.height - y - (w.isLarge ? 24 : 0))
                    active: (!tile.pressure || w.graphs) && height > 3
                    sourceComponent: StatsGraph {
                        objectName: "activityGraph_" + tile.modelData
                        anchors.fill: parent
                        history: w.history; metric: tile.modelData
                        primaryColor: tile.tint; secondaryColor: w.dark ? "#efb27d" : "#a45d25"
                    }
                }
                Text {
                    visible: w.isLarge
                    x: 0; y: parent.height - height; width: parent.width; height: 18
                    text: tile.pressure ? tile.hint : tile.hint + (tile.modelData === "network" ? " · ↓ / ↑" : Language.I18n.text("ui.t_fa39ea10a513"))
                    color: w.fgSub; font.family: w.fam; font.pixelSize: 10 * w.textScale; elide: Text.ElideRight
                }
            }
        }
    }
    Text {
        objectName: "activityStatus"
        x: 16; y: parent.height - 23; width: parent.width - 32; height: 16
        text: w.status; color: w.fgSub; font.family: w.fam; font.pixelSize: 10 * w.textScale; elide: Text.ElideRight
    }
    Rectangle { anchors.fill: parent; radius: w.radiusPx; color: "transparent"; border.width: w.activeFocus ? 2 : 0; border.color: "#0a84ff" }
    MouseArea {
        objectName: "activityOpen"
        anchors.fill: parent; enabled: w.interactive && !w.preview && !w.editing
        cursorShape: Qt.PointingHandCursor
        onClicked: w.requestOpen()
    }
}
