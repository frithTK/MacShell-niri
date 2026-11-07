import QtQuick

// A symbolic indicator: no fingerprint image or inferred scan progress is used.
Item {
    id: root
    property bool dark: true
    property bool running: false
    property var fingerPresent: null
    property int stage: 0
    property int total: 0
    property string statusText: ""
    property string progressText: ""
    property string family: "sans-serif"
    readonly property bool touching: running && fingerPresent === true
    readonly property real progress: total > 0 ? Math.max(0, Math.min(1, stage / total)) : 0
    implicitHeight: 132

    Rectangle {
        anchors.fill: parent; radius: 14
        color: root.dark ? "#252c37" : "#eaf3ff"
        border.width: 1; border.color: root.dark ? "#3b4a5c" : "#d3e3f6"
    }
    Item {
        id: symbol
        x: 14; anchors.verticalCenter: parent.verticalCenter; width: 102; height: 102
        Rectangle {
            anchors.centerIn: parent; width: 90; height: 90; radius: 45
            color: root.dark ? "#213d59" : "#d3e8ff"
            opacity: root.touching ? .55 + root.pulse * .25 : .32
            scale: root.touching ? 1 + root.pulse * .04 : 1
        }
        Canvas {
            id: fingerprint
            anchors.centerIn: parent; width: 70; height: 70; antialiasing: true
            onPaint: {
                var c = getContext("2d"); c.reset();
                c.strokeStyle = root.dark ? "#9dcaff" : "#2376c5";
                c.globalAlpha = root.touching ? 1 : .62;
                c.lineWidth = 2; c.lineCap = "round";
                function curve(x, y, a, b, d, e, f, g) { c.beginPath(); c.moveTo(x,y); c.bezierCurveTo(a,b,d,e,f,g); c.stroke(); }
                curve(10,32,10,13,21,6,35,6); curve(35,6,51,6,60,16,60,32);
                curve(15,40,15,24,19,12,35,12); curve(35,12,49,12,55,21,55,34);
                curve(20,49,21,35,19,18,35,18); curve(35,18,47,18,50,27,50,37);
                curve(25,58,28,46,23,24,35,24); curve(35,24,44,24,44,30,44,40);
                curve(31,63,35,49,29,30,35,30); curve(35,30,40,30,38,40,38,45);
                curve(44,46,44,53,42,60,40,65); curve(50,44,50,52,49,57,47,62);
                curve(55,42,55,49,55,53,54,56); curve(15,46,15,51,14,55,13,58);
            }
            Connections { target: root; function onTouchingChanged() { fingerprint.requestPaint(); } function onDarkChanged() { fingerprint.requestPaint(); } }
        }
    }
    property real pulse: 0
    SequentialAnimation on pulse {
        running: root.touching; loops: Animation.Infinite
        NumberAnimation { from: 0; to: 1; duration: 650; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: 0; duration: 650; easing.type: Easing.InOutSine }
    }
    Column {
        anchors.left: symbol.right; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 8; anchors.rightMargin: 16; spacing: 10
        Text { objectName: "fingerPresenceText"; width: parent.width; text: root.statusText; color: root.dark ? "#e8f2ff" : "#17436c"; font.family: root.family; font.pixelSize: 13; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        Text { objectName: "fingerStageText"; visible: root.total > 0; width: parent.width; text: root.progressText; color: root.dark ? "#b3c6dd" : "#526b84"; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Rectangle {
            objectName: "fingerStageTrack"; visible: root.total > 0; width: parent.width; height: 5; radius: 3
            color: root.dark ? "#415064" : "#c7daee"
            Rectangle { objectName: "fingerStageFill"; width: parent.width * root.progress; height: parent.height; radius: 3; color: "#2789ed"; Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } } }
        }
    }
}
