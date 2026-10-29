import QtQuick
import "Locale" as Language

// Content only: the owning layer provides the compositor-blurred glass surface.
Item {
    id: osd
    property string kind: "volume"
    property real value: 0
    property bool muted: false
    property color foreground: "#f7f7fa"
    property string fontFamily: "Inter Variable"
    readonly property string title: kind === "brightness" ? Language.I18n.text("ui.t_ec811d30a89c") : kind === "microphone" ? Language.I18n.text("ui.t_186352a881d0") : Language.I18n.text("audio.volume")
    readonly property real maximumValue: kind === "volume" ? 1.5 : 1
    readonly property real level: Math.max(0, Math.min(maximumValue, value))
    readonly property int percentage: Math.round(level * 100)
    readonly property real filled: muted ? 0 : level / maximumValue
    implicitWidth: 292; implicitHeight: 76

    ShellGlyph {
        objectName: "osdIcon"
        x: 20; y: 25; width: 26; height: 26
        kind: osd.kind === "brightness" ? "sun" : osd.kind === "microphone" ? "mic" : "speaker"
        level: osd.kind === "brightness" ? 3 : osd.muted || osd.level <= 0 ? 0 : osd.level < .34 ? 1 : osd.level < .67 ? 2 : 3
        flag: osd.muted
        color: osd.foreground
    }
    Text {
        x: 62; y: 17; width: parent.width - 146
        text: osd.title
        font.family: osd.fontFamily; font.pixelSize: 13; font.weight: Font.Medium
        color: osd.foreground; elide: Text.ElideRight
    }
    Text {
        objectName: "osdValue"
        x: parent.width - 84; y: 17; width: 64
        text: osd.muted ? Language.I18n.text("ui.t_2346f214ad56") : osd.percentage + "%"
        font.family: osd.fontFamily; font.pixelSize: 13; font.weight: Font.DemiBold
        color: osd.foreground; horizontalAlignment: Text.AlignRight
    }
    Row {
        id: segments
        x: 62; y: 45; width: parent.width - 82; height: 5
        spacing: 3
        Repeater {
            model: 20
            Rectangle {
                required property int index
                width: (segments.width - 19 * segments.spacing) / 20
                height: 5; radius: 2.5
                color: osd.foreground
                opacity: .18 + .82 * Math.max(0, Math.min(1, osd.filled * 20 - index))
                Behavior on opacity { NumberAnimation { duration: 80 } }
            }
        }
    }
}
