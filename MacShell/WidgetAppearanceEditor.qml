import QtQuick
import "Locale" as Language
import QtQuick.Controls
import "WidgetAppearance.js" as Appearance
import "WidgetCatalog.js" as Catalog
import "ActivityWidgetData.js" as ActivityData
import "BatteriesData.js" as BatteriesData

ControlMenu {
    id: root
    required property var controller
    required property var record
    property var draft: ({})
    property var baseSettings: ({})
    property string editingId: ""
    property string editingType: ""
    property bool applying: false
    property string error: ""
    readonly property bool dirty: JSON.stringify(draft) !== JSON.stringify(baseSettings)
    readonly property var local: draft.appearance || ({})
    readonly property var activity: draft.activity || ({})
    readonly property var activityMetrics: ActivityData.selected(activity)
    readonly property var batteries: draft.batteries || ({})
    readonly property var batteryIds: batteries.devices || []
    readonly property var batteryChoices: editingType === "batteries"
        ? BatteriesData.choices(controller && controller.batteryDevices ? controller.batteryDevices.entries : [], batteryIds) : []
    readonly property bool editable: !!controller && controller.settingsEditable && !!record && record.supported && !applying
    readonly property string previewStyle: draft.style || (record && record.supported ? record.defaultStyle || record.style : "liquid")
    readonly property string previewMode: draft.mode || (record && record.supported ? record.mode : "auto")
    readonly property var fontChoices: [{value: "", label: Language.I18n.text("ui.t_809e2174ade9")}].concat(Appearance.fonts)
        .concat(local.fontFamily && !Appearance.fonts.some(item => item.value === local.fontFamily) ? [{value: local.fontFamily, label: local.fontFamily}] : [])
    readonly property var tintChoices: [{value: "", label: Language.I18n.text("ui.t_71ae60d4261e")}].concat(Appearance.tints)
        .concat(local.tint && !Appearance.tints.some(item => item.value === local.tint) ? [{value: local.tint, label: local.tint}] : [])
    readonly property var textChoices: [{value: 1, label: Language.I18n.text("ui.t_21b111cbfe6e")}, {value: .9, label: Language.I18n.text("ui.t_5263293fc202")}, {value: 1.1, label: Language.I18n.text("ui.t_ab80540d98d2")}, {value: 1.2, label: Language.I18n.text("ui.t_cc16912b3b97")}]
        .concat(local.textScale !== undefined && [1, .9, 1.1, 1.2].indexOf(local.textScale) < 0 ? [{value: local.textScale, label: Language.I18n.text("ui.t_a6ab054a5318") + Math.round(local.textScale * 100) + "%)"}] : [])
    signal actionResult(bool accepted)
    signal cancelled()
    function clone(value) { return JSON.parse(JSON.stringify(value)); }
    function load() {
        editingId = record ? record.id : "";
        editingType = record ? record.type : "";
        baseSettings = record && record.supported ? clone(record.savedSettings || {style: record.style, mode: record.mode, appearance: record.appearance || {}}) : {};
        draft = clone(baseSettings); error = "";
    }
    onRecordChanged: if (!record || editingId !== record.id || (!dirty && !applying)) load()
    Component.onCompleted: load()
    Connections {
        target: root.controller; ignoreUnknownSignals: true
        function onMutationFinished(success) {
            if (!root.applying) return;
            root.applying = false;
            if (success) root.load(); else root.error = "Appearance was not saved. Your draft is kept. Cancel to load current settings.";
            root.actionResult(success);
        }
    }
    function change(key, value) {
        if (!editable) return;
        var next = clone(draft), look = next.appearance || {};
        if (key === "all") { Appearance.fields.forEach(field => { delete look[field]; }); delete next.style; }
        else if (value === null) delete look[key]; else look[key] = value;
        if (key === "all" || key === "theme") {
            delete next.mode;
            if (value === null && record.type === "calendar") look.theme = "auto";
        }
        if (Object.keys(look).length) next.appearance = look; else delete next.appearance;
        draft = next; error = "";
    }
    function apply() {
        if (!editable || !dirty) return;
        applying = true;
        if (!controller.commitWidgetAppearance(editingId, clone(draft), clone(baseSettings), editingType)) {
            applying = false; error = "This card changed or is unavailable. Your draft is kept. Cancel to load current settings.";
        }
    }
    function changeActivity(key, value) {
        if (!editable || editingType !== "activity") return;
        var next = clone(draft);
        next.activity = next.activity || {};
        next.activity[key] = value;
        if (!ActivityData.validSettings(next.activity)) return;
        draft = next; error = "";
    }
    function toggleMetric(key) {
        var next = activityMetrics.slice();
        if (next.indexOf(key) >= 0) next = next.filter(item => item !== key);
        else next.push(key);
        changeActivity("metrics", next);
    }
    function changeBatteries(key, value) {
        if (!editable || editingType !== "batteries") return;
        var next = clone(draft);
        next.batteries = next.batteries || {};
        next.batteries[key] = value;
        if (!BatteriesData.validSettings(next.batteries)) return;
        draft = next; error = "";
    }
    function toggleBattery(id) {
        var next = batteryIds.slice();
        if (next.indexOf(id) >= 0) next = next.filter(item => item !== id); else next.push(id);
        changeBatteries("devices", next);
    }
    contentItem: Column {
        spacing: 12
        Rectangle {
            width: parent.width; height: 160; radius: 12; color: root.dark ? "#2b2c32" : "#e7e8ee"; border.color: root.separator
            Item {
                anchors.centerIn: parent
                width: root.record && root.record.supported ? Catalog.dimensions(root.record.size)[0] : 185
                height: root.record && root.record.supported ? Catalog.dimensions(root.record.size)[1] : 185
                scale: Math.min((parent.width - 32) / width, (parent.height - 24) / height, 1)
                WidgetPreview {
                    objectName: "widgetAppearancePreview"; anchors.fill: parent
                    widgetType: root.record && root.record.supported ? root.record.type : ""; widgetSize: root.record && root.record.supported ? root.record.size : "small"
                    widgetStyle: root.previewStyle; mode: root.previewMode
                    appearance: root.local; family: root.font.family; dark: root.dark
                    activity: root.activity
                    batteries: root.batteries
                }
            }
        }
        Column {
            width: parent.width; spacing: 8; visible: root.editingType === "batteries"
            Text { text: Language.I18n.text("ui.t_4ba5121d4d1b"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetBatteriesMode"; width: parent.width; enabled: root.editable
                model: [Language.I18n.text("ui.t_d461a493a375"), Language.I18n.text("ui.t_9e4742eed655")]; currentIndex: root.batteries.mode === "selected" ? 1 : 0
                Accessible.name: Language.I18n.text("ui.t_a6b00d06aeb3")
                onActivated: index => root.changeBatteries("mode", index === 1 ? "selected" : "auto")
            }
            Column {
                width: parent.width; spacing: 8; visible: root.batteries.mode === "selected"
                Repeater {
                    model: root.batteryChoices
                    delegate: Row {
                        id: batteryChoice
                        required property var modelData
                        width: parent.width; spacing: 8
                        Column {
                            width: parent.width - deviceSwitch.width - 8; spacing: 2
                            Text { width: parent.width; text: batteryChoice.modelData.label; textFormat: Text.PlainText; color: root.foreground; font.family: root.font.family; font.pixelSize: 12; elide: Text.ElideRight }
                            Text { width: parent.width; text: BatteriesData.status(batteryChoice.modelData) || BatteriesData.value(batteryChoice.modelData); color: root.secondary; font.family: root.font.family; font.pixelSize: 10; elide: Text.ElideRight }
                        }
                        ControlSwitch {
                            id: deviceSwitch; objectName: "widgetBatteryDevice_" + batteryChoice.modelData.id
                            checked: root.batteryIds.indexOf(batteryChoice.modelData.id) >= 0
                            enabled: root.editable && (checked || root.batteryIds.length < 16)
                            Accessible.name: batteryChoice.modelData.label
                            onToggled: root.toggleBattery(batteryChoice.modelData.id)
                        }
                    }
                }
                Text { width: parent.width; visible: root.batteryChoices.length === 0; text: Language.I18n.text("ui.t_941a9388e9ea"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            }
            Text { width: parent.width; text: Language.I18n.text("ui.t_ab93f7dd1fc7"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
        Column {
            width: parent.width; spacing: 8; visible: root.editingType === "activity"
            Text { text: Language.I18n.text("ui.t_a58da793c725"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            Repeater {
                model: ActivityData.metrics
                delegate: Row {
                    required property string modelData
                    width: parent.width; spacing: 8
                    Text { width: parent.width - activityToggle.width - 8; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.legacy(ActivityData.labels[parent.modelData]); color: root.foreground; font.family: root.font.family; font.pixelSize: 12 }
                    ControlSwitch {
                        id: activityToggle; objectName: "widgetActivityMetric_" + parent.modelData
                        checked: root.activityMetrics.indexOf(parent.modelData) >= 0
                        enabled: root.editable && (!checked || root.activityMetrics.length > 1)
                        Accessible.name: Language.I18n.legacy(ActivityData.labels[parent.modelData]) + Language.I18n.text("ui.t_003f3b973a92")
                        onToggled: root.toggleMetric(parent.modelData)
                    }
                }
            }
            Text { text: Language.I18n.text("ui.t_dcc839a4015c"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetActivityView"; width: parent.width; enabled: root.editable
                model: [Language.I18n.text("ui.t_bab4c75d0722"), Language.I18n.text("ui.t_49df72d3d6df")]; currentIndex: root.activity.view === "graphs" ? 1 : 0
                Accessible.name: Language.I18n.text("ui.t_bbf9857741a8")
                onActivated: index => root.changeActivity("view", index === 1 ? "graphs" : "rings")
            }
            Text { width: parent.width; text: Language.I18n.legacy(Catalog.find("activity").shared); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
        Column {
            width: parent.width; spacing: 6
            visible: !!root.record && Appearance.supports(root.record.type, root.previewStyle, "theme")
            Text { text: Language.I18n.text("ui.t_efb52e7172b7"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTheme"; width: parent.width; enabled: root.editable
                model: [Language.I18n.text("ui.t_5751e967b6d4"), Language.I18n.text("ui.t_dbcd5e7bb7a0"), Language.I18n.text("ui.t_60acc53f13a5")]
                readonly property string selectedTheme: root.local.theme || (root.record && root.record.type === "calendar" ? root.previewMode : "auto")
                currentIndex: Math.max(0, ["auto", "light", "dark"].indexOf(selectedTheme))
                Accessible.name: Language.I18n.text("ui.t_70933efc8e94")
                onActivated: index => root.change("theme", index === 0 ? null : ["auto", "light", "dark"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6
            Text { text: Language.I18n.text("ui.t_64d0b3adcd2d"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceFont"; width: parent.width; enabled: root.editable
                model: root.fontChoices; textRole: "label"; translatedLabels: true
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.fontFamily || "")))
                Accessible.name: Language.I18n.text("ui.t_959e5a8a0a5b")
                onActivated: index => root.change("fontFamily", model[index].value || null)
            }
        }
        Column {
            width: parent.width; spacing: 6
            Text { text: Language.I18n.text("ui.t_d68761cc1eb2"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTextSize"; width: parent.width; enabled: root.editable
                model: root.textChoices
                textRole: "label"
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.textScale === undefined ? 1 : root.local.textScale)))
                Accessible.name: Language.I18n.text("ui.t_da6b93069087")
                onActivated: index => root.change("textScale", index === 0 ? null : model[index].value)
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && root.record.supported && root.record.type === "clock"
            Text { text: Language.I18n.text("ui.t_381a8e969905"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceSeconds"; width: parent.width; enabled: root.editable
                model: [Language.I18n.text("ui.t_8f66eec8d906"), Language.I18n.text("ui.t_1600358cd6ad"), Language.I18n.text("ui.t_7e6fefff0f0a")]
                currentIndex: Math.max(0, ["smooth", "tick", "hidden"].indexOf(root.local.secondsMode || "smooth"))
                Accessible.name: Language.I18n.text("ui.t_5a18e6f12aff")
                onActivated: index => root.change("secondsMode", index === 0 ? null : ["smooth", "tick", "hidden"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && Appearance.supports(root.record.type, root.record.style, "density")
            Text { text: Language.I18n.text("ui.t_7c662e12f634"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceDensity"; width: parent.width; enabled: root.editable
                model: [Language.I18n.text("ui.t_21b111cbfe6e"), Language.I18n.text("ui.t_99452646e34b"), Language.I18n.text("ui.t_459a23a5980f")]; currentIndex: Math.max(0, ["", "compact", "comfortable"].indexOf(root.local.density || ""))
                Accessible.name: Language.I18n.text("ui.t_ddbcea113512")
                onActivated: index => root.change("density", index === 0 ? null : ["", "compact", "comfortable"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && Appearance.supports(root.record.type, root.record.style, "tint")
            Text { text: Language.I18n.text("ui.t_6a822da0d9db"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTint"; width: parent.width; enabled: root.editable
                model: root.tintChoices; textRole: "label"; translatedLabels: true
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.tint || "")))
                Accessible.name: Language.I18n.text("ui.t_693cf936f9f6")
                onActivated: index => root.change("tint", model[index].value || null)
            }
        }
        Text { width: parent.width; text: Language.I18n.text("ui.t_e953289a70d1"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        ControlButton { objectName: "widgetAppearanceReset"; text: Language.I18n.text("ui.t_54ba48b060d6"); enabled: root.editable; onClicked: root.change("all", null) }
        Text { objectName: "widgetAppearanceError"; width: parent.width; visible: root.error !== ""; text: Language.I18n.legacy(root.error); color: root.warning; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Row {
            spacing: 8
            ControlButton { objectName: "widgetAppearanceApply"; text: root.applying ? Language.I18n.text("ui.t_23e39291d613") : Language.I18n.text("common.apply"); primary: true; enabled: root.editable && root.dirty; onClicked: root.apply() }
            ControlButton { objectName: "widgetAppearanceCancel"; text: Language.I18n.text("common.cancel"); enabled: !root.applying; onClicked: { root.load(); root.cancelled(); } }
        }
    }
}
