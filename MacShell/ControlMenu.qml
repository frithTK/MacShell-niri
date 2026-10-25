import QtQuick
import QtQuick.Controls

Pane {
    property var t: null
    property color foreground: t ? t.fg : "white"
    readonly property bool dark: foreground.hslLightness > .5
    readonly property color secondary: Qt.rgba(foreground.r, foreground.g, foreground.b, dark ? .62 : .68)
    readonly property color warning: dark ? "#ffb454" : "#542e00"
    readonly property color danger: dark ? "#ff8f87" : "#6b1a16"
    readonly property color separator: Qt.rgba(foreground.r, foreground.g, foreground.b, .10)
    signal backRequested()
    font.family: t ? t.fam : "Inter Variable"
    font.pixelSize: 13
    padding: 0
    background: null
    palette.window: dark ? "#24252b" : "#fafafb"
    palette.windowText: foreground
    palette.text: foreground
    palette.buttonText: foreground
    palette.button: dark ? "#3b3b40" : "#e2e2e6"
    palette.base: dark ? "#303035" : "#ffffff"
    palette.highlightedText: "white"
    palette.highlight: t ? t.accent : "#0a84ff"
    palette.placeholderText: secondary
}
