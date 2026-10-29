import QtQuick
import "Locale" as Language
import QtQuick.Controls
import QtQuick.Window
import "WidgetCatalog.js" as Catalog

ControlMenu {
    id: root
    required property var controller
    property color accent: "#0a84ff"
    palette.highlight: accent
    property string selectedType: "weather"
    property string selectedSize: "small"
    property string selectedStyle: "liquid"
    property bool advanced: false
    property string status: ""
    property bool confirmRecovery: false
    property string selectedOutput: ""
    property bool adding: false
    property string focusInstanceId: ""
    property int focusSerial: 0
    function focusInstance() {
        if (!focusInstanceId) return;
        adding = false; instances.selectAndFocus(focusInstanceId);
    }
    onFocusSerialChanged: Qt.callLater(focusInstance)
    readonly property bool editorOpen: visible && !!root.Window.window && root.Window.window.visible
    function updateSession(open) {
        if (controller && typeof controller.setEditorOpen === "function") controller.setEditorOpen("settings", open);
    }
    onEditorOpenChanged: updateSession(editorOpen)
    Component.onCompleted: { updateSession(editorOpen); Qt.callLater(focusInstance); }
    Component.onDestruction: updateSession(false)
    readonly property var displayChoices: controller && controller.displayChoices ? controller.displayChoices : []
    readonly property string effectiveOutput: displayChoices.some(item => item.name === selectedOutput) ? selectedOutput
        : controller && displayChoices.some(item => item.name === controller.screenName) ? controller.screenName
        : displayChoices.length ? displayChoices[0].name : ""
    signal revealRequested(var item)
    Connections {
        target: root.Window.window
        function onActiveFocusItemChanged() {
            var item = root.Window.window.activeFocusItem, ancestor = item;
            while (ancestor && ancestor !== root) ancestor = ancestor.parent;
            if (ancestor === root && item) root.revealRequested(item);
        }
    }
    readonly property var definition: Catalog.find(selectedType)
    readonly property var footprint: Catalog.dimensions(selectedSize)
    readonly property bool canAdd: !!controller && controller.editable && !!definition
    readonly property int placedCount: {
        var revision = controller ? controller.rev : 0;
        return controller ? controller.count(selectedType) : 0;
    }
    onSelectedTypeChanged: { selectedStyle = "liquid"; status = ""; }
    onSelectedSizeChanged: status = ""
    onSelectedStyleChanged: status = ""
    Connections {
        target: root.controller; ignoreUnknownSignals: true
        function onMutationFinished(success) { root.status = success ? Language.I18n.text("ui.t_12b3f1a3e924") : ""; root.confirmRecovery = false; }
    }
    function add() {
        if (!canAdd) return;
        status = controller.addWidget(selectedType, selectedStyle, selectedSize, effectiveOutput)
            ? (controller.pending ? Language.I18n.text("ui.t_8f5ddf11abe9") : Language.I18n.legacy(definition.label) + Language.I18n.text("ui.t_e5e0d20e2486"))
            : Language.I18n.text("ui.t_6d0144f5651c");
    }
    contentItem: Column {
        width: root.width; spacing: 12
        Row {
            width: parent.width; spacing: 8
            Text { width: parent.width - editButton.width - visibilitySwitch.width - 16; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_7ea4f0f4af9f"); color: root.foreground; font.family: root.font.family; font.pixelSize: 17; font.weight: Font.DemiBold; elide: Text.ElideRight }
            ControlSwitch {
                id: visibilitySwitch; objectName: "widgetsEnabled"; anchors.verticalCenter: parent.verticalCenter
                checked: !!root.controller && root.controller.widgetsEnabled !== false
                enabled: !!root.controller && root.controller.settingsEditable
                Accessible.name: Language.I18n.text("ui.t_78b13ef8776b")
                onToggled: if (root.controller) root.controller.setWidgetsEnabled(checked)
            }
            ControlButton { id: editButton; objectName: "widgetsEdit"; text: root.controller && root.controller.editing ? Language.I18n.text("ui.t_058f24ef2d7c") : Language.I18n.text("ui.t_a8515544675c"); enabled: !!root.controller && root.controller.editable && root.controller.widgetsEnabled !== false; onClicked: root.controller.editing = !root.controller.editing }
        }
        Row {
            spacing: 6
            ControlButton { objectName: "widgetsManageTab"; text: Language.I18n.text("ui.t_32ad1024f09f"); primary: !root.adding; onClicked: root.adding = false }
            ControlButton { objectName: "widgetsAddTab"; text: Language.I18n.text("ui.t_5ab344046cec"); primary: root.adding; onClicked: root.adding = true }
        }
        Text { width: parent.width; visible: text !== ""; text: root.controller ? Language.I18n.legacy(root.controller.error || root.controller.notice) : ""; color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Row {
            spacing: 8; visible: !!root.controller && (!!root.controller.error || root.controller.readOnly)
            ControlButton { objectName: "widgetsReload"; text: Language.I18n.text("language.reload"); enabled: !!root.controller && !root.controller.pending; onClicked: root.controller.reloadSettings() }
            ControlButton { objectName: "widgetsRestore"; text: Language.I18n.text("ui.t_1b5b84085a2b"); visible: !!root.controller && root.controller.canRecover && !root.confirmRecovery; enabled: !!root.controller && !root.controller.pending; onClicked: root.confirmRecovery = true }
        }
        Column {
            width: parent.width; spacing: 8; visible: root.confirmRecovery
            Text { width: parent.width; text: Language.I18n.text("ui.t_efe9e1ebce77"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            Row {
                spacing: 8
                ControlButton { objectName: "widgetsConfirmRestore"; text: Language.I18n.text("ui.t_7f0e04dbe6e8"); enabled: !!root.controller && !root.controller.pending; onClicked: root.controller.recoverSettings() }
                ControlButton { text: Language.I18n.text("common.cancel"); onClicked: root.confirmRecovery = false }
            }
        }
        WidgetInstances {
            id: instances
            objectName: "widgetInstances"; width: parent.width; visible: !root.adding
            controller: root.controller; foreground: root.foreground; accent: root.accent; font.family: root.font.family
            onAddRequested: root.adding = true
        }
        Column {
            width: parent.width; spacing: 12; visible: root.adding
            Text { width: parent.width; text: Language.I18n.text("ui.t_973de64f8677"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            Column {
                width: parent.width; spacing: 6; visible: root.displayChoices.length > 1
                Text { text: Language.I18n.text("ui.t_06b607b65ce9"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                ControlComboBox {
                    objectName: "widgetOutput"; width: parent.width
                    model: root.displayChoices; textRole: "label"
                    currentIndex: Math.max(0, root.displayChoices.findIndex(item => item.name === root.effectiveOutput))
                    Accessible.name: Language.I18n.text("ui.t_4f9399fe2391")
                    onActivated: index => { root.selectedOutput = model[index].name; root.status = ""; }
                }
            }
            Flow {
                width: parent.width; spacing: 6
                Repeater {
                    model: Catalog.types
                    delegate: ControlButton {
                        required property var modelData
                        objectName: "widgetType_" + modelData.type
                        text: Language.I18n.legacy(modelData.label); primary: root.selectedType === modelData.type
                        onClicked: root.selectedType = modelData.type
                    }
                }
            }
            Rectangle {
                width: parent.width; height: 236; radius: 12
                color: root.dark ? "#2b2c32" : "#e7e8ee"
                border.color: root.separator; clip: true
                Item {
                    anchors.fill: parent; anchors.topMargin: 26; anchors.bottomMargin: 48
                    Item {
                        anchors.centerIn: parent; width: root.footprint[0]; height: root.footprint[1]
                        scale: Math.min(1, (parent.width - 32) / width, parent.height / height)
                        WidgetPreview { id: preview; objectName: "widgetSample"; anchors.fill: parent; widgetType: root.selectedType; widgetSize: root.selectedSize; widgetStyle: root.selectedStyle; dark: root.dark; family: root.font.family }
                    }
                }
                Text { anchors.top: parent.top; anchors.topMargin: 8; anchors.horizontalCenter: parent.horizontalCenter; text: Language.I18n.text("ui.t_39d399369a10"); color: root.secondary; font.family: root.font.family; font.pixelSize: 10 }
                Row {
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 8; anchors.horizontalCenter: parent.horizontalCenter; spacing: 6
                    Repeater {
                        model: Catalog.sizes
                        delegate: ControlButton {
                            required property var modelData
                            objectName: "widgetSize_" + modelData.key
                            text: Language.I18n.legacy(modelData.label); primary: root.selectedSize === modelData.key
                            enabled: !!root.definition && root.definition.sizes.indexOf(modelData.key) >= 0
                            onClicked: root.selectedSize = modelData.key
                        }
                    }
                }
            }
            Row {
                width: parent.width; spacing: 8
                ControlComboBox {
                    id: styleChoice
                    objectName: "widgetStyle"; width: Math.min(190, parent.width - addButton.width - 8)
                    model: root.definition ? root.definition.styles.map(key => ({key: key, label: Language.I18n.legacy(Catalog.styles[key])})) : []
                    textRole: "label"
                    currentIndex: root.definition ? Math.max(0, root.definition.styles.indexOf(root.selectedStyle)) : 0
                    Accessible.name: Language.I18n.text("ui.t_1508e3ec8202")
                    onActivated: index => root.selectedStyle = model[index].key
                }
                Item { width: Math.max(0, parent.width - styleChoice.width - addButton.width - 16); height: 1 }
                ControlButton { id: addButton; objectName: "widgetAdd"; text: Language.I18n.text("ui.t_ac18a779157d"); primary: true; enabled: root.canAdd; onClicked: root.add() }
            }
            Text { width: parent.width; text: root.status || (root.definition ? Language.I18n.legacy(root.definition.description) + " · " + root.placedCount + Language.I18n.text("ui.t_9bb3fa87357c") : Language.I18n.text("ui.t_7ca8cf3a37ce")); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
        ControlButton { objectName: "widgetsAdvanced"; text: (root.advanced ? "▾" : "▸") + Language.I18n.text("ui.t_f4077f9a9cff"); onClicked: root.advanced = !root.advanced }
        Column {
            width: parent.width; spacing: 12; visible: root.advanced
            Text { width: parent.width; text: Language.I18n.legacy(Catalog.find("weather").shared); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            Column {
                width: parent.width; spacing: 8
                Text { text: Language.I18n.text("ui.t_b7dcbd263b22"); color: root.foreground; font.family: root.font.family; font.pixelSize: 12; font.weight: Font.DemiBold }
                ControlComboBox {
                    objectName: "widgetWeatherLocation"; width: parent.width; enabled: !!root.controller && root.controller.settingsEditable
                    model: [Language.I18n.text("ui.t_f5a46e041016"), Language.I18n.text("ui.t_fc33f73246f4")]
                    currentIndex: root.controller && root.controller.locMode === "city" ? 1 : 0
                    onActivated: index => root.controller.setWeather("locMode", index === 1 ? "city" : "auto")
                }
                TextField {
                    objectName: "widgetWeatherCity"; width: parent.width
                    visible: !!root.controller && root.controller.locMode === "city"
                    enabled: !!root.controller && root.controller.settingsEditable
                    placeholderText: Language.I18n.text("ui.t_b7c7a822e5ce"); text: root.controller ? root.controller.cityName : ""
                    color: root.foreground; font.family: root.font.family; font.pixelSize: 12
                    Accessible.name: Language.I18n.text("ui.t_83beb7eac7b3")
                    onEditingFinished: if (root.controller && root.controller.settingsEditable) root.controller.setWeather("cityName", text.trim())
                }
                ControlComboBox {
                    objectName: "widgetWeatherUnit"; width: parent.width; enabled: !!root.controller && root.controller.settingsEditable
                    model: [Language.I18n.text("ui.t_400b949d3863"), Language.I18n.text("ui.t_9c9497df3469")]
                    currentIndex: root.controller && root.controller.tempUnit === "F" ? 1 : 0
                    Accessible.name: Language.I18n.text("ui.t_e50c0db10a18")
                    onActivated: index => root.controller.setWeather("tempUnit", index === 1 ? "F" : "C")
                }
            }
            Text { width: parent.width; text: root.controller && root.controller.editing ? Language.I18n.text("ui.t_d5a62f834439") : Language.I18n.text("ui.t_71a41351ed14"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
    }
}
