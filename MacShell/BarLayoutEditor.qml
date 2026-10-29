import QtQuick
import "Locale" as Language
import QtQuick.Controls
import QtQuick.Window
import "BarLayout.js" as Layout
import "OutputProfiles.js" as Outputs

ControlMenu {
    id: root
    required property var controller
    property color accent: "#0a84ff"
    property var draft: ({common: [], outputs: {}, bindings: {}})
    property string baseToken: ""
    property bool dirty: false
    property bool conflict: false
    property bool confirmRecovery: false
    property string scope: "common"
    property real previewWidth: 1366
    property string dragId: ""
    property string focusOnMoveId: ""
    property string selectedId: ""
    property bool advanced: false
    readonly property var selectedEntry: entries.find(item => item.id === selectedId && item.enabled) || null
    readonly property var availableBlocks: controller.catalog.filter(block => block.repeatable || !entries.some(item => item.type === block.type && item.enabled))
    signal revealRequested(var item)
    ListModel { id: leftRows }
    ListModel { id: centerRows }
    ListModel { id: rightRows }
    function syncRows(model, zone) {
        var desired = entries.filter(item => item.zone === zone && item.enabled);
        for (var i = 0; i < desired.length; i++) {
            var item = desired[i], found = -1;
            for (var j = i; j < model.count; j++) if (model.get(j).blockId === item.id) { found = j; break; }
            var data = {blockId: item.id, blockType: item.type, blockEnabled: item.enabled, blockPriority: item.priority, blockWidth: item.type === "spacer" && item.width !== undefined ? item.width : 16};
            if (found < 0) model.insert(i, data);
            else { if (found !== i) model.move(found, i, 1); model.set(i, data); }
        }
        if (model.count > desired.length) model.remove(desired.length, model.count - desired.length);
    }
    function syncZones() { syncRows(leftRows, "left"); syncRows(centerRows, "center"); syncRows(rightRows, "right"); }
    onEntriesChanged: Qt.callLater(syncZones)
    Connections {
        target: root.Window.window
        function onActiveFocusItemChanged() {
            var item = root.Window.window.activeFocusItem, ancestor = item;
            while (ancestor && ancestor !== root) ancestor = ancestor.parent;
            if (ancestor === root && item) root.revealRequested(item);
        }
    }
    onScopeChanged: { selectedId = ""; Qt.callLater(() => { if (root.selected.output && root.selected.output.logicalRect) root.previewWidth = root.selected.output.logicalRect.width; }); }
    readonly property bool editable: controller.ready && !controller.pending && !controller.readOnly
    readonly property var scopes: {
        var result = [{key: "common", label: Language.I18n.text("ui.t_893d3edb9042")}], attached = [];
        controller.outputs.forEach(output => {
            result.push({key: "live:" + output.name, label: output.name + " · " + (output.model || "connected"), output: output});
            var match = Outputs.resolve(draft.outputs, output, controller.outputs, draft.bindings);
            if (match.id) attached.push(match.id);
        });
        Object.keys(draft.outputs).filter(key => attached.indexOf(key) < 0).forEach(key => result.push({key: "saved:" + key, label: draft.outputs[key].identity.connector + Language.I18n.text("ui.t_1b9e9f483dab"), id: key}));
        return result;
    }
    onScopesChanged: if (!scopes.some(item => item.key === scope)) Qt.callLater(() => { if (!root.scopes.some(item => item.key === root.scope)) root.scope = "common"; })
    readonly property var selected: scopes.find(item => item.key === scope) || scopes[0]
    readonly property var match: selected.output ? Outputs.resolve(draft.outputs, selected.output, controller.outputs, draft.bindings) : ({id: selected.id || "", ambiguous: false})
    readonly property string profileId: match.id || ""
    readonly property bool inherited: scope !== "common" && (!profileId || !draft.outputs[profileId] || !Array.isArray(draft.outputs[profileId].layout))
    readonly property var entries: { var profile = draft.outputs[profileId]; return scope === "common" || !profile || !Array.isArray(profile.layout) ? draft.common : profile.layout; }
    readonly property var savedIds: Object.keys(draft.outputs)
    function rebase() {
        if (!controller.ready) return;
        draft = Layout.clone(controller.values); baseToken = controller.token;
        dirty = false; conflict = false; confirmRecovery = false; selectedId = "";
    }
    function update(next) { draft = next; dirty = JSON.stringify(draft) !== JSON.stringify(controller.values); }
    function replaceEntries(items) {
        if (!editable || inherited) return;
        var next = Layout.clone(draft);
        if (scope === "common") next.common = items;
        else next.outputs[profileId].layout = items;
        update(next);
    }
    function customize() {
        if (!editable || scope === "common" || !profileId && !selected.output) return;
        var next = Layout.clone(draft), key = profileId;
        if (!key) {
            key = "display-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 9);
            next.outputs[key] = {identity: Outputs.identity(selected.output)};
            next.bindings[selected.output.name] = key;
        }
        next.outputs[key].layout = Layout.clone(next.common); update(next);
    }
    function inherit() { if (profileId && draft.outputs[profileId]) { var next = Layout.clone(draft); delete next.outputs[profileId].layout; update(next); } }
    function bindProfile(key) {
        if (!editable || !selected.output || !draft.outputs[key]) return;
        var next = Layout.clone(draft);
        next.outputs[key].identity = Outputs.identity(selected.output);
        Object.keys(next.bindings).forEach(name => { if (next.bindings[name] === key) delete next.bindings[name]; });
        next.bindings[selected.output.name] = key;
        update(next);
    }
    function change(id, key, value) {
        var items = Layout.clone(entries), item = items.find(entry => entry.id === id);
        if (item) { item[key] = value; replaceEntries(items); }
    }
    function move(id, zone, target) {
        var items = Layout.clone(entries), index = items.findIndex(item => item.id === id);
        if (index < 0 || ["left", "center", "right"].indexOf(zone) < 0) return;
        var item = items.splice(index, 1)[0];
        focusOnMoveId = item.zone !== zone ? id : ""; item.zone = zone;
        var peers = items.filter(entry => entry.zone === zone && entry.enabled), before = peers[Math.max(0, target)];
        var at = before ? items.findIndex(entry => entry.id === before.id) : items.length;
        items.splice(at, 0, item); replaceEntries(items);
    }
    function add(type) {
        var definition = controller.catalog.find(item => item.type === type);
        if (!definition) return;
        var existing = entries.find(item => item.type === type);
        if (!definition.repeatable && existing) {
            change(existing.id, "enabled", true); selectedId = existing.id; return;
        }
        var items = Layout.clone(entries);
        var id = definition.repeatable ? "spacer-" + Date.now() + "-" + Math.random().toString(36).slice(2, 7) : type;
        items.push({id: id, type: type, zone: definition.zone, enabled: true, priority: definition.priority});
        replaceEntries(items); selectedId = id;
    }
    function hideSelected() {
        if (!selectedEntry) return;
        if (selectedEntry.type === "spacer") replaceEntries(entries.filter(item => item.id !== selectedId));
        else change(selectedId, "enabled", false);
        selectedId = "";
    }
    function shortLabel(type) {
        return Language.I18n.legacy(({appMenus: Language.I18n.text("ui.t_bc5d8e3025d5"), monitoring: "Activity", tray: "Tray", keyboard: "Keyboard", wifi: "Wi-Fi", search: "Search", clock: "Clock", privacy: "Privacy", spacer: "Space"})[type] || Layout.label(controller.catalog, type));
    }
    function shiftSelected(offset) {
        if (!selectedEntry) return;
        var peers = entries.filter(item => item.zone === selectedEntry.zone && item.enabled);
        var index = peers.findIndex(item => item.id === selectedId);
        if (index + offset >= 0 && index + offset < peers.length) move(selectedId, selectedEntry.zone, index + offset);
    }
    function dropNear(id, target, zone, after) {
        if (id === target) return;
        var items = Layout.clone(entries), source = items.findIndex(item => item.id === id);
        if (source < 0) return;
        var item = items.splice(source, 1)[0], at = items.findIndex(entry => entry.id === target);
        if (at < 0) return;
        focusOnMoveId = item.zone !== zone ? id : "";
        item.zone = zone; items.splice(at + (after ? 1 : 0), 0, item); replaceEntries(items);
    }
    Component.onCompleted: { rebase(); controller.refresh(); }
    Connections {
        target: root.controller
        function onReadyChanged() { if (root.controller.ready && !root.dirty) root.rebase(); }
        function onTokenChanged() { if (!root.dirty) root.rebase(); else if (!root.controller.pending && root.controller.token !== root.baseToken) root.conflict = true; }
        function onFinished(success) { if (success) root.rebase(); else if (root.controller.token !== root.baseToken) root.conflict = true; }
    }
    contentItem: Column {
        spacing: 12
        Row {
            width: parent.width; spacing: 8
            Text {
                width: parent.width - cancelButton.width - applyButton.width - 16
                anchors.verticalCenter: parent.verticalCenter
                text: Language.I18n.text("ui.t_7bff2a544977"); color: root.foreground
                font.family: root.font.family; font.pixelSize: 17; font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            ControlButton { id: cancelButton; objectName: "barCancel"; text: Language.I18n.text("common.cancel"); enabled: !root.controller.pending && root.dirty; onClicked: root.rebase() }
            ControlButton { id: applyButton; objectName: "barApply"; text: root.controller.pending ? Language.I18n.text("ui.t_3329a9bb48b9") : Language.I18n.text("common.apply"); primary: true; enabled: root.editable && !root.conflict && (root.dirty || root.controller.needsRepair || root.controller.migrationPending); onClicked: root.controller.save(root.draft, root.baseToken) }
        }
        Text { width: parent.width; text: Language.I18n.text("ui.t_869cea78dbda"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Text {
            width: parent.width; visible: root.scope !== "common"
            text: root.selected.label + (root.inherited ? Language.I18n.text("ui.t_815b400d4059") : Language.I18n.text("ui.t_748fd19abe84"))
            color: root.accent; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap
        }
        Text { width: parent.width; visible: text !== ""; text: root.conflict ? Language.I18n.text("ui.t_2503c4ba43ff") : Language.I18n.legacy(root.controller.error || root.controller.notice); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        ControlButton { objectName: "barReload"; visible: root.conflict || !!root.controller.error; text: Language.I18n.text("language.reload"); enabled: !root.controller.pending; onClicked: { root.rebase(); root.controller.refresh(); } }
        Repeater {
            model: ["left", "center", "right"]
            delegate: Rectangle {
                id: zoneCard
                objectName: "barDropZone_" + modelData
                required property string modelData
                readonly property var blocks: root.entries.filter(item => item.zone === modelData && item.enabled)
                width: root.width; height: Math.max(50, chips.height + 20); radius: 10
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .035)
                border.width: 1
                border.color: zoneDrop.containsDrag ? root.accent : root.separator
                z: root.dragId && blocks.some(item => item.id === root.dragId) ? 2 : 0
                DropArea {
                    id: zoneDrop; anchors.fill: parent; enabled: root.editable && !root.inherited
                    onDropped: drop => {
                        if (!root.dragId) return;
                        var id = root.dragId, zone = zoneCard.modelData, at = zoneCard.blocks.length;
                        Qt.callLater(() => root.move(id, zone, at)); drop.acceptProposedAction();
                    }
                }
                Text {
                    x: 12; y: 18; width: 45
                    text: ({left: "Left", center: "Center", right: "Right"})[zoneCard.modelData]
                    color: root.secondary; font.family: root.font.family; font.pixelSize: 11
                }
                Text { x: 68; anchors.verticalCenter: parent.verticalCenter; visible: zoneCard.blocks.length === 0; text: Language.I18n.text("ui.t_4034ec9f457d"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                Flow {
                    id: chips; x: 68; y: 10; width: parent.width - 78; spacing: 6
                    Repeater {
                        model: zoneCard.modelData === "left" ? leftRows : zoneCard.modelData === "center" ? centerRows : rightRows
                        delegate: AbstractButton {
                            id: chip
                            required property string blockId
                            required property string blockType
                            required property bool blockEnabled
                            required property int blockPriority
                            required property int blockWidth
                            required property int index
                            objectName: "barItem_" + blockId
                            readonly property bool selected: root.selectedId === blockId
                            property point grabPoint: Qt.point(0, 0)
                            width: Math.min(chips.width, label.implicitWidth); height: 30
                            z: dragMouse.drag.active ? 2 : 0
                            enabled: root.editable && !root.inherited
                            focusPolicy: Qt.StrongFocus
                            Accessible.name: Language.I18n.legacy(Layout.label(root.controller.catalog, blockType))
                            Component.onCompleted: if (root.focusOnMoveId === blockId) { forceActiveFocus(); root.focusOnMoveId = ""; }
                            onClicked: root.selectedId = blockId
                            Keys.onReturnPressed: root.selectedId = blockId
                            Keys.onLeftPressed: event => { root.selectedId = blockId; root.shiftSelected(-1); event.accepted = true; }
                            Keys.onRightPressed: event => { root.selectedId = blockId; root.shiftSelected(1); event.accepted = true; }
                            Keys.onDeletePressed: { root.selectedId = blockId; root.hideSelected(); }
                            background: Rectangle {
                                radius: 7; color: chip.selected ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, .16) : root.dark ? "#35363b" : "#ffffff"
                                border.width: 1; border.color: chipDrop.containsDrag || chip.activeFocus || chip.selected ? root.accent : root.separator
                            }
                            contentItem: Text { id: label; leftPadding: 20; rightPadding: 10; text: root.shortLabel(chip.blockType); color: root.foreground; font.family: root.font.family; font.pixelSize: 11; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; opacity: chip.enabled ? 1 : .5 }
                            Text { x: 6; anchors.verticalCenter: parent.verticalCenter; text: "⠿"; color: root.secondary; font.pixelSize: 11 }
                            MouseArea {
                                id: dragMouse; objectName: "barDrag_" + chip.blockId
                                anchors.fill: parent; enabled: chip.enabled; cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                drag.target: dragGhost
                                drag.smoothed: false
                                onPressed: mouse => { chip.grabPoint = Qt.point(mouse.x, mouse.y); chip.forceActiveFocus(); root.selectedId = chip.blockId; root.dragId = chip.blockId; dragGhost.x = 0; dragGhost.y = 0; }
                                onClicked: root.selectedId = chip.blockId
                                onReleased: { dragGhost.Drag.drop(); root.dragId = ""; dragGhost.x = 0; dragGhost.y = 0; }
                                onCanceled: { root.dragId = ""; dragGhost.x = 0; dragGhost.y = 0; }
                            }
                            Rectangle {
                                id: dragGhost; width: chip.width; height: chip.height; radius: 7
                                color: root.accent; visible: dragMouse.drag.active
                                Drag.active: dragMouse.drag.active; Drag.source: dragGhost
                                Drag.hotSpot.x: chip.grabPoint.x; Drag.hotSpot.y: chip.grabPoint.y
                                Text { anchors.centerIn: parent; text: root.shortLabel(chip.blockType); color: "white"; font.family: root.font.family; font.pixelSize: 11 }
                            }
                            DropArea {
                                id: chipDrop; objectName: "barDropOn_" + chip.blockId
                                property bool insertAfter: false
                                anchors.fill: parent; enabled: chip.enabled
                                onEntered: drag => insertAfter = drag.x >= width / 2
                                onPositionChanged: drag => insertAfter = drag.x >= width / 2
                                Rectangle { x: chipDrop.insertAfter ? parent.width - 1 : -1; width: 2; height: parent.height; radius: 1; color: root.accent; visible: chipDrop.containsDrag && root.dragId !== chip.blockId }
                                onDropped: drop => {
                                    if (!root.dragId) return;
                                    var id = root.dragId, target = chip.blockId, zone = zoneCard.modelData, after = drop.x >= width / 2;
                                    Qt.callLater(() => root.dropNear(id, target, zone, after)); drop.acceptProposedAction();
                                }
                            }
                        }
                    }
                }
            }
        }
        Rectangle {
            width: parent.width; height: selectionControls.height + 20; radius: 10
            visible: !!root.selectedEntry
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, .06)
            Column {
                id: selectionControls; x: 10; y: 10; width: parent.width - 20; spacing: 8
                Row {
                    width: parent.width; spacing: 6
                    Text { width: parent.width - hideButton.width - 6; anchors.verticalCenter: parent.verticalCenter; text: root.selectedEntry ? Language.I18n.legacy(Layout.label(root.controller.catalog, root.selectedEntry.type)) : ""; color: root.foreground; font.family: root.font.family; font.pixelSize: 12; elide: Text.ElideRight }
                    ControlButton { id: hideButton; objectName: "barHide"; text: Language.I18n.text("ui.t_ac20a57bfde0"); enabled: root.editable && !root.inherited; onClicked: root.hideSelected() }
                }
                Row {
                    width: parent.width; spacing: 6
                    ControlComboBox {
                        objectName: "barSelectedZone"; width: Math.max(90, parent.width - earlierButton.width - laterButton.width - 12)
                        model: [Language.I18n.text("ui.t_58eb9032e3bb"), Language.I18n.text("ui.t_d946067427e9"), Language.I18n.text("ui.t_883361d5d682")]; currentIndex: root.selectedEntry ? ["left", "center", "right"].indexOf(root.selectedEntry.zone) : 0
                        enabled: root.editable && !root.inherited && !!root.selectedEntry
                        onActivated: i => root.move(root.selectedId, ["left", "center", "right"][i], 999)
                    }
                    ControlButton { id: earlierButton; objectName: "barEarlier"; text: "←"; implicitWidth: 38; Accessible.name: Language.I18n.text("ui.t_4495e77129ed"); enabled: root.editable && !root.inherited && !!root.selectedEntry && root.entries.filter(item => item.zone === root.selectedEntry.zone && item.enabled)[0].id !== root.selectedId; onClicked: root.shiftSelected(-1) }
                    ControlButton { id: laterButton; objectName: "barLater"; text: "→"; implicitWidth: 38; Accessible.name: Language.I18n.text("ui.t_b386d0a31ca0"); enabled: root.editable && !root.inherited && !!root.selectedEntry && root.entries.filter(item => item.zone === root.selectedEntry.zone && item.enabled).slice(-1)[0].id !== root.selectedId; onClicked: root.shiftSelected(1) }
                }
            }
        }
        Row {
            width: parent.width; spacing: 8
            ControlButton {
                id: addButton; objectName: "barAdd"; text: Language.I18n.text("ui.t_d8af7430df31"); enabled: root.editable && !root.inherited && root.availableBlocks.length > 0
                onClicked: addPopup.open()
                Popup {
                    id: addPopup; objectName: "barAddPopup"; y: addButton.height + 5; width: Math.min(260, root.width); padding: 6
                    focus: true; margins: 8
                    height: Math.min(312, addList.implicitHeight + 12)
                    onOpened: Qt.callLater(() => { var first = addRepeater.itemAt(0); if (first) first.forceActiveFocus(); })
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    background: Rectangle { radius: 10; color: root.palette.window; border.color: root.separator }
                    contentItem: ScrollView {
                        id: addScroll
                        clip: true; contentWidth: availableWidth
                        Column {
                            id: addList; width: parent.width; spacing: 3
                            Repeater {
                                id: addRepeater
                                model: root.availableBlocks
                                delegate: ControlButton {
                                    required property var modelData
                                    width: addList.width; objectName: "barAdd_" + modelData.type; text: "+  " + Language.I18n.legacy(modelData.label)
                                    Keys.onReturnPressed: clicked()
                                    onActiveFocusChanged: if (activeFocus) {
                                        var flick = addScroll.contentItem;
                                        if (y < flick.contentY) flick.contentY = y;
                                        else if (y + height > flick.contentY + flick.height) flick.contentY = y + height - flick.height;
                                    }
                                    onClicked: { var type = modelData.type; addPopup.close(); root.add(type); }
                                }
                            }
                        }
                    }
                }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: root.dirty ? Language.I18n.text("ui.t_a710c2b90913") : ""; color: root.secondary; font.family: root.font.family; font.pixelSize: 11 }
        }
        ControlButton { objectName: "barAdvanced"; text: (root.advanced ? "▾" : "▸") + Language.I18n.text("ui.t_078c987eb6be"); onClicked: root.advanced = !root.advanced }
        Column {
            width: parent.width; spacing: 12; visible: root.advanced
            Text { text: Language.I18n.text("ui.t_34e108c0896d"); color: root.foreground; font.family: root.font.family; font.pixelSize: 12; font.weight: Font.DemiBold }
            ControlComboBox {
                objectName: "barLayoutScope"; width: parent.width; enabled: !root.controller.pending
                model: root.scopes; textRole: "label"
                currentIndex: Math.max(0, root.scopes.findIndex(item => item.key === root.scope))
                onActivated: index => { root.selectedId = ""; root.scope = root.scopes[index].key; }
            }
            Text { width: parent.width; visible: root.inherited; text: root.match.ambiguous ? Language.I18n.text("ui.t_bff172eb236d") : Language.I18n.text("ui.t_704a7fab4434"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            ControlButton { objectName: "barCustomize"; visible: root.scope !== "common" && root.inherited; text: Language.I18n.text("ui.t_efe0a935c383"); enabled: root.editable; onClicked: root.customize() }
            ControlButton { objectName: "barInherit"; visible: root.scope !== "common" && !root.inherited; text: Language.I18n.text("ui.t_ec2af69450c7"); enabled: root.editable; onClicked: root.inherit() }
            Column {
                width: parent.width; visible: !!root.selected.output && root.inherited && root.savedIds.length > 0; spacing: 8
                ControlComboBox { id: savedProfile; width: parent.width; model: root.savedIds.map(key => ({key: key, label: root.draft.outputs[key].identity.connector + " · " + (root.draft.outputs[key].identity.model || key)})); textRole: "label" }
                ControlButton { text: Language.I18n.text("ui.t_54ad8452d92a"); enabled: root.editable; onClicked: root.bindProfile(root.savedIds[savedProfile.currentIndex]) }
            }
            Column {
                width: parent.width; visible: !!root.selectedEntry; spacing: 8
                Text { text: Language.I18n.text("ui.t_37466d35fdbb"); color: root.foreground; font.family: root.font.family; font.pixelSize: 12; font.weight: Font.DemiBold }
                Text { width: parent.width; text: Language.I18n.text("ui.t_7b4cc146e625"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
                Row {
                    spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_d60dbba07922"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                    SpinBox { objectName: "barSelectedPriority"; width: 110; from: 0; to: 100; value: root.selectedEntry ? root.selectedEntry.priority : 0; editable: true; enabled: root.editable && !root.inherited; Accessible.name: Language.I18n.text("ui.t_543340942a33"); onValueModified: root.change(root.selectedId, "priority", value) }
                }
                Row {
                    spacing: 8; visible: !!root.selectedEntry && root.selectedEntry.type === "spacer"
                    Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_c10ce42aa769"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                    SpinBox { objectName: "barSelectedWidth"; width: 110; from: 0; to: 240; value: root.selectedEntry && root.selectedEntry.width !== undefined ? root.selectedEntry.width : 16; enabled: root.editable && !root.inherited; Accessible.name: Language.I18n.text("ui.t_ed3507e12ab6"); onValueModified: root.change(root.selectedId, "width", value) }
                }
            }
            Text { text: Language.I18n.text("ui.t_324b134f57c7"); color: root.foreground; font.family: root.font.family; font.pixelSize: 12; font.weight: Font.DemiBold }
            Row {
                spacing: 8
                Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_317f934a4656"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                SpinBox { objectName: "barPreviewWidth"; from: 240; to: 7680; stepSize: 50; value: root.previewWidth; editable: true; onValueModified: root.previewWidth = value; Accessible.name: Language.I18n.text("ui.t_8e995ec1154a") }
            }
            BarLayoutPreview { width: parent.width; layout: root.entries; catalog: root.controller.catalog; logicalWidth: root.previewWidth; widgetScale: root.controller.widgetScale || 1; foreground: root.foreground; accent: root.accent }
            ControlButton { objectName: "barReset"; text: Language.I18n.text("ui.t_c82de9851ad7"); enabled: root.editable && !root.inherited; onClicked: { root.replaceEntries(Layout.defaults(root.controller.catalog)); root.selectedId = ""; } }
        }
        Column {
            spacing: 8; visible: root.controller.canRecover
            ControlButton { text: Language.I18n.text("ui.t_15efa04829c4"); enabled: !root.controller.pending; visible: !root.confirmRecovery; onClicked: root.confirmRecovery = true }
            Row {
                spacing: 8; visible: root.confirmRecovery
                ControlButton { text: Language.I18n.text("ui.t_5b55363005a0"); enabled: !root.controller.pending; onClicked: root.controller.recover(root.controller.token) }
                ControlButton { text: Language.I18n.text("common.cancel"); enabled: !root.controller.pending; onClicked: root.confirmRecovery = false }
            }
        }
    }
}
