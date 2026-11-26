import QtQuick
import "Locale" as Language

// Notification centre. It stays on the menu-bar layer (the bar owns the backdrop and the click-outside mask).
Item {
    id: notifPop
    required property var bar
    required property var shell
    required property var ink
    required property var time
    required property var history
    z: 10
    width: 380
    // while clearing it tracks the collapsing list frame by frame (never shorter than the empty state),
    // so the dust and the shrink are one motion; otherwise it eases to its new size
    height: 92 + (history.count === 0 ? 70 : (bar.notifClearing ? Math.max(70, nfl.height) : nfl.height)) + 14
    Behavior on height { enabled: !bar.notifClearing; NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
    x: shell.popupX(width, scale, transformOrigin)
    y: bar.barHeight + 6
    opacity: shell.pop === "notif" ? 1 : 0
    visible: opacity > 0
    scale: bar.barPopupScale * (shell.pop === "notif" ? 1 : 0.96)
    transformOrigin: Item.TopRight
    // popups merging in: the panel appears at once (its cards are the popups, solid from the first frame) and only
    // its chrome (glass, header, Do Not Disturb) builds in around them
    readonly property bool merging: shell.toastsShown
    property real chrome: shell.pop === "notif" ? 1 : 0
    Behavior on chrome { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    Behavior on opacity { enabled: !notifPop.merging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { enabled: !notifPop.merging; NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

    LiquidGlass {
        host: bar
        anchors.fill: parent
        opacity: notifPop.chrome
        backdrop: shell.glassSrc
        shaderUrl: bar.glassShaderUrl
        liquid: bar.liquidActive
        dark: bar.effDark

        cornerR: 26
        tint: bar.glassOpacity
        thickness: 26
        strength: 0.8 * bar.glassLiquid
        rim: bar.glassRim
        grain: bar.glassGrain
        blur: bar.notifBlur
        debug: bar.glassDebug
        onShaderError: bar.glassState = "failed"
    }
    MouseArea { anchors.fill: parent }      // clicks inside the panel don't close it

    Item {
        x: 18; y: 14; width: parent.width - 36; height: 26
        opacity: notifPop.chrome
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Language.I18n.text("ui.t_fa3ea3dda5df")
            color: ink.fg
            font.family: ink.fam; font.pixelSize: 17; font.weight: Font.DemiBold
        }
        Rectangle {
            visible: history.count > 0
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            width: clrText.implicitWidth + 20; height: 24; radius: 12
            color: clrMa.containsMouse ? ink.btnHover : ink.btnOff
            Text {
                id: clrText
                anchors.centerIn: parent
                text: Language.I18n.text("ui.t_ddceb7adfdb8")
                color: ink.fg
                font.family: ink.fam; font.pixelSize: 12; font.weight: Font.Medium
            }
            MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; onClicked: bar.notifClearAnimated() }
        }
    }
    Item {
        x: 12; y: 46; width: parent.width - 24; height: 36
        opacity: notifPop.chrome
        Rectangle { anchors.fill: parent; radius: 12; color: ink.tile; border.width: 1; border.color: ink.tileBorder }
        ShellGlyph { x: 12; anchors.verticalCenter: parent.verticalCenter; width: 15; height: 15; kind: "moon"; color: ink.fg }
        Text {
            x: 36; anchors.verticalCenter: parent.verticalCenter
            text: Language.I18n.text("ui.t_d0b47b15de45")
            color: ink.fg
            font.family: ink.fam; font.pixelSize: 13
        }
        Rectangle {
            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
            width: 38; height: 22; radius: 11
            color: bar.notifDnd ? ink.accent : ink.switchOff
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                y: 2; width: 18; height: 18; radius: 9; color: "white"
                x: bar.notifDnd ? 18 : 2
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
            MouseArea { anchors.fill: parent; onClicked: bar.notifDnd = !bar.notifDnd }
        }
    }
    Text {
        // fades in as the list finishes collapsing (no pop at the end of Clear All)
        opacity: history.count === 0 ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        x: 0; y: 96; width: parent.width; height: 60
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: Language.I18n.text("ui.t_d963c3ae148d")
        color: ink.fg2
        font.family: ink.fam; font.pixelSize: 14
    }
    Flickable {
        id: nfl
        x: 12; y: 92
        width: parent.width - 24
        height: Math.min(ncol.height, 440)
        contentHeight: ncol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: ncol
            width: nfl.width
            spacing: 8
            Repeater {
                model: history
                delegate: Dissolve {
                    id: hcd
                    required property int nid
                    required property int index
                    required property string app
                    required property string summary
                    required property string body
                    required property string icon
                    required property int urgency
                    required property real time
                    readonly property var group: bar.notifGroupAt(index)
                    property bool dropGroup: false
                    visible: !group.away
                    width: ncol.width
                    // entrance: grows into the list (cards below glide down), slides in from above, comes into focus
                    property real inT: 0
                    property bool snapIn: false
                    Component.onCompleted: inT = 1
                    Behavior on inT { enabled: !hcd.snapIn && !bar.notifClearing; NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                    // morph from the popup: the card starts at the popup's spot / width and flies into its slot
                    property real flipX: 0
                    property real flipY: 0
                    property real flipS: 1
                    function flyFromPopup() {
                        var f = bar.notifMergeFrom[hcd.nid];
                        if (!f || flipAnim.running) return;
                        // the card's final width is the panel's list width (the list may not be laid out yet)
                        var cw = notifPop.width - 24;
                        if (!(cw > 0)) return;
                        var here = hcd.mapToItem(shell, 0, 0);
                        hcd.flipX = f.x + f.w - (here.x + cw);      // right edges line up (scale origin is the right edge)
                        // starts where its popup was, but never above the list's top edge (it would be clipped there)
                        var listTop = nfl.mapToItem(shell, 0, 0).y;
                        hcd.flipY = Math.max(f.y, listTop) - here.y;
                        hcd.flipS = Math.max(0.5, Math.min(1.5, f.w / cw));
                        flyDelay.interval = 1 + Math.max(0, hcd.index) * 40;
                        flyDelay.restart();
                    }
                    Timer { id: flyDelay; onTriggered: flipAnim.restart() }
                    ParallelAnimation {
                        id: flipAnim
                        NumberAnimation { target: hcd; property: "flipX"; to: 0; duration: 280; easing.type: Easing.OutQuint }
                        NumberAnimation { target: hcd; property: "flipY"; to: 0; duration: 280; easing.type: Easing.OutQuint }
                        NumberAnimation { target: hcd; property: "flipS"; to: 1; duration: 280; easing.type: Easing.OutQuint }
                    }
                    Connections {
                        target: bar
                        function onNotifMergeFromChanged() { Qt.callLater(hcd.flyFromPopup); }
                    }
                    height: group.away ? 0 : slot.height * inT
                    cardH: slot.height
                    opacity: inT
                    transform: [
                        Scale { origin.x: hcd.width; origin.y: 0; xScale: hcd.flipS; yScale: hcd.flipS },
                        Translate { x: hcd.flipX; y: (hcd.inT - 1) * 18 + hcd.flipY }
                    ]
                    z: (flipAnim.running || flyDelay.running) ? 10 : 0
                    // after the dust: the gap closes smoothly, then the entry is removed
                    onDone: { if (bar.notifClearing) return; hcd.inT = 0; delT.restart(); }
                    Timer { id: delT; interval: 320; onTriggered: hcd.dropGroup ? bar.notifDeleteGroup(hcd.group.key) : bar.notifDelete(hcd.nid) }
                    // during Clear All the slot shrinks while the card turns to dust (one fluid motion)
                    Timer { id: collapseT; onTriggered: collapseAnim.restart() }
                    NumberAnimation { id: collapseAnim; target: hcd; property: "inT"; to: 0; duration: 820; easing.type: Easing.InOutCubic }
                    Connections {
                        target: bar
                        function onNotifDustAll() {
                            hcd.dissolve(hcd.index * 55);
                            collapseT.interval = 120 + hcd.index * 55; collapseT.restart();
                        }
                    }
                Item {
                    id: slot
                    width: hcd.width
                    height: head.height + hc.height
                    Item {
                        id: head
                        width: parent.width
                        height: hcd.group.open ? 28 : 0
                        visible: hcd.group.open
                        Text {
                            x: 8; anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 70
                            text: hcd.app
                            elide: Text.ElideRight
                            color: ink.fg
                            font.family: ink.fam; font.pixelSize: 13; font.weight: Font.DemiBold
                        }
                        Text {
                            anchors.right: headClose.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                            text: "⌃"
                            color: ink.fg2
                            font.pixelSize: 13
                        }
                        Rectangle {
                            id: headClose
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            width: 22; height: 22; radius: 11
                            color: headCloseMa.containsMouse ? ink.btnHover : "transparent"
                            ShellGlyph { anchors.centerIn: parent; width: 12; height: 12; kind: "close"; color: ink.fg }
                            MouseArea {
                                id: headCloseMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: { hcd.dropGroup = true; hcd.dissolve(1); }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; anchors.rightMargin: 30
                            onClicked: bar.notifToggleGroup(hcd.group.key)
                        }
                    }
                Rectangle {
                    id: hc
                    y: head.height
                    readonly property int nid: hcd.nid
                    readonly property string app: hcd.app
                    readonly property string summary: hcd.summary
                    readonly property string body: hcd.body
                    readonly property string icon: hcd.icon
                    readonly property int urgency: hcd.urgency
                    readonly property real time: hcd.time
                    width: hcd.width
                    height: hcd.group.stack ? stackBody.height : hbody.height
                    radius: 18
                    color: ink.tile
                    border.width: 1; border.color: ink.tileBorder
                    HoverHandler { id: hhov }
                    MouseArea {
                        visible: !hcd.group.stack
                        anchors.fill: parent
                        onClicked: { bar.notifActivate(hc.nid); shell.pop = ""; }
                    }
                    MouseArea {
                        visible: hcd.group.stack
                        anchors.fill: parent
                        onClicked: bar.notifToggleGroup(hcd.group.key)
                    }
                    Rectangle {
                        visible: hcd.group.stack && hhov.hovered
                        z: 2
                        anchors.right: parent.right; anchors.rightMargin: 10; y: 10
                        width: 22; height: 22; radius: 11
                        color: stackCloseMa.containsMouse ? ink.btnHover : ink.btnOff
                        ShellGlyph { anchors.centerIn: parent; width: 12; height: 12; kind: "close"; color: ink.fg }
                        MouseArea {
                            id: stackCloseMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: { hcd.dropGroup = true; hcd.dissolve(1); }
                        }
                    }
                    NotifBody {
                        id: hbody
                        visible: !hcd.group.stack
                        t: ink
                        width: parent.width
                        app: hc.app; summary: hc.summary; body: hc.body; icon: hc.icon
                        urgency: hc.urgency; stamp: hc.time; nowMs: time.date.getTime()
                        showTime: true
                        showClose: hhov.hovered
                        onCloseClicked: hcd.dissolve(1)          // dust away, then removed
                    }
                    NotifBody {
                        id: stackBody
                        visible: hcd.group.stack
                        t: ink
                        width: parent.width
                        app: hc.app
                        summary: hc.summary
                        body: Language.I18n.plural("notifications.more", Math.max(0, hcd.group.count - 1))
                        icon: hcd.group.icon || hc.icon
                        urgency: 1
                        timeSensitive: hcd.group.critical
                        stamp: hc.time; nowMs: time.date.getTime()
                        showTime: !hhov.hovered
                        showClose: false
                    }
                }
                }
                }
            }
        }
    }
}

