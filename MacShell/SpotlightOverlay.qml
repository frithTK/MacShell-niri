// Spotlight layer. niri blurs a whole layer or none of it, so this window
// uses namespace "macspot" and the menu bar stays unblurred.
import QtQuick
import "Locale" as Language
import "SettingsSearch.js" as SettingsSearch
import "QuickLook.js" as QuickLook
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: spotWin
    component Glyph: ShellGlyph {}
    component GGlass: BarGlass { host: spotWin.bar }
    component CCBtn: BarButton { host: spotWin.bar }
    required property var bar
    required property var ui
    required property var pal
    required property Component backdrop
    property alias spInput: spInput
    property alias appsInput: appsInput
    property alias clipInput: clipInput
    property alias emojiInput: emojiInput
    property alias resPanel: resPanel
    property alias spFocusTimer: spFocusTimer
    property alias spotlightRows: spotlightRows
    property var glassSurfaces: []
    BackgroundEffect.blurRegion: GlassRegion { host: spotWin }
    // The layer stays mapped: creating / destroying it on every open restarted the glass's window captures and
    // niri's layer animation, which is what made Spotlight flicker or vanish. Closed = invisible + click-through.
    visible: bar.spotlightEnabled
    readonly property bool openish: ui.pop === "spot" || spot.vis > 0
    onOpenishChanged: bar.popCount += (openish ? 1 : -1)     // keeps the window-geometry poller running while Spotlight is open
    mask: Region { item: spotWin.openish ? spotRoot : spotNoInput }
    Item { id: spotNoInput; width: 0; height: 0 }
    anchors { left: true; right: true; top: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "macspot"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: ui.pop === "spot" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Item {
        id: spotRoot
        anchors.fill: parent

        Loader {
            id: spotBackdrop
            active: bar.liquidActive
            sourceComponent: backdrop
            onLoaded: { item.includeWindows = true;
                        item.hostShown = Qt.binding(function () { return !bar.gaming && spotWin.openish; });
                        item.region = Qt.binding(function () { return Qt.rect(spot.x - 128, spot.y - 128, spot.width + 256, spot.height + 256); }); }
        }

        // a clipboard entry being dragged out of Spotlight
        Item {
            id: clipGhost
            z: 50
            property var en: null
            property real px: 0
            property real py: 0
            property real zoom: 1
            property real wob: 0
            property real homeX: 0
            property real homeY: 0
            visible: en !== null
            width: 220; height: en && en.kind === "image" ? 150 : 64
            x: px - width / 2; y: py - height / 2
            scale: zoom; rotation: wob
            function start(e) { en = e; zoom = 1.06; opacity = 1; homeX = px; homeY = py; wiggleClip.restart(); }
            function drop(out) {
                wiggleClip.stop();
                if (out) { clipLaunch.restart(); }
                else { clipBack.restart(); }
            }
            Rectangle {
                anchors.fill: parent; radius: 14
                color: bar.darkMode ? Qt.rgba(0.16, 0.16, 0.18, 0.92) : Qt.rgba(0.97, 0.97, 0.98, 0.95)
                border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.18)
            }
            Image {
                visible: clipGhost.en && clipGhost.en.kind === "image"
                anchors.fill: parent; anchors.margins: 6
                source: clipGhost.en && clipGhost.en.thumb ? clipGhost.en.thumb : ""
                fillMode: Image.PreserveAspectCrop; asynchronous: true
            }
            Text {
                visible: !(clipGhost.en && clipGhost.en.kind === "image")
                anchors.fill: parent; anchors.margins: 12
                text: clipGhost.en ? clipGhost.en.text : ""
                wrapMode: Text.Wrap; elide: Text.ElideRight; maximumLineCount: 2
                color: bar.darkMode ? "white" : "#1d1d1f"; font.family: bar.fontFamily; font.pixelSize: 13
            }
            SequentialAnimation {
                id: wiggleClip; loops: Animation.Infinite
                NumberAnimation { target: clipGhost; property: "wob"; to: 3; duration: 90; easing.type: Easing.InOutSine }
                NumberAnimation { target: clipGhost; property: "wob"; to: -3; duration: 180; easing.type: Easing.InOutSine }
                NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 90; easing.type: Easing.InOutSine }
            }
            SequentialAnimation {
                id: clipLaunch
                ParallelAnimation {
                    NumberAnimation { target: clipGhost; property: "zoom"; to: 2.2; duration: 460; easing.type: Easing.OutQuint }
                    NumberAnimation { target: clipGhost; property: "opacity"; to: 0; duration: 460; easing.type: Easing.OutCubic }
                    NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 200 }
                }
                ScriptAction { script: { var e = clipGhost.en; clipGhost.en = null; ui.pop = ""; if (e) bar.clipOpen(e); } }
            }
            SequentialAnimation {
                id: clipBack
                ParallelAnimation {
                    NumberAnimation { target: clipGhost; property: "px"; to: clipGhost.homeX; duration: 380; easing.type: Easing.OutQuint }
                    NumberAnimation { target: clipGhost; property: "py"; to: clipGhost.homeY; duration: 380; easing.type: Easing.OutQuint }
                    NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 200 }
                    NumberAnimation { target: clipGhost; property: "opacity"; to: 0; duration: 380; easing.type: Easing.InCubic }
                }
                ScriptAction { script: clipGhost.en = null }
            }
        }

        // click outside Spotlight closes it
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: ui.pop = ""
        }

        // Backdrop capture + blur for Spotlight's glass. Deliberately NOT inside `spot`: as children they inherited
        // spot's opacity while it faded, so the glass refracted a half-transparent backdrop and turned into a milky
        // blob mid-fade (the fade looked broken). Out here they always produce the real backdrop.
        MappedRect {
            id: spotMapping
            sourceItem: spot; targetItem: spotBackdrop.item
            localRect: Qt.rect(-128, -128, spot.width + 256, 684)
        }
            ShaderEffectSource {
            id: spSrc
            sourceItem: spotBackdrop.item
            hideSource: true
            live: spotWin.openish
            visible: false
            sourceRect: spotMapping.rect
        }
        MultiEffect {
            id: spBlurFx
            source: spSrc
            width: spSrc.sourceRect.width; height: spSrc.sourceRect.height
            blurEnabled: spg.blur * spg.blurMul > 0
            blurMax: 64
            blur: Math.min(1.0, (spg.blur * spg.blurMul) * 1.4 / 64.0)
            autoPaddingEnabled: false
            visible: false
        }
        // real Gaussian pre-blur of the backdrop (Qt MultiEffect): the glass shader refracts THIS texture,
        // so there are no sampled copies of the background any more
        ShaderEffectSource {
            id: spBlur
            sourceItem: spBlurFx
            live: spotWin.openish
            visible: false
        }
        MultiEffect {
            id: spBlur2Fx
            source: spBlur
            width: spSrc.sourceRect.width; height: spSrc.sourceRect.height
            blurEnabled: (spg.blur * spg.blurMul) * 1.4 / 64.0 > 1.0
            blurMax: 64
            blur: Math.max(0.0, Math.min(1.0, (spg.blur * spg.blurMul) * 1.4 / 64.0 - 1.0))
            autoPaddingEnabled: false
            visible: false
        }
        // second Gaussian pass: stacks on the first one so Spotlight can blur past a single pass's 64 px limit
        ShaderEffectSource {
            id: spBlur2
            sourceItem: (spg.blur * spg.blurMul) * 1.4 / 64.0 > 1.0 ? spBlur2Fx : null
            live: spotWin.openish
            visible: false
        }
        GlassCtx {
            id: spg
            src: (blur * blurMul) * 1.4 / 64.0 > 1.0 ? spBlur2 : spBlur
            srcRect: spSrc.sourceRect
            frame: spotRoot
            liquid: bar.liquidActive
            shaderUrl: bar.glassShaderUrl
            dark: bar.effDark
            tint: bar.glassOpacity
            strength: bar.glassLiquid
            rim: bar.glassRim
            grain: bar.glassGrain
            blur: bar.glassBlur
            debug: bar.glassDebug
            onFailed: bar.glassState = "failed"
        }

        // ═════════ Spotlight (Liquid Glass) ═════════
        Item {
            id: spot
            z: 10
            width: 640
            readonly property var curPanel: ui.spMode === "apps" ? appsPanel : (ui.spMode === "clip" ? clipPanel : emojiPanel)
            height: ui.spFull ? curPanel.height : (resPanel.visible ? resPanel.y + resPanel.height : spRow.height)
            x: Math.round((spotRoot.width - width) / 2)
            // the search pill sits a little above the vertical centre of the screen (0.4 of the height; 0.5 = dead centre); the Applications panel centres itself instead
            y: Math.round(spotRoot.height * 0.4 - (ui.spFull ? curPanel.height / 2 : 24))
            Behavior on y { enabled: spot.vis > 0.99; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            // opens with a springy pop; dismiss: quick fade + shrink
            property real vis: 0
            opacity: vis
            visible: vis > 0.001
            scale: ui.spCalm ? 0.98 : 0.94
            transformOrigin: Item.Center
            states: State {
                name: "open"
                when: ui.pop === "spot"
                PropertyChanges { target: spot; vis: 1; scale: 1 }
            }
            transitions: [
                Transition {
                    from: ""; to: "open"
                    ParallelAnimation {
                        NumberAnimation { property: "vis"; duration: 520; easing.type: Easing.OutCubic }
                        NumberAnimation { property: "scale"; duration: ui.spCalm ? 460 : 580; easing.type: Easing.OutQuint }
                    }
                },
                Transition {
                    from: "open"; to: ""
                    ParallelAnimation {
                        NumberAnimation { property: "vis"; duration: 400; easing.type: Easing.OutCubic }
                        NumberAnimation { property: "scale"; to: 0.95; duration: 400; easing.type: Easing.OutCubic }
                    }
                }
            ]

            Timer { id: spHoverClear; interval: 350; onTriggered: ui.spHoverLabel = "" }
            Timer {
                id: spFocusTimer
                interval: 60
                onTriggered: (ui.spMode === "apps" ? appsInput : (ui.spMode === "clip" ? clipInput : (ui.spMode === "emoji" ? emojiInput : spInput))).forceActiveFocus()
            }

            // ── search pill + the four round buttons ──
            Row {
                id: spRow
                spacing: 12
                opacity: !ui.spFull ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

                Item {
                    id: spPill
                    width: spot.width - 5 * 60
                    height: 48
                    GGlass { anchors.fill: parent; gx: spg; cornerR: 24; thickness: 18; strengthMul: 0.7; shadowAmt: 0.18 }
                    HoverHandler { id: pillHover }
                    ContourGlow { cornerR: 24; hovered: pillHover.hovered; at: pillHover.point.position; glowColor: bar.darkMode ? "white" : bar.accent }
                    // very thin outline
                    Rectangle {
                        anchors.fill: parent; radius: 24; color: "transparent"; antialiasing: true
                        border.width: 1; border.color: bar.darkMode ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.11)
                    }
                    Glyph {
                        x: 18; anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18
                        kind: "search"; color: pal.fg2
                    }
                    // placeholder: blur-morphs between "Spotlight Search" and the hovered button's name
                    MorphText {
                        x: spInput.x + 3
                        width: spInput.width
                        anchors.verticalCenter: parent.verticalCenter
                        visible: spInput.text === ""
                        animateWidth: false
                        duration: 460
                        blurMax: 48
                        text: ui.spHoverLabel !== "" ? ui.spHoverLabel : Language.I18n.text("ui.t_296cb158c0e5")
                        color: pal.fg2
                        font.family: pal.fam; font.pixelSize: 17
                        elide: Text.ElideRight
                    }
                    TextInput {
                        id: spInput
                        x: 46
                        width: parent.width - 46 - 18
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        color: pal.fg
                        selectionColor: bar.accent
                        selectedTextColor: "white"
                        font.family: pal.fam; font.pixelSize: 17
                        horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
                        onTextChanged: { if (!ui.spFull) { resPanel.pointerSelection = false; ui.spCloseActions(); ui.spQuery = text; ui.spSel = 0; ui.armed = ""; bar.syncFileSearch(text); } }
                        Keys.onPressed: event => ui.spKey(event)
                    }
                }
                Repeater {
                    model: [
                        { k: "appstore", id: "apps", label: Language.I18n.text("spotlight.apps") }, { k: "folder", id: "files", label: Language.I18n.text("spotlight.home_folder") },
                        { k: "layers", id: "actions", label: Language.I18n.text("ui.t_ff8059dc6752") }, { k: "clipboard", id: "clip", label: Language.I18n.text("ui.t_285d69f0c5d1") }, { k: "smile", id: "emoji", label: Language.I18n.text("ui.t_61ad8976e650") }
                    ]
                    delegate: CCBtn {
                        required property var modelData
                        t: pal; gx: spg
                        d: 48
                        bounce: true
                        shadow: 0.18
                        kind: modelData.k
                        on: ui.spMode === modelData.id
                        HoverHandler {
                            id: btnHover
                            // crossing the gap to the next button must not flash "Spotlight Search": only go back
                            // to it once the pointer has been off every button for 0.35 s
                            onHoveredChanged: {
                                if (hovered) { spHoverClear.stop(); ui.spHoverLabel = modelData.label; }
                                else if (ui.spHoverLabel === modelData.label) spHoverClear.restart();
                            }
                        }
                        ContourGlow { cornerR: 24; hovered: btnHover.hovered; at: btnHover.point.position; glowColor: bar.darkMode ? "white" : bar.accent }
                        // very thin outline
                        Rectangle {
                            anchors.fill: parent; radius: width / 2; color: "transparent"; antialiasing: true
                            border.width: 1; border.color: bar.darkMode ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.11)
                        }
                        onClicked: {
                            if (modelData.id === "apps") ui.spSetMode(ui.spMode === "apps" ? "home" : "apps");
                            else if (modelData.id === "actions") ui.spSetMode(ui.spMode === "actions" ? "home" : "actions");
                            else if (modelData.id === "files") { ui.pop = ""; bar.sh(bar.filesCmd); }
                            else if (modelData.id === "clip") ui.spSetMode(ui.spMode === "clip" ? "home" : "clip");
                            else ui.spSetMode(ui.spMode === "emoji" ? "home" : "emoji");
                        }
                    }
                }
            }

            // ── results under the pill ──
            Item {
                id: resPanel
                y: spRow.height + 10
                width: spot.width
                readonly property var items: ui.spFull ? [] : ui.spList()      // clipboard / emoji / apps have their own panels; actions replace the list
                property bool pointerSelection: false
                property int keep: 1                         // last non-empty row count, so the panel shrinks while it fades out
                onItemsChanged: {
                    if (items.length > 0) keep = items.length;
                    // Keep existing delegates (and their mouse grabs) when search data changes.
                    while (resultRows.count < items.length) resultRows.append({});
                    while (resultRows.count > items.length) resultRows.remove(resultRows.count - 1);
                }
                ListModel { id: resultRows }
                readonly property int selIdx: Math.max(0, Math.min(ui.spSel, items.length - 1))
                opacity: (!ui.spFull && items.length > 0) ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                height: (items.length > 0 ? items.length : keep) * 46 + 16
                Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                GGlass { anchors.fill: parent; gx: spg; cornerR: 26; thickness: 22; strengthMul: 0.75; shadowAmt: 0.22 }
                Item {
                    x: 8; y: 8
                    width: parent.width - 16
                    height: parent.height - 16
                    clip: true
                    Rectangle {
                        y: resPanel.selIdx * 46
                        width: parent.width; height: 46; radius: 16
                        color: (resPanel.items[resPanel.selIdx] && resPanel.items[resPanel.selIdx].confirm === true
                                && ui.armed === resPanel.items[resPanel.selIdx].title) ? "#FF453A" : bar.accent
                        Behavior on y { enabled: !resPanel.pointerSelection; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                Column {
                    width: parent.width
                    Repeater {
                        id: spotlightRows
                        model: resultRows
                        delegate: Item {
                            id: rr
                            required property int index
                            readonly property var modelData: resPanel.items[index] || ({})
                            readonly property string ico: (modelData && modelData.icon) ? String(modelData.icon) : ""
                            readonly property bool sel: index === Math.min(ui.spSel, resPanel.items.length - 1)
                            readonly property bool armedNow: modelData.confirm === true && ui.armed === modelData.title
                            readonly property bool hasActions: !ui.spActionItem && SettingsSearch.hasExtras(modelData.kind)
                            readonly property bool disabledAction: ui.spActionItem && modelData.enabled === false
                            width: parent.width
                            height: 46
                            Drag.dragType: Drag.Automatic
                            Drag.supportedActions: Qt.CopyAction
                            Drag.proposedAction: Qt.CopyAction
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData.title || ""
                            Accessible.description: modelData.sub || ""
                            Accessible.onPressAction: ui.spActivate(rr.index)
                            Item {
                                x: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 30; height: 30
                                Image {
                                    visible: rr.ico !== ""
                                    anchors.fill: parent
                                    source: rr.ico
                                    sourceSize: Qt.size(64, 64)
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    smooth: true
                                }
                                Glyph {
                                    visible: rr.ico === ""
                                    anchors.centerIn: parent
                                    width: 20; height: 20
                                    kind: (rr.modelData && rr.modelData.glyph) ? rr.modelData.glyph : ""
                                    color: rr.sel ? "white" : pal.fg
                                }
                            }
                            Text {
                                x: 54
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 54 - (rr.hasActions && rr.sel ? 168 : 140)
                                elide: Text.ElideRight
                                opacity: rr.disabledAction ? 0.45 : 1
                                text: rr.armedNow ? (rr.modelData.confirmLabel || Language.I18n.text("ui.t_56af92f92b20")) : (rr.modelData.title || "")
                                color: rr.sel ? "white" : pal.fg
                                font.family: pal.fam; font.pixelSize: 14
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: rr.hasActions && rr.sel ? 44 : 16
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, 120)
                                elide: Text.ElideRight
                                text: rr.modelData.sub || ""
                                color: rr.sel ? Qt.rgba(1, 1, 1, 0.8) : pal.fg2
                                font.family: pal.fam; font.pixelSize: 12
                            }
                            Text {
                                visible: rr.hasActions && rr.sel
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: "›"
                                color: "white"
                                font.pixelSize: 22
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                property string pressedResult: ""
                                property bool dragging: false
                                property real pressX: 0
                                property real pressY: 0
                                readonly property bool canDrag: rr.modelData && rr.modelData.kind === "file" && SettingsSearch.isLocalPath(rr.modelData.path)
                                function resultKey(item) { return JSON.stringify([item.title, item.sub, item.icon, item.glyph, item.kind, item.path || ""]); }
                                onEntered: { resPanel.pointerSelection = true; ui.spSel = rr.index; }
                                onPressed: mouse => {
                                    pressedResult = resultKey(rr.modelData);
                                    dragging = false;
                                    pressX = mouse.x;
                                    pressY = mouse.y;
                                }
                                onPositionChanged: mouse => {
                                    if (dragging || !pressed || !canDrag || mouse.buttons !== Qt.LeftButton) return;
                                    if (Math.abs(mouse.x - pressX) < 10 && Math.abs(mouse.y - pressY) < 10) return;
                                    dragging = true;
                                    rr.Drag.mimeData = { "text/uri-list": QuickLook.uriList(rr.modelData.path) };
                                    rr.Drag.active = true;
                                }
                                onCanceled: {
                                    if (rr.Drag.active) rr.Drag.active = false;
                                    dragging = false;
                                }
                                onClicked: mouse => {
                                    if (dragging) { dragging = false; return; }
                                    if (mouse.button === Qt.RightButton) { ui.spOpenActions(rr.modelData); return; }
                                    if (pressedResult === resultKey(rr.modelData)) ui.spActivate(rr.index);
                                }
                            }
                            MouseArea {
                                visible: rr.hasActions
                                z: 1
                                anchors.right: parent.right
                                width: 40; height: parent.height
                                hoverEnabled: true
                                Accessible.name: Language.I18n.text("spotlight.more_actions")
                                onClicked: ui.spOpenActions(rr.modelData)
                            }
                        }
                    }
                }
                }
            }

            // ── Clipboard history panel (macOS Tahoe style) ──
            Item {
                id: clipPanel
                opacity: ui.spMode === "clip" ? 1 : 0
                visible: opacity > 0
                scale: ui.spMode === "clip" ? 1 : 0.96
                transformOrigin: Item.Top
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                width: spot.width
                readonly property var items: ui.spMode === "clip" ? ui.spResults : []
                readonly property int rowH: 56
                readonly property int shown: Math.min(items.length, 7)
                readonly property string emptyTitle: bar.clipState === "missing" ? Language.I18n.text("ui.t_f948efee2fc6")
                    : (!bar.clipHistory ? Language.I18n.text("ui.t_98f3c171f27c")
                    : (bar.clipLoading && bar.clipEntries.length === 0 ? "Loading\u2026"
                    : (ui.spQuery.trim() !== "" ? Language.I18n.text("ui.t_ed805f62bdbf") : Language.I18n.text("ui.t_1c0006ee863c"))))
                readonly property string emptySub: bar.clipState === "missing" ? Language.I18n.text("ui.t_74ae71c81bcb")
                    : (!bar.clipHistory ? Language.I18n.text("ui.t_e49c6720db6f")
                    : (ui.spQuery.trim() === "" && !bar.clipLoading ? Language.I18n.text("ui.t_1bb86a09457d") : ""))
                height: 64 + (items.length > 0 ? shown * rowH + 14 : 118)
                Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                Item {
                    id: clipHeader
                    x: 20
                    width: parent.width - 40
                    height: 64
                    Rectangle {
                        id: clipChip
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34; height: 34; radius: 10
                        color: bar.accent
                        Glyph { anchors.centerIn: parent; width: 20; height: 20; kind: "clipboard"; color: "white" }
                    }
                    Text {
                        id: clipLabel
                        x: 46
                        anchors.verticalCenter: parent.verticalCenter
                        text: Language.I18n.text("ui.t_285d69f0c5d1")
                        color: pal.fg
                        font.family: pal.fam; font.pixelSize: 24; font.weight: Font.Medium
                    }
                    TextInput {
                        id: clipInput
                        x: clipLabel.x + clipLabel.width + 14
                        width: parent.width - x - 48
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        color: pal.fg
                        selectionColor: bar.accent
                        selectedTextColor: "white"
                        font.family: pal.fam; font.pixelSize: 24
                        onTextChanged: { if (ui.spMode === "clip") { ui.spQuery = text; ui.spSel = 0; } }
                        Keys.onPressed: event => ui.spKey(event)
                    }
                    CCBtn {
                        t: pal; gx: spg
                        d: 34
                        bounce: true
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        kind: "dots"
                        on: ui.clipMenu
                        onClicked: ui.clipMenu = !ui.clipMenu
                    }
                }

                ListView {
                    id: clipListView
                    x: 8; y: 64
                    width: parent.width - 16
                    height: clipPanel.shown * clipPanel.rowH
                    visible: clipPanel.items.length > 0
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: clipPanel.items
                    Connections {
                        target: ui
                        function onSpSelChanged() {
                            if (ui.spHover) { ui.spHover = false; return; }
                            if (ui.spMode === "clip" && clipPanel.items.length > 0)
                                clipListView.positionViewAtIndex(Math.min(ui.spSel, clipPanel.items.length - 1), ListView.Contain);
                        }
                    }
                    delegate: Item {
                        id: cr
                        required property var modelData
                        required property int index
                        readonly property bool sel: index === Math.min(ui.spSel, clipPanel.items.length - 1)
                        width: ListView.view.width
                        height: clipPanel.rowH
                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 2; anchors.bottomMargin: 2
                            radius: 16
                            color: bar.accent
                            opacity: cr.sel ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 90 } }
                        }
                        Item {
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: 36; height: 36
                            Rectangle {
                                visible: cr.modelData.kind === "text" || cr.modelData.kind === "url"
                                anchors.fill: parent
                                radius: 10
                                color: cr.sel ? Qt.rgba(1, 1, 1, 0.22) : (bar.darkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06))
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 20; height: 20
                                    kind: cr.modelData.kind === "url" ? "link" : "doc"
                                    color: cr.sel ? "white" : pal.fg2
                                }
                            }
                            Rectangle {
                                visible: cr.modelData.kind === "color"
                                anchors.fill: parent
                                radius: 10
                                color: cr.modelData.kind === "color" ? cr.modelData.color : "transparent"
                                border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.25)
                            }
                            Item {
                                visible: cr.modelData.kind === "image"
                                anchors.fill: parent
                                Rectangle { anchors.fill: parent; radius: 10; color: bar.darkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06) }
                                Image {
                                    anchors.fill: parent
                                    source: cr.modelData.kind === "image" ? cr.modelData.thumb : ""
                                    sourceSize: Qt.size(72, 72)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    layer.enabled: true
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: thMask
                                        maskThresholdMin: 0.5
                                        maskSpreadAtMin: 1.0
                                    }
                                }
                                Item {
                                    id: thMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: true
                                    Rectangle { anchors.fill: parent; radius: 10; color: "black" }
                                }
                            }
                        }
                        Text {
                            x: 62; y: 9
                            width: parent.width - 62 - 56
                            elide: Text.ElideRight
                            text: cr.modelData ? cr.modelData.title : ""
                            color: cr.sel ? "white" : pal.fg
                            font.family: pal.fam; font.pixelSize: 14
                        }
                        Text {
                            x: 62; y: 31
                            width: parent.width - 62 - 56
                            elide: Text.ElideRight
                            text: cr.modelData ? cr.modelData.sub : ""
                            color: cr.sel ? Qt.rgba(1, 1, 1, 0.8) : pal.fg2
                            font.family: pal.fam; font.pixelSize: 12
                        }
                        Glyph {
                            visible: cr.sel
                            anchors.right: parent.right
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18
                            kind: "return"; color: "white"
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            property point press: Qt.point(0, 0)
                            property bool dragged: false
                            onEntered: { if (ui.spSel !== cr.index) { ui.spHover = true; ui.spSel = cr.index; } }
                            onPressed: mouse => { press = mapToItem(spotRoot, mouse.x, mouse.y); dragged = false; }
                            onPositionChanged: mouse => {
                                if (!pressed) return;
                                var p = mapToItem(spotRoot, mouse.x, mouse.y);
                                if (!dragged && Math.abs(p.x - press.x) + Math.abs(p.y - press.y) > 14) { dragged = true; clipGhost.start(cr.modelData); }
                                if (dragged) { clipGhost.px = p.x; clipGhost.py = p.y; }
                            }
                            onReleased: mouse => {
                                if (!dragged) return;
                                var p = mapToItem(spotRoot, mouse.x, mouse.y);
                                // outside Spotlight = on the desktop → open it; inside → it flies back
                                var out = p.x < spot.x || p.x > spot.x + spot.width || p.y < spot.y || p.y > spot.y + spot.height;
                                clipGhost.drop(out);
                            }
                            onClicked: if (!dragged) ui.spActivate(cr.index)
                        }
                    }
                }

                Column {
                    visible: clipPanel.items.length === 0
                    x: 20; y: 64
                    width: parent.width - 40
                    height: 118
                    spacing: 6
                    topPadding: 30
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: clipPanel.emptyTitle
                        color: pal.fg
                        font.family: pal.fam; font.pixelSize: 15; font.weight: Font.Medium
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: clipPanel.emptySub
                        color: pal.fg2
                        font.family: pal.fam; font.pixelSize: 12
                    }
                }

                // the round "..." menu
                MouseArea { anchors.fill: parent; z: 4; visible: ui.clipMenu; onClicked: ui.clipMenu = false }
                Item {
                    id: clipMenuPop
                    z: 5
                    visible: ui.clipMenu
                    x: parent.width - width - 20
                    y: 58
                    width: 250
                    height: 3 * 40 + 12
                    GGlass { anchors.fill: parent; gx: spg; cornerR: 20; thickness: 22; strengthMul: 0.8; shadowAmt: 0.6 }
                    Column {
                        x: 6; y: 6
                        width: parent.width - 12
                        Repeater {
                            model: ["auto", "del", "clear"]
                            delegate: Item {
                                id: cm
                                required property string modelData
                                width: parent.width; height: 40
                                readonly property bool armedNow: modelData === "clear" && ui.armed === "clipclear"
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 14
                                    color: cm.armedNow ? "#FF453A" : bar.accent
                                    opacity: cmMa.containsMouse ? 1 : 0
                                }
                                Glyph {
                                    visible: cm.modelData === "auto" && bar.clipAutoPaste
                                    x: 12; anchors.verticalCenter: parent.verticalCenter
                                    width: 16; height: 16
                                    kind: "check"; color: cmMa.containsMouse ? "white" : pal.fg
                                }
                                Text {
                                    x: 38
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: cm.modelData === "auto" ? Language.I18n.text("ui.t_2ceb6ba917f4")
                                          : (cm.modelData === "del" ? Language.I18n.text("ui.t_6662750e0331")
                                          : (cm.armedNow ? Language.I18n.text("ui.t_1f8c95036230") : Language.I18n.text("ui.t_9768be40e931")))
                                    color: cmMa.containsMouse ? "white" : ((cm.modelData === "clear") ? "#FF453A" : pal.fg)
                                    font.family: pal.fam; font.pixelSize: 14
                                }
                                MouseArea {
                                    id: cmMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        if (cm.modelData === "auto") bar.clipAutoPaste = !bar.clipAutoPaste;
                                        else if (cm.modelData === "del") {
                                            var n = clipPanel.items.length;
                                            if (n > 0) bar.clipDelete(clipPanel.items[Math.min(ui.spSel, n - 1)]);
                                            ui.clipMenu = false;
                                        } else {
                                            if (ui.armed === "clipclear") { ui.armed = ""; bar.clipClear(); ui.clipMenu = false; }
                                            else ui.armed = "clipclear";
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Emoji panel ──
            Item {
                id: emojiPanel
                opacity: ui.spMode === "emoji" ? 1 : 0
                visible: opacity > 0
                scale: ui.spMode === "emoji" ? 1 : 0.96
                transformOrigin: Item.Top
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                width: spot.width
                readonly property int cell: 50
                readonly property int gridRows: 6
                readonly property var items: ui.spMode === "emoji" ? ui.spResults : []
                readonly property var cur: items[Math.min(ui.spSel, items.length - 1)]
                height: 64 + 42 + gridRows * cell + 46
                GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                Item {
                    x: 20
                    width: parent.width - 40
                    height: 64
                    Rectangle {
                        id: emojiChip
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34; height: 34; radius: 10
                        color: bar.accent
                        Glyph { anchors.centerIn: parent; width: 20; height: 20; kind: "smile"; color: "white" }
                    }
                    Text {
                        id: emojiLabel
                        x: 46
                        anchors.verticalCenter: parent.verticalCenter
                        text: Language.I18n.text("ui.t_61ad8976e650")
                        color: pal.fg
                        font.family: pal.fam; font.pixelSize: 24; font.weight: Font.Medium
                    }
                    TextInput {
                        id: emojiInput
                        x: emojiLabel.x + emojiLabel.width + 14
                        width: parent.width - x
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        color: pal.fg
                        selectionColor: bar.accent
                        selectedTextColor: "white"
                        font.family: pal.fam; font.pixelSize: 24
                        onTextChanged: { if (ui.spMode === "emoji") { ui.spQuery = text; ui.spSel = 0; } }
                        Keys.onPressed: event => ui.spKey(event)
                    }
                }

                // category tabs
                Row {
                    x: 20; y: 64
                    opacity: ui.spQuery.trim() === "" ? 1 : 0.35
                    Repeater {
                        model: ["\uD83D\uDD58", "\uD83D\uDE00", "\uD83E\uDDD1", "\uD83D\uDC3B", "\uD83C\uDF54", "\u2708\uFE0F", "\u26BD", "\uD83D\uDCA1", "\uD83D\uDD23", "\uD83C\uDFF3\uFE0F"]
                        delegate: Item {
                            id: tab
                            required property string modelData
                            required property int index
                            width: 60; height: 36
                            Rectangle {
                                anchors.centerIn: parent
                                width: 48; height: 32; radius: 12
                                color: bar.accent
                                opacity: (ui.emCat === tab.index && ui.spQuery.trim() === "") ? 0.9 : (tabMa.containsMouse ? 0.25 : 0)
                                Behavior on opacity { NumberAnimation { duration: 100 } }
                            }
                            Text {
                                anchors.centerIn: parent
                                text: tab.modelData
                                font.family: bar.emojiFont; font.pixelSize: 22
                            }
                            MouseArea {
                                id: tabMa
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    emojiInput.text = "";
                                    ui.emCat = tab.index; ui.spSel = 0;
                                    emojiInput.forceActiveFocus();
                                }
                            }
                        }
                    }
                }

                GridView {
                    id: emojiGrid
                    x: 20; y: 64 + 42
                    width: ui.emCols * emojiPanel.cell
                    height: emojiPanel.gridRows * emojiPanel.cell
                    cellWidth: emojiPanel.cell
                    cellHeight: emojiPanel.cell
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: emojiPanel.items
                    Connections {
                        target: ui
                        function onSpSelChanged() {
                            if (ui.spHover) { ui.spHover = false; return; }
                            if (ui.spMode === "emoji" && emojiPanel.items.length > 0)
                                emojiGrid.positionViewAtIndex(Math.min(ui.spSel, emojiPanel.items.length - 1), GridView.Contain);
                        }
                    }
                    delegate: Item {
                        id: ec
                        required property var modelData
                        required property int index
                        readonly property bool sel: index === Math.min(ui.spSel, emojiPanel.items.length - 1)
                        width: emojiPanel.cell; height: emojiPanel.cell
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width - 4; height: parent.height - 4
                            radius: 14
                            color: bar.accent
                            opacity: ec.sel ? 1 : 0
                        }
                        Text {
                            anchors.centerIn: parent
                            text: ec.modelData ? ec.modelData[0] : ""
                            font.family: bar.emojiFont; font.pixelSize: 36
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: { if (ui.spSel !== ec.index) { ui.spHover = true; ui.spSel = ec.index; } }
                            onClicked: { ui.pop = ""; bar.emojiPick(ec.modelData); }
                        }
                    }
                }
                Text {
                    visible: emojiPanel.items.length === 0
                    x: 20; y: 64 + 42
                    width: parent.width - 40
                    height: emojiPanel.gridRows * emojiPanel.cell
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: ui.spQuery.trim() !== "" ? Language.I18n.text("ui.t_ed805f62bdbf") : Language.I18n.text("ui.t_54670f28748a")
                    color: pal.fg2
                    font.family: pal.fam; font.pixelSize: 14
                }

                // footer: name of the highlighted emoji
                Item {
                    x: 20; y: parent.height - 46
                    width: parent.width - 40; height: 46
                    Rectangle { width: parent.width; height: 1; color: pal.sep }
                    Text {
                        x: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 180
                        elide: Text.ElideRight
                        text: emojiPanel.cur ? (emojiPanel.cur[0] + "  " + Language.I18n.emojiName(emojiPanel.cur[0], emojiPanel.cur[1])) : ""
                        color: pal.fg2
                        font.family: pal.fam; font.pixelSize: 13
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: bar.clipAutoPaste ? Language.I18n.text("ui.t_0b865d472eb3") : Language.I18n.text("ui.t_75245254fc6f")
                        color: pal.fg3
                        font.family: pal.fam; font.pixelSize: 12
                    }
                }
            }

            // ── Applications panel ──
            Item {
                id: appsPanel
                opacity: ui.spMode === "apps" ? 1 : 0
                visible: opacity > 0
                scale: ui.spMode === "apps" ? 1 : 0.96
                transformOrigin: Item.Top
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                width: spot.width
                height: Math.min(64 + appsCol.height + 14, 520)
                GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                Item {
                    id: appsHeader
                    x: 24
                    width: parent.width - 48
                    height: 64
                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24; height: 24
                        kind: "appstore"; color: pal.fg2
                    }
                    Text {
                        x: 40 + 3
                        anchors.verticalCenter: parent.verticalCenter
                        visible: appsInput.text === ""
                        text: Language.I18n.text("ui.t_98e33b0f3104")
                        color: pal.fg3
                        font.family: pal.fam; font.pixelSize: 24
                    }
                    TextInput {
                        id: appsInput
                        x: 40
                        width: parent.width - 40 - 48
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        color: pal.fg
                        selectionColor: bar.accent
                        selectedTextColor: "white"
                        font.family: pal.fam; font.pixelSize: 24
                        onTextChanged: { if (ui.spMode === "apps") { ui.spQuery = text; ui.spSel = 0; } }
                        Keys.onPressed: event => ui.spKey(event)
                    }
                    CCBtn {
                        t: pal; gx: spg
                        d: 34
                        bounce: true
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        kind: "dots"
                        onClicked: ui.spSetMode("home")
                    }
                }

                Flickable {
                    id: appsFlick
                    y: 64
                    width: parent.width
                    height: parent.height - 64 - 6
                    contentWidth: width
                    contentHeight: appsCol.height + 8
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: appsCol
                        x: 24
                        width: appsFlick.width - 48

                        Repeater {
                            id: appsRep
                            model: ui.spQuery.trim() === "" ? bar.appSections : bar.appSearchSection(ui.spQuery)
                            delegate: Column {
                                id: sec
                                required property var modelData
                                readonly property bool searching: ui.spQuery.trim() !== ""
                                readonly property bool expanded: searching || ui.spExpanded[modelData.name] === true
                                readonly property int shown: expanded ? modelData.apps.length : Math.min(5, modelData.apps.length)
                                width: appsCol.width

                                Rectangle { width: parent.width; height: 1; color: pal.sep }
                                Item {
                                    width: parent.width
                                    height: 38
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: sec.modelData.name
                                        color: pal.fg
                                        font.family: pal.fam; font.pixelSize: 13; font.weight: Font.Bold
                                    }
                                    Text {
                                        visible: !sec.searching && sec.modelData.apps.length > 5
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: sec.expanded ? Language.I18n.text("ui.t_0264d7b0ccb8") : Language.I18n.text("ui.t_ba8a80fdd737")
                                        color: bar.accent
                                        font.family: pal.fam; font.pixelSize: 12; font.weight: Font.Bold
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            onClicked: ui.spToggleSection(sec.modelData.name)
                                        }
                                    }
                                }
                                Grid {
                                    columns: 5
                                    Repeater {
                                        model: sec.shown
                                        delegate: Item {
                                            id: cell
                                            required property int index
                                            readonly property var e: sec.modelData.apps[index]
                                            width: appsCol.width / 5
                                            height: 96
                                                                                                                                                    Rectangle {
                                                anchors.fill: parent
                                                anchors.margins: 2
                                                radius: 16
                                                color: cma.containsMouse ? pal.hover : "transparent"
                                            }
                                            Image {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                y: 10
                                                width: 56; height: 56
                                                source: bar.iconSrc(cell.e.icon)
                                                sourceSize: Qt.size(128, 128)
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                                smooth: true
                                            }
                                            Text {
                                                y: 72
                                                width: parent.width - 8
                                                x: 4
                                                horizontalAlignment: Text.AlignHCenter
                                                elide: Text.ElideRight
                                                text: cell.e.name
                                                color: pal.fg
                                                font.family: pal.fam; font.pixelSize: 12
                                            }
                                            MouseArea {
                                                id: cma
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                onClicked: { ui.pop = ""; bar.launchApp(cell.e); }
                                            }
                                        }
                                    }
                                }
                                Item { width: 1; height: 10 }
                            }
                        }
                        Text {
                            visible: ui.spQuery.trim() !== "" && appsRep.count === 0
                            width: parent.width
                            height: 90
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: Language.I18n.text("ui.t_ed805f62bdbf")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 14
                        }
                    }
                }
            }
        }

    }
}
