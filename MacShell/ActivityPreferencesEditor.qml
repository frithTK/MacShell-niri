import QtQuick
import QtQuick.Controls
import "PreferenceFields.js" as Fields

ControlMenu {
    id: root
    required property var controller
    property color accent: "#0a84ff"
    property var draft: ({})
    property string baseToken: ""
    property bool dirty: false
    property bool conflict: false
    property bool advanced: false
    property bool confirmRecovery: false
    property string focusKey: ""
    property int focusSerial: 0
    property string highlightedKey: ""
    readonly property var issues: Fields.validate(controller.fields, draft)
    readonly property bool editable: controller.ready && !controller.readOnly && !controller.pending
    readonly property bool needsWrite: !!controller.needsRepair || !!controller.migrationPending
    readonly property var visibleFields: controller.fields.filter(field => !field.advanced || root.advanced)
    signal revealRequested(var item)
    function rebase() {
        if (!controller.ready) return;
        draft = Fields.clone(controller.values);
        baseToken = controller.token;
        dirty = false; conflict = false; confirmRecovery = false;
    }
    function change(key, value) {
        var next = Fields.clone(draft);
        next[key] = value;
        draft = next;
        dirty = JSON.stringify(draft) !== JSON.stringify(controller.values);
    }
    function resetField(field) { change(field.key, Fields.clone(field.default)); }
    function resetAll() {
        var next = Fields.clone(draft), values = Fields.defaults(controller.fields);
        Object.keys(values).forEach(key => next[key] = values[key]);
        draft = next;
        dirty = JSON.stringify(draft) !== JSON.stringify(controller.values);
    }
    function moveMetric(index, direction) {
        var next = (draft.order || []).slice(), target = index + direction;
        if (target < 0 || target >= next.length) return;
        var swap = next[index]; next[index] = next[target]; next[target] = swap;
        change("order", next);
    }
    function requestFocus() {
        if (!focusKey) return;
        if (controller.fields.some(field => field.key === focusKey && field.advanced)) advanced = true;
        highlightedKey = focusKey;
        revealSoon.restart();
        clearHighlight.restart();
    }
    onFocusKeyChanged: requestFocus()
    onFocusSerialChanged: requestFocus()
    Component.onCompleted: { rebase(); controller.refresh(); requestFocus(); }
    Connections {
        target: root.controller
        function onReadyChanged() { if (root.controller.ready && !root.dirty) { root.rebase(); root.requestFocus(); } }
        function onTokenChanged() {
            if (!root.dirty) root.rebase();
            else if (root.controller.token !== root.baseToken && !root.controller.pending) root.conflict = true;
        }
        function onFinished(success) {
            if (success) root.rebase();
            else if (root.controller.token !== root.baseToken) root.conflict = true;
        }
    }
    Timer {
        id: revealSoon; interval: 50
        onTriggered: {
            for (var i = 0; i < rows.count; i++) {
                var item = rows.itemAt(i);
                if (item && item.modelData.key === root.focusKey) { root.revealRequested(item); return; }
            }
        }
    }
    Timer { id: clearHighlight; interval: 2400; onTriggered: root.highlightedKey = "" }
    QtObject {
        id: preview
        readonly property var sample: ({cpu: 78, memory: {used: 12369505812, total: 17179869184}, network: [524288, 65536], disk: [25165824, 1048576]})
        readonly property bool stale: false
        function gib(v) { return (v / 1073741824).toFixed(1); }
        function rate(v) {
            var units = ["B", "K", "M", "G"], i = 0;
            while (v >= 1000 && i < 3) { v /= 1000; i++; }
            return (v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + units[i];
        }
    }
    contentItem: Column {
        spacing: 12
        Text { width: parent.width; text: "Activity appearance"; color: root.foreground; font.family: root.font.family; font.pixelSize: 17; font.weight: Font.DemiBold }
        Text { width: parent.width; text: "Preview changes here, then Apply to update the menu bar."; color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Rectangle {
            width: parent.width; height: 65; radius: 10
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06)
            Text { x: 12; y: 12; text: "Sample data · CPU 78% · Memory 72%"; color: root.secondary; font.family: root.font.family; font.pixelSize: 11 }
            SystemStatsBar {
                objectName: "activityAppearancePreview"
                anchors.right: parent.right; anchors.rightMargin: 12; y: 30
                controller: preview; foreground: root.foreground; fontFamily: root.font.family
                appearance: root.draft; tooltipsEnabled: true; budget: 250
            }
        }
        Text { width: parent.width; visible: !root.controller.ready; text: "Loading Activity settings…"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
        Text {
            objectName: "activityPreferencesNotice"
            width: parent.width; visible: text !== ""; wrapMode: Text.Wrap
            text: root.conflict ? "Activity settings changed elsewhere. Reload to review the latest values before applying." : root.controller.error || root.controller.notice
            color: root.secondary; font.family: root.font.family; font.pixelSize: 12
        }
        Row {
            spacing: 8
            ControlButton { objectName: "activityReload"; text: "Reload"; enabled: !root.controller.pending; onClicked: { root.rebase(); root.controller.refresh(); } }
            ControlButton { objectName: "activityRecovery"; visible: root.controller.canRecover; text: "Restore defaults…"; enabled: !root.controller.pending; onClicked: root.confirmRecovery = true }
        }
        Column {
            visible: root.confirmRecovery; width: parent.width; spacing: 8
            Text { width: parent.width; text: "Restore Activity appearance defaults? The original file will be kept in a recovery copy."; wrapMode: Text.Wrap; color: root.foreground; font.family: root.font.family; font.pixelSize: 12 }
            Row {
                spacing: 8
                ControlButton { objectName: "activityConfirmRecovery"; text: "Restore defaults"; primary: true; enabled: !root.controller.pending; onClicked: root.controller.recover(root.controller.token) }
                ControlButton { text: "Cancel"; enabled: !root.controller.pending; onClicked: root.confirmRecovery = false }
            }
        }
        Row {
            spacing: 10; visible: root.controller.ready
            ControlSwitch { objectName: "activityAdvanced"; implicitWidth: 38; checked: root.advanced; onToggled: root.advanced = checked }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Advanced · CPU and memory thresholds"; color: root.foreground; font.family: root.font.family; font.pixelSize: 12 }
        }
        Repeater {
            id: rows
            model: root.visibleFields
            delegate: Rectangle {
                id: fieldRow
                required property var modelData
                objectName: "activitySetting_" + modelData.key
                width: root.width; height: fieldContents.height + 20; radius: 10
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .04)
                border.width: root.highlightedKey === modelData.key ? 1 : 0
                border.color: root.accent
                Column {
                    id: fieldContents
                    x: 10; y: 10; width: parent.width - 20; spacing: 6
                    Row {
                        width: parent.width
                        Text { width: parent.width - 68; anchors.verticalCenter: parent.verticalCenter; text: fieldRow.modelData.label + (fieldRow.modelData.unit ? " · " + fieldRow.modelData.unit : ""); color: root.foreground; font.family: root.font.family; font.pixelSize: 12; font.weight: Font.DemiBold }
                        ControlButton { objectName: "activityReset_" + fieldRow.modelData.key; text: "Reset"; implicitWidth: 60; implicitHeight: 26; enabled: root.editable; onClicked: root.resetField(fieldRow.modelData) }
                    }
                    Text { width: parent.width; text: fieldRow.modelData.description; color: root.secondary; font.family: root.font.family; font.pixelSize: 11; wrapMode: Text.Wrap }
                    SpinBox {
                        objectName: "activityThreshold_" + fieldRow.modelData.key
                        visible: fieldRow.modelData.type === "integer"
                        enabled: root.editable
                        from: fieldRow.modelData.minimum || 0; to: fieldRow.modelData.maximum || 100
                        value: fieldRow.modelData.type === "integer" && typeof root.draft[fieldRow.modelData.key] === "number" ? root.draft[fieldRow.modelData.key] : 0
                        editable: true
                        onValueModified: root.change(fieldRow.modelData.key, value)
                        Accessible.name: fieldRow.modelData.label
                    }
                    ControlComboBox {
                        objectName: "activityChoice_" + fieldRow.modelData.key
                        visible: fieldRow.modelData.type === "choice"
                        enabled: root.editable; width: Math.min(250, parent.width)
                        model: fieldRow.modelData.choices || []
                        textRole: "label"
                        currentIndex: (fieldRow.modelData.choices || []).findIndex(choice => choice.value === root.draft[fieldRow.modelData.key])
                        onActivated: index => root.change(fieldRow.modelData.key, fieldRow.modelData.choices[index].value)
                        Accessible.name: fieldRow.modelData.label
                    }
                    Column {
                        visible: fieldRow.modelData.type === "order"
                        width: parent.width; spacing: 4
                        Repeater {
                            model: fieldRow.modelData.type === "order" ? root.draft.order || [] : []
                            delegate: Row {
                                required property string modelData
                                required property int index
                                width: parent.width; spacing: 6
                                Text { width: parent.width - 118; anchors.verticalCenter: parent.verticalCenter; text: ({cpu: "CPU", memory: "Memory", network: "Network", disk: "Disk"})[modelData]; color: root.foreground; font.family: root.font.family; font.pixelSize: 12 }
                                ControlButton { objectName: "activityOrderUp_" + parent.modelData; text: "↑"; implicitWidth: 50; implicitHeight: 28; enabled: root.editable && parent.index > 0; Accessible.name: "Move " + parent.modelData + " up"; onClicked: root.moveMetric(parent.index, -1) }
                                ControlButton { objectName: "activityOrderDown_" + parent.modelData; text: "↓"; implicitWidth: 50; implicitHeight: 28; enabled: root.editable && parent.index < root.draft.order.length - 1; Accessible.name: "Move " + parent.modelData + " down"; onClicked: root.moveMetric(parent.index, 1) }
                            }
                        }
                    }
                    Text { width: parent.width; visible: text !== ""; text: root.issues[fieldRow.modelData.key] || ""; color: root.dark ? "#ff9b91" : "#b83229"; font.family: root.font.family; font.pixelSize: 11; wrapMode: Text.Wrap }
                }
            }
        }
        Row {
            spacing: 8
            ControlButton { objectName: "activityResetAll"; text: "Reset section"; enabled: root.editable; onClicked: root.resetAll() }
            ControlButton { objectName: "activityCancel"; text: "Cancel"; enabled: !root.controller.pending && root.dirty; onClicked: root.rebase() }
            ControlButton { objectName: "activityApply"; text: root.controller.pending ? "Applying…" : "Apply"; primary: true; enabled: root.editable && (root.dirty || root.needsWrite) && !root.conflict && Object.keys(root.issues).length === 0; onClicked: root.controller.save(root.draft, root.baseToken) }
        }
        Text { width: parent.width; text: "Selected metrics, update interval and devices are configured in Menu Bar → Activity Monitor."; color: root.secondary; font.family: root.font.family; font.pixelSize: 11; wrapMode: Text.Wrap }
    }
}
