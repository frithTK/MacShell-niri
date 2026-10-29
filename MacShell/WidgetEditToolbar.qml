import QtQuick
import "Locale" as Language
import QtQuick.Controls
import QtQuick.Layouts
import "WidgetCatalog.js" as Catalog

ControlMenu {
    id: root
    property color accent: "#0a84ff"
    property string family: "Inter"
    property string selectedId: ""
    property string selectedType: ""
    property string selectedSize: "small"
    property bool busy: false
    property bool canUndo: false
    property bool canConfigure: false
    property string error: ""
    property var displayChoices: []
    property string selectedOutput: ""
    readonly property var definition: Catalog.find(selectedType)
    signal finished()
    signal resizeRequested(string size)
    signal removeRequested()
    signal duplicateRequested()
    signal undoRequested()
    signal configureRequested()
    signal moveRequested(string name)
    implicitWidth: 760; implicitHeight: 40
    padding: 4; focus: true
    font.family: family; palette.highlight: accent
    function activate() { forceActiveFocus(); }
    function openActions() { if (visible) actions.open(); }
    function actionButton(name) {
        for (var i = 0; i < actions.count; i++) { var item = actions.itemAt(i); if (item.objectName === name) return item; }
        return null;
    }
    onSelectedIdChanged: actions.close()
    onVisibleChanged: if (!visible) actions.close()
    Keys.onEscapePressed: root.finished()
    background: Rectangle {
        radius: 12; color: root.dark ? "#28282d" : "#f5f5f7"
        border.width: 1; border.color: root.dark ? "#55555b" : "#bcbcc4"
    }
    contentItem: RowLayout {
        spacing: 6
        Text {
            Layout.leftMargin: 10; Layout.fillWidth: true
            text: root.definition ? Language.I18n.legacy(root.definition.label) : Language.I18n.text("ui.t_260c18b5d3b2")
            color: root.foreground; font.family: root.family; font.pixelSize: 13; font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Repeater {
            model: Catalog.sizes
            delegate: ControlButton {
                required property var modelData
                objectName: "widgetEditSize_" + modelData.key
                visible: !!root.definition
                Layout.preferredWidth: 34; implicitWidth: 34
                text: Language.I18n.legacy(modelData.label).substring(0, 1); primary: root.selectedSize === modelData.key
                Accessible.name: Language.I18n.legacy(modelData.label) + Language.I18n.text("ui.t_f0d62e3b6dbd")
                enabled: !root.busy
                onClicked: root.resizeRequested(modelData.key)
            }
        }
        ControlComboBox {
            objectName: "widgetEditOutput"; Layout.preferredWidth: Math.min(140, root.width * .22)
            visible: !!root.definition && root.displayChoices.length > 1
            enabled: !root.busy; model: root.displayChoices; textRole: "label"
            currentIndex: Math.max(0, root.displayChoices.findIndex(item => item.name === root.selectedOutput))
            Accessible.name: Language.I18n.text("ui.t_ab506341f8b2")
            onActivated: index => { if (model[index].name !== root.selectedOutput) root.moveRequested(model[index].name); }
        }
        ControlButton {
            id: more; objectName: "widgetEditMore"; text: Language.I18n.text("ui.t_d47d7cb0e4f8")
            onClicked: root.openActions()
            Menu {
                id: actions; y: more.height + 8
                closePolicy: Popup.CloseOnPressOutside
                MenuItem { objectName: "widgetEditConfigure"; text: Language.I18n.text("ui.t_37d782202d97"); visible: !!root.definition && root.canConfigure; height: visible ? implicitHeight : 0; enabled: !root.busy; onTriggered: root.configureRequested() }
                MenuItem { objectName: "widgetEditDuplicate"; text: Language.I18n.text("ui.t_02cdaabfca80"); visible: !!root.definition; height: visible ? implicitHeight : 0; enabled: !root.busy; onTriggered: root.duplicateRequested() }
                MenuItem { objectName: "widgetEditRemove"; text: Language.I18n.text("ui.t_c3812fc4acb8"); visible: !!root.definition; height: visible ? implicitHeight : 0; enabled: !root.busy; onTriggered: root.removeRequested() }
                MenuItem { objectName: "widgetEditUndo"; text: Language.I18n.text("ui.t_6b83c3f4d833"); enabled: root.canUndo && !root.busy; onTriggered: root.undoRequested() }
            }
        }
        ControlButton { objectName: "widgetEditDone"; text: Language.I18n.text("common.done"); primary: true; onClicked: root.finished() }
    }
    ToolTip {
        visible: root.error !== ""; text: Language.I18n.legacy(root.error); timeout: 7000
        width: Math.min(440, root.width); y: root.height + 8
    }
    Shortcut { sequence: "Escape"; enabled: root.visible; onActivated: root.finished() }
}
