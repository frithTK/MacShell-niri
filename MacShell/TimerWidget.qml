// One view of Clock's shared timer. It never owns or starts a clock service.
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import "Locale" as Language
import "WidgetCatalog.js" as Catalog
import "TimerWidgetData.js" as Data

Item {
    id: w
    property string style: "liquid"
    property string size: "small"
    property string fam: "Inter Variable"
    property real textScale: 1
    property var settings: ({})
    property var backend: null
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
    signal openClock()
    readonly property bool dark: darkGlass
    readonly property real radiusPx: 28
    readonly property real tint: Math.min(.92, dark ? .25 + glassOpacity * .8 : .45 + glassOpacity * .9)
    readonly property bool glassOn: style === "liquid" && glassReady && !preview && wallUrl != ""
    readonly property color fg: dark ? "#f5f5f7" : "#202025"
    readonly property color fgSub: dark ? "#b9b9c4" : "#60606c"
    readonly property var presets: Data.presets(settings)
    readonly property var timer: preview ? ({state: "running", sessionId: "preview"}) : backend && backend.timing ? backend.timing.timer : null
    readonly property string timerState: timer ? timer.state : "unavailable"
    readonly property bool controllable: interactive && !preview && !editing && backend && backend.ready && !backend.busy && timer && backend.timerStatus === "normal"
    readonly property bool active: timerState === "running" || timerState === "paused"
    readonly property bool needsClock: !active || (!preview && backend && backend.timerStatus !== "normal")
    property int requestedMinutes: 0
    property string requestedSession: ""
    readonly property real remaining: preview ? 874000 : backend ? backend.timerRemaining : 0
    implicitWidth: Catalog.dimensions(size)[0]
    implicitHeight: Catalog.dimensions(size)[1]
    width: implicitWidth; height: implicitHeight
    function choose(minutes) {
        if (!controllable) return;
        if (active) { requestedSession = timer.sessionId; requestedMinutes = minutes; }
        else if (timerState === "idle") backend.startTimer(minutes * 60000, "", false, "", null);
    }
    function confirmReplace() {
        var minutes = requestedMinutes, session = requestedSession;
        requestedMinutes = 0; requestedSession = "";
        if (!controllable || !active || !session || timer.sessionId !== session) return;
        backend.startTimer(minutes * 60000, "", true, "", null);
    }
    function act(action) { if (controllable && active) backend.timerAction(action); }
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
        x: 16; y: 13; width: parent.width - 32
        text: Language.I18n.text("timer_widget.title"); color: w.fg; font.family: w.fam
        font.pixelSize: 14 * w.textScale; font.weight: Font.DemiBold; elide: Text.ElideRight
    }
    Column {
        id: body
        anchors.centerIn: parent; anchors.verticalCenterOffset: size === "small" ? 10 : 8
        width: Math.min(parent.width - 24, 340); spacing: size === "large" ? 16 : 7
        Text {
            objectName: "timerWidgetTime"; width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: !w.preview && (!w.backend || !w.backend.ready || w.backend.timerStatus === "unavailable") ? "--:--" :
                  w.timerState === "idle" ? Data.duration(w.presets[0] * 60000) : Data.duration(w.remaining)
            color: w.fg; font.family: w.fam; font.weight: Font.Light
            font.pixelSize: (w.size === "small" ? 33 : 42) * w.textScale; font.features: { "tnum": 1 }
        }
        Text {
            objectName: "timerWidgetStatus"; width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            text: !w.preview && (!w.backend || !w.backend.ready) ? Language.I18n.text("timer_widget.unavailable") :
                  w.timerState === "recovery" || (w.backend && w.backend.timerStatus === "recovery") ? Language.I18n.text("timer_widget.recovery") :
                  w.timerState === "running" ? Language.I18n.text("timer_widget.running") : w.timerState === "paused" ? Language.I18n.text("timer_widget.paused") : Language.I18n.text("timer_widget.ready")
            color: w.fgSub; font.family: w.fam; font.pixelSize: 11 * w.textScale
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter; spacing: 5
            Repeater {
                model: w.presets
                delegate: TimerButton {
                    required property int modelData
                    required property int index
                    objectName: "timerWidgetPreset_" + index
                    width: w.size === "small" ? 46 : 70
                    text: modelData + " " + Language.I18n.text("timer_widget.minutes_short")
                    enabled: w.controllable && !w.requestedMinutes
                    onClicked: w.choose(modelData)
                }
            }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter; spacing: 6
            TimerButton {
                objectName: "timerWidgetToggle"; width: w.size === "small" ? 72 : 112
                text: w.timerState === "paused" ? Language.I18n.text("timer_widget.resume") : Language.I18n.text("timer_widget.pause")
                visible: !w.needsClock; enabled: w.controllable && !w.requestedMinutes
                onClicked: w.act(w.timerState === "paused" ? "resume" : "pause")
            }
            TimerButton {
                objectName: "timerWidgetCancel"; width: w.size === "small" ? 72 : 112
                text: Language.I18n.text("timer_widget.cancel_timer"); visible: !w.needsClock
                enabled: w.controllable && !w.requestedMinutes; onClicked: w.act("cancel")
            }
            TimerButton {
                objectName: "timerWidgetOpenClock"; width: w.size === "small" ? 130 : 180
                text: Language.I18n.text("timer_widget.open_clock"); visible: w.needsClock
                enabled: w.interactive && !w.preview && !w.editing && !w.requestedMinutes
                onClicked: w.openClock()
            }
        }
    }
    Rectangle {
        objectName: "timerWidgetConfirmation"; anchors.fill: parent; radius: w.radiusPx
        visible: w.requestedMinutes > 0; color: w.dark ? "#ed25262d" : "#f2f5f5f7"
        Column {
            anchors.centerIn: parent; width: parent.width - 24; spacing: 10
            Text {
                width: parent.width; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                text: Language.I18n.text("timer_widget.replace_question")
                color: w.fg; font.family: w.fam; font.pixelSize: 13 * w.textScale; font.weight: Font.DemiBold
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter; spacing: 6
                TimerButton { objectName: "timerWidgetKeep"; width: w.size === "small" ? 66 : 90; text: Language.I18n.text("common.cancel"); enabled: w.interactive && !w.editing; onClicked: { w.requestedMinutes = 0; w.requestedSession = ""; } }
                TimerButton { objectName: "timerWidgetReplace"; width: w.size === "small" ? 76 : 100; text: Language.I18n.text("timer_widget.replace"); enabled: w.controllable; onClicked: w.confirmReplace() }
            }
        }
    }
    component TimerButton: Button {
        height: 27; padding: 0
        font.family: w.fam; font.pixelSize: 11 * w.textScale
        background: Rectangle { radius: 8; color: parent.down ? "#ff9f0a" : w.dark ? "#3dffffff" : "#20000000" }
        contentItem: Text { text: parent.text; color: w.fg; opacity: parent.enabled || w.preview ? 1 : .5; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
    }
}
