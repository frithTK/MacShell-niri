import QtQuick

Item {
    id: s
    required property var t
    property real value: 0
    property real maximumValue: 1
    readonly property real position: Math.max(0, Math.min(1, value / maximumValue))
    property string leftKind: "sun"
    property string rightKind: "sun"
    property real leftLevel: 1
    property real rightLevel: 3
    signal moved(real v)
    height: 28
    readonly property real trackX: 28
    readonly property real trackW: Math.max(1, s.width - 28 - 26)
    ShellGlyph {
        x: 4; anchors.verticalCenter: parent.verticalCenter
        width: 16; height: 16
        kind: s.leftKind; level: s.leftLevel
        color: s.t.fg
    }
    Rectangle {
        x: s.trackX; width: s.trackW; height: 4; radius: 2
        anchors.verticalCenter: parent.verticalCenter
        color: s.t.track
    }
    Rectangle {
        x: s.trackX
        width: s.position * s.trackW
        height: 4; radius: 2
        anchors.verticalCenter: parent.verticalCenter
        color: s.t.fg
    }
    ShellGlyph {
        x: s.width - 20; anchors.verticalCenter: parent.verticalCenter
        width: 16; height: 16
        kind: s.rightKind; level: s.rightLevel
        color: s.t.fg2
    }
    Rectangle {
        objectName: "unityMark"
        visible: s.maximumValue > 1
        x: s.trackX + s.trackW / s.maximumValue - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 2; height: 8; radius: 1
        color: s.t.fg2
    }
    MouseArea {
        anchors.fill: parent
        preventStealing: true
        function setFrom(mx) { s.moved(Math.max(0, Math.min(1, (mx - s.trackX) / s.trackW)) * s.maximumValue); }
        onPressed: mouse => setFrom(mouse.x)
        onPositionChanged: mouse => { if (pressed) setFrom(mouse.x); }
    }
}
