import QtQuick
import "Locale" as Language
import QtQuick.Controls
import "WidgetCatalog.js" as Catalog

ControlMenu {
    id: root
    required property var controller
    property color accent: "#0a84ff"
    palette.highlight: accent
    property string selectedId: ""
    property string status: ""
    property bool appearanceExpanded: false
    readonly property var rows: controller && controller.instanceRows ? controller.instanceRows : []
    readonly property var selected: rows.find(item => item.id === selectedId) || rows[0] || null
    readonly property var definition: selected && selected.supported ? Catalog.find(selected.type) : null
    readonly property bool editable: !!controller && controller.settingsEditable
    signal addRequested()
    function selectAndFocus(id) {
        selectedId = id;
        Qt.callLater(() => {
            var index = rows.findIndex(item => item.id === id), card = cards.itemAt(index);
            if (card) card.forceActiveFocus();
        });
    }
    Connections {
        target: root.controller; ignoreUnknownSignals: true
        function onMutationFinished(success) { root.status = success ? Language.I18n.text("ui.t_12b3f1a3e924") : ""; }
    }
    function apply(accepted, failure) { status = accepted ? (controller.pending ? Language.I18n.text("ui.t_23e39291d613") : Language.I18n.text("ui.t_12b3f1a3e924")) : failure; }
    contentItem: Column {
        spacing: 12
        Text {
            width: parent.width
            text: root.rows.length ? Language.I18n.text("ui.t_999aca254a1d") : Language.I18n.text("ui.t_3422f0e226ed")
            color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap
        }
        ControlButton { visible: root.rows.length === 0; text: Language.I18n.text("ui.t_43c87df5ae94"); primary: true; onClicked: root.addRequested() }
        Column {
            width: parent.width; spacing: 6
            Repeater {
                id: cards
                model: root.rows
                delegate: Button {
                    id: card
                    required property var modelData
                    objectName: "widgetInstance_" + modelData.id
                    width: parent.width; height: 58; padding: 10
                    readonly property bool selected: !!root.selected && root.selected.id === modelData.id
                    Accessible.name: Language.I18n.legacy(modelData.label) + ", " + (modelData.display || Language.I18n.text("ui.t_995a033bfb49")) + (modelData.placed ? "" : ", " + modelData.reason)
                    onClicked: { root.selectedId = modelData.id; root.status = ""; }
                    background: Rectangle {
                        radius: 10
                        color: card.selected ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.dark ? .18 : .10) : root.dark ? "#2b2c32" : "#ececf0"
                        border.width: 1; border.color: card.selected || card.activeFocus ? root.accent : root.separator
                    }
                    contentItem: Row {
                        spacing: 10
                        Rectangle {
                            width: 36; height: 36; radius: 9; anchors.verticalCenter: parent.verticalCenter
                            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, .15)
                            Text { anchors.centerIn: parent; text: Language.I18n.legacy(card.modelData.label).charAt(0); color: root.foreground; font.family: root.font.family; font.pixelSize: 17; font.weight: Font.DemiBold }
                        }
                        Column {
                            width: parent.width - 46; spacing: 3; anchors.verticalCenter: parent.verticalCenter
                            Text { width: parent.width; text: Language.I18n.legacy(card.modelData.label); textFormat: Text.PlainText; color: root.foreground; font.family: root.font.family; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            Text {
                                width: parent.width
                                text: (card.modelData.display || Language.I18n.text("ui.t_995a033bfb49")) + " · " + Language.I18n.legacy(card.modelData.placed ? (Catalog.sizes.find(item => item.key === card.modelData.size) || {label: ""}).label : card.modelData.reason)
                                textFormat: Text.PlainText; color: root.secondary; font.family: root.font.family; font.pixelSize: 11; elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
        Column {
            width: parent.width; spacing: 12; visible: !!root.selected
            Rectangle { width: parent.width; height: 1; color: root.separator }
            Text { text: root.selected ? Language.I18n.text("ui.t_23c778bec476") + Language.I18n.legacy(root.selected.label) : ""; textFormat: Text.PlainText; color: root.foreground; font.family: root.font.family; font.pixelSize: 15; font.weight: Font.DemiBold }
            Text { width: parent.width; visible: !!root.selected && !root.selected.placed; text: root.selected ? Language.I18n.legacy(root.selected.reason) : ""; textFormat: Text.PlainText; color: root.warning; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
            Row {
                spacing: 8; visible: !!root.definition
                Text { text: Language.I18n.text("ui.t_1af851907331"); width: 70; anchors.verticalCenter: parent.verticalCenter; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                Repeater {
                    model: Catalog.sizes
                    delegate: ControlButton {
                        required property var modelData
                        objectName: "widgetInstanceSize_" + modelData.key
                        text: Language.I18n.legacy(modelData.label); primary: !!root.selected && root.selected.size === modelData.key
                        enabled: root.editable && !!root.selected && root.selected.canPlace && !!root.definition && root.definition.sizes.indexOf(modelData.key) >= 0
                        onClicked: root.apply(root.controller.setSize(root.selected.id, modelData.key), "No room for this size. The card has been kept. Try a smaller size or another display.")
                    }
                }
            }
            Row {
                width: parent.width; spacing: 8; visible: !!root.definition
                Text { text: Language.I18n.text("ui.t_7e744141b40e"); width: 70; anchors.verticalCenter: parent.verticalCenter; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                ControlComboBox {
                    objectName: "widgetInstanceStyle"; width: parent.width - 78; enabled: root.editable
                    model: root.definition ? [{key: "", label: Language.I18n.text("ui.t_254af4e31993") + Language.I18n.legacy(Catalog.styles[root.selected.defaultStyle || "liquid"]) + ")"}].concat(root.definition.styles.map(key => ({key: key, label: Language.I18n.legacy(Catalog.styles[key])}))) : []; textRole: "label"
                    currentIndex: root.definition && !root.selected.styleInherited ? Math.max(0, root.definition.styles.indexOf(root.selected.style) + 1) : 0
                    Accessible.name: Language.I18n.text("ui.t_b2c2e2349a3f")
                    onActivated: index => root.apply(index === 0 ? root.controller.resetWidgetAppearance(root.selected.id, "style") : root.controller.setStyle(root.selected.id, model[index].key), Language.I18n.text("ui.t_8b2bf5544972"))
                }
            }
            ControlButton { objectName: "widgetAppearanceExpand"; visible: !!root.definition; text: (root.appearanceExpanded ? "▾" : "▸") + (root.selected && root.selected.type === "activity" ? " Appearance & metrics…" : root.selected && root.selected.type === "batteries" ? " Appearance & devices…" : root.selected && root.selected.type === "image" ? " Appearance & image…" : " Appearance…"); onClicked: root.appearanceExpanded = !root.appearanceExpanded }
            WidgetAppearanceEditor {
                objectName: "widgetAppearanceEditor"; width: parent.width; visible: !!root.definition && root.appearanceExpanded
                controller: root.controller; record: root.selected
                foreground: root.foreground; font.family: root.font.family; palette.highlight: root.accent
                onActionResult: accepted => root.apply(accepted, Language.I18n.text("ui.t_294bfa2e3e19"))
                onCancelled: root.appearanceExpanded = false
            }
            Column {
                width: parent.width; spacing: 6; visible: !!root.definition && !!root.controller && root.controller.displayChoices.length > 0
                Text { text: Language.I18n.text("ui.t_e849e8eb66aa"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
                ControlComboBox {
                    objectName: "widgetInstanceOutput"; width: parent.width; enabled: root.editable
                    // A placeholder keeps a disconnected card from silently selecting the first monitor.
                    model: [{name: "", label: root.selected && root.selected.outputName ? Language.I18n.text("ui.t_577b09752db4") : Language.I18n.text("ui.t_5ce166e84ca0")}].concat(root.controller ? root.controller.displayChoices : [])
                    textRole: "label"; currentIndex: root.selected ? Math.max(0, model.findIndex(item => item.name === root.selected.outputName)) : 0
                    Accessible.name: Language.I18n.text("ui.t_2e59c19eaf41")
                    onActivated: index => {
                        if (model[index].name && model[index].name !== root.selected.outputName)
                            root.apply(root.controller.moveWidgetToOutput(root.selected.id, model[index].name), Language.I18n.text("ui.t_b773acaede26"));
                    }
                }
            }
            Flow {
                width: parent.width; spacing: 8
                ControlButton { objectName: "widgetInstanceDuplicate"; text: Language.I18n.text("ui.t_02cdaabfca80"); visible: !!root.definition; enabled: root.editable && !!root.selected && root.selected.canPlace; onClicked: root.apply(root.controller.duplicateWidget(root.selected.id), "No room for another card on this display. Try a smaller size or move the card first.") }
                ControlButton { objectName: "widgetInstanceRemove"; text: Language.I18n.text("ui.t_c3812fc4acb8"); enabled: root.editable; onClicked: root.apply(root.controller.removeWidget(root.selected.id), "Could not remove this card.") }
            }
            Text { width: parent.width; visible: !!root.definition; text: root.definition ? Language.I18n.legacy(root.definition.shared) : ""; color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
        Row {
            spacing: 8; visible: !!root.controller && root.controller.undoStack && root.controller.undoStack.length > 0
            ControlButton { objectName: "widgetsUndo"; text: Language.I18n.text("ui.t_6b83c3f4d833"); enabled: !!root.controller && root.controller.canUndoDelete; onClicked: root.apply(root.controller.undoDelete(), "Could not restore this card. Reload settings and try again.") }
            Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_e1f9c701a11e"); color: root.secondary; font.family: root.font.family; font.pixelSize: 11 }
        }
        Text { objectName: "widgetInstanceStatus"; width: parent.width; visible: root.status !== ""; text: Language.I18n.legacy(root.status); color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
    }
}
