import QtQuick
import QtQuick.Effects

Column {
    id: hc
    required property var info
    required property var wd
    property real colW: 40
    width: colW
    spacing: 3 * hc.wd.s
    Text {
        width: parent.width
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        height: 16 * hc.wd.s
        fontSizeMode: Text.Fit; minimumPixelSize: Math.round(10 * hc.wd.s)
        text: hc.info.h
        color: hc.wd.ink(.85)
        font.family: hc.wd.fam
        font.pixelSize: 12 * hc.wd.s * hc.wd.textScale
        font.weight: Font.DemiBold
    }
    Item {
        width: parent.width
        height: 20 * hc.wd.s
        WeatherIcon {
            visible: hc.wd.showIcon(hc.info.k)
            anchors.centerIn: parent
            kind: hc.info.k; dark: hc.wd.dark
            size: 18 * hc.wd.s
        }
    }
    Text {
        width: parent.width
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        height: 19 * hc.wd.s
        fontSizeMode: Text.Fit; minimumPixelSize: Math.round(10 * hc.wd.s)
        text: hc.info.t + hc.wd.unitSuffix
        color: hc.wd.fg
        font.family: hc.wd.fam
        font.pixelSize: 15 * hc.wd.s * hc.wd.textScale
        font.weight: Font.DemiBold
    }
}
