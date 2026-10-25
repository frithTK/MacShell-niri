import QtQuick
import QtQuick.Controls
import "WidgetAppearance.js" as Appearance
import "WidgetCatalog.js" as Catalog

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
    readonly property bool editable: !!controller && controller.settingsEditable && !!record && record.supported && !applying
    readonly property string previewStyle: draft.style || (record && record.supported ? record.defaultStyle || record.style : "liquid")
    readonly property string previewMode: draft.mode || (record && record.supported ? record.mode : "auto")
    readonly property var fontChoices: [{value: "", label: "Follow shell font"}].concat(Appearance.fonts)
        .concat(local.fontFamily && !Appearance.fonts.some(item => item.value === local.fontFamily) ? [{value: local.fontFamily, label: local.fontFamily}] : [])
    readonly property var tintChoices: [{value: "", label: "From artwork"}].concat(Appearance.tints)
        .concat(local.tint && !Appearance.tints.some(item => item.value === local.tint) ? [{value: local.tint, label: local.tint}] : [])
    readonly property var textChoices: [{value: 1, label: "Default"}, {value: .9, label: "Small"}, {value: 1.1, label: "Large"}, {value: 1.2, label: "Extra large"}]
        .concat(local.textScale !== undefined && [1, .9, 1.1, 1.2].indexOf(local.textScale) < 0 ? [{value: local.textScale, label: "Custom (" + Math.round(local.textScale * 100) + "%)"}] : [])
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
                }
            }
        }
        Column {
            width: parent.width; spacing: 6
            visible: !!root.record && Appearance.supports(root.record.type, root.previewStyle, "theme")
            Text { text: "Theme"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTheme"; width: parent.width; enabled: root.editable
                model: ["Follow shell", "Light", "Dark"]
                readonly property string selectedTheme: root.local.theme || (root.record && root.record.type === "calendar" ? root.previewMode : "auto")
                currentIndex: Math.max(0, ["auto", "light", "dark"].indexOf(selectedTheme))
                Accessible.name: "Widget theme"
                onActivated: index => root.change("theme", index === 0 ? null : ["auto", "light", "dark"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6
            Text { text: "Font"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceFont"; width: parent.width; enabled: root.editable
                model: root.fontChoices; textRole: "label"
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.fontFamily || "")))
                Accessible.name: "Widget font"
                onActivated: index => root.change("fontFamily", model[index].value || null)
            }
        }
        Column {
            width: parent.width; spacing: 6
            Text { text: "Text size"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTextSize"; width: parent.width; enabled: root.editable
                model: root.textChoices
                textRole: "label"
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.textScale === undefined ? 1 : root.local.textScale)))
                Accessible.name: "Widget text size"
                onActivated: index => root.change("textScale", index === 0 ? null : model[index].value)
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && root.record.supported && root.record.type === "clock"
            Text { text: "Seconds"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceSeconds"; width: parent.width; enabled: root.editable
                model: ["Smooth (default)", "Once per second", "Hidden"]
                currentIndex: Math.max(0, ["smooth", "tick", "hidden"].indexOf(root.local.secondsMode || "smooth"))
                Accessible.name: "Clock seconds indicator"
                onActivated: index => root.change("secondsMode", index === 0 ? null : ["smooth", "tick", "hidden"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && Appearance.supports(root.record.type, root.record.style, "density")
            Text { text: "Content density"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceDensity"; width: parent.width; enabled: root.editable
                model: ["Default", "Compact", "Comfortable"]; currentIndex: Math.max(0, ["", "compact", "comfortable"].indexOf(root.local.density || ""))
                Accessible.name: "Player content density"
                onActivated: index => root.change("density", index === 0 ? null : ["", "compact", "comfortable"][index])
            }
        }
        Column {
            width: parent.width; spacing: 6; visible: !!root.record && Appearance.supports(root.record.type, root.record.style, "tint")
            Text { text: "Tint"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
            ControlComboBox {
                objectName: "widgetAppearanceTint"; width: parent.width; enabled: root.editable
                model: root.tintChoices; textRole: "label"
                currentIndex: Math.max(0, model.findIndex(item => item.value === (root.local.tint || "")))
                Accessible.name: "Player tint"
                onActivated: index => root.change("tint", model[index].value || null)
            }
        }
        Text { width: parent.width; text: "Preview with sample data. Apply saves this card's appearance; Cancel discards the draft. Default fields follow the shell or widget defaults."; color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        ControlButton { objectName: "widgetAppearanceReset"; text: "Reset appearance"; enabled: root.editable; onClicked: root.change("all", null) }
        Text { objectName: "widgetAppearanceError"; width: parent.width; visible: root.error !== ""; text: root.error; color: root.warning; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Row {
            spacing: 8
            ControlButton { objectName: "widgetAppearanceApply"; text: root.applying ? "Saving…" : "Apply"; primary: true; enabled: root.editable && root.dirty; onClicked: root.apply() }
            ControlButton { objectName: "widgetAppearanceCancel"; text: "Cancel"; enabled: !root.applying; onClicked: { root.load(); root.cancelled(); } }
        }
    }
}
