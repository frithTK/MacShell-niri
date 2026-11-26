import QtQuick

Item {
    id: b
    required property var host
    required property var t
    required property var gx
    property string kind: ""
    property bool on: false
    property real level: 3
    property bool flag: false
    property string onTint: ""
    property real d: 40
    property real shadow: 0
    signal clicked()
    property bool bounce: false
    width: d; height: d
    scale: (bounce && bma.pressed) ? 0.88 : 1
    Behavior on scale { NumberAnimation { duration: 230; easing.type: Easing.OutBack; easing.overshoot: 3.2 } }
    BarGlass {
        host: host
        anchors.fill: parent; gx: b.gx; cornerR: b.d / 2; thickness: 14; strengthMul: 0.6; shadowAmt: b.shadow; flatInner: 1
    }
    Rectangle {
        anchors.fill: parent
        radius: b.d / 2
        color: b.on ? (b.onTint !== "" ? Qt.color(b.onTint) : Qt.rgba(b.t.accent.r, b.t.accent.g, b.t.accent.b, 0.92))
                    : (bma.containsMouse ? (b.t.dark ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.34)) : Qt.rgba(1, 1, 1, 0))
        Behavior on color { ColorAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }
    // state flip: the icon dips, turns a touch and springs back (motion), while the fill fades
    property real pop: 0
    onOnChanged: popAnim.restart()
    SequentialAnimation {
        id: popAnim
        NumberAnimation { target: b; property: "pop"; to: 1; duration: 120; easing.type: Easing.OutCubic }
        NumberAnimation { target: b; property: "pop"; to: 0; duration: 420; easing.type: Easing.OutQuint }
    }
    ShellGlyph {
        scale: 1 - 0.22 * b.pop
        rotation: (b.on ? -14 : 14) * b.pop
        anchors.centerIn: parent
        width: b.d * 0.46; height: width
        kind: b.kind; level: b.level; flag: b.flag
        color: b.on ? "white" : b.t.fg
    }
    MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
}
