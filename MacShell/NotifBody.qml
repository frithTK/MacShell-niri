import QtQuick
import QtQuick.Effects
import "Locale" as Language

Item {
    id: nb
    required property var t
    property string app: ""
    property string summary: ""
    property string body: ""
    property string icon: ""
    property int urgency: 1
    property real stamp: 0
    property real nowMs: 0
    property bool showClose: false
    property bool showTime: false
    property bool timeSensitive: false
    signal closeClicked()
    width: parent ? parent.width : 340
    height: Math.max(74, textCol.height + 30)

    readonly property string agoText: {
        var m = Math.floor((nb.nowMs - nb.stamp) / 60000);
        return m < 1 ? "now" : (m < 60 ? m + "m ago" : (m < 1440 ? Math.floor(m / 60) + "h ago" : Math.floor(m / 1440) + "d ago"));
    }

    Item {
        x: 14; y: 15; width: 44; height: 44
        Rectangle {
            anchors.fill: parent; radius: 10
            visible: nimg.status !== Image.Ready
            color: nb.t.accent
            ShellGlyph { anchors.centerIn: parent; width: 24; height: 24; kind: "bell"; color: "white" }
        }
        Image {
            id: nimg
            anchors.fill: parent
            visible: status === Image.Ready
            source: nb.icon
            sourceSize.width: 96; sourceSize.height: 96
            fillMode: Image.PreserveAspectFit
            asynchronous: true; smooth: true
        }
    }
    Column {
        id: textCol
        // a notification updated in place (same id, new text): blur out, refocus on the new wording
        property real refocus: 0
        layer.enabled: refocus > 0.001
        layer.effect: MultiEffect { blurEnabled: true; blurMax: 32; blur: textCol.refocus; autoPaddingEnabled: true }
        opacity: 1 - 0.5 * refocus
        NumberAnimation { id: refocusAnim; target: textCol; property: "refocus"; from: 1; to: 0; duration: 460; easing.type: Easing.OutQuint }
        Connections {
            target: nb
            function onSummaryChanged() { refocusAnim.restart(); }
            function onBodyChanged() { refocusAnim.restart(); }
        }
        x: 70; y: 14
        width: parent.width - 70 - 44
        spacing: 1
        Text {
            width: parent.width
            visible: nb.timeSensitive && nb.urgency !== 2
            text: Language.I18n.text("ui.t_3299e1c9c571")
            color: nb.t.fg2
            font.family: nb.t.fam; font.pixelSize: 11; font.weight: Font.DemiBold
            font.letterSpacing: 0.4
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: nb.urgency === 2 ? Language.I18n.text("ui.t_3299e1c9c571") : nb.app
            horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
            visible: text !== ""
            color: nb.urgency === 2 ? nb.t.fg2 : nb.t.fg
            font.family: nb.t.fam; font.pixelSize: nb.urgency === 2 ? 12 : 14
            font.weight: Font.DemiBold
            font.letterSpacing: nb.urgency === 2 ? 0.4 : 0
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: nb.summary
            horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
            visible: text !== ""
            color: nb.t.fg
            font.family: nb.t.fam; font.pixelSize: 14; font.weight: Font.Bold
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: nb.body
            horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
            visible: text !== ""
            color: nb.t.fg
            font.family: nb.t.fam; font.pixelSize: 13
            wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
        }
    }
    Text {
        visible: nb.showTime && !nb.showClose
        anchors.right: parent.right; anchors.rightMargin: 14
        y: 15
        text: nb.agoText
        color: nb.t.fg2
        font.family: nb.t.fam; font.pixelSize: 12
    }
    Rectangle {
        id: xbtn
        visible: nb.showClose
        anchors.right: parent.right; anchors.rightMargin: 10
        y: 10
        width: 22; height: 22; radius: 11
        color: xma.containsMouse ? nb.t.btnHover : nb.t.btnOff
        ShellGlyph { anchors.centerIn: parent; width: 12; height: 12; kind: "close"; color: nb.t.fg }
        MouseArea { id: xma; anchors.fill: parent; hoverEnabled: true; onClicked: nb.closeClicked() }
    }
}

