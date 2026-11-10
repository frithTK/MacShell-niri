import QtQuick

// Local track texture is used only while the control is being manipulated.
Item {
    id: lens
    property color trackColor: "#777777"
    property Item track: null
    property point trackOrigin: Qt.point(0, 0)
    property bool active: false
    property url shaderUrl: Qt.resolvedUrl("liquidglass.frag.qsb")
    property bool failed: false
    readonly property real margin: 24
    Rectangle {
        id: picture
        x: -lens.margin; y: -lens.margin
        width: lens.width + lens.margin * 2; height: lens.height + lens.margin * 2
        color: lens.trackColor
        visible: false
    }
    ShaderEffectSource { id: texture; sourceItem: lens.track || picture; hideSource: false; live: lens.active; mipmap: true; visible: false }
    Loader {
        anchors.fill: parent
        active: lens.active && !lens.failed
        sourceComponent: Item {
            ShaderEffect {
                x: -10; y: -10; width: parent.width + 20; height: parent.height + 20
                fragmentShader: lens.shaderUrl
                onStatusChanged: if (status === ShaderEffect.Error) lens.failed = true
                property variant src: texture
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(lens.width, lens.height)
                property vector2d srcSize: lens.track ? Qt.vector2d(lens.track.width, lens.track.height) : Qt.vector2d(picture.width, picture.height)
                property vector2d srcOffset: lens.track ? Qt.vector2d(lens.trackOrigin.x - 10, lens.trackOrigin.y - 10) : Qt.vector2d(lens.margin - 10, lens.margin - 10)
                property real pad: 10
                property real radius: lens.height / 2
                property real bezel: Math.min(lens.height * .36, 26)
                property real thickness: lens.height * 1.1
                property real dispersion: .06
                property real blurPx: 1.5
                property real tintMix: .23
                property real saturation: 1.25
                property real dark: 1
                property real debug: 0
                property real rim: .1125
                property real grain: .006
                property real magnify: .05
                property real shadowAmt: .5
                property real rimTint: 1
                property real ringW: 0
                property real flatInner: 1
            }
        }
    }
}
