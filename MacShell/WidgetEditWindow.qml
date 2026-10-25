import QtQuick
import QtQuick.Window
import QtQuick.Controls
import "WidgetCatalog.js" as Catalog

Window {
    id: root
    property color foreground: "#f5f5f7"
    property color accent: "#0a84ff"
    property string family: "Inter"
    property string selectedId: ""
    property string selectedType: ""
    property string selectedSize: "small"
    property bool busy: false
    property bool canUndo: false
    property bool canConfigure: false
    property string error: ""
    property string outputName: ""
    property var displayChoices: []
    property string selectedOutput: ""
    readonly property bool dark: foreground.hslLightness > .5
    readonly property var definition: Catalog.find(selectedType)
    readonly property int editorHeight: Math.max(displayChoices.length > 1 ? 354 : 304, controls.contentItem.implicitHeight + 32)
    signal finished()
    signal resizeRequested(string size)
    signal removeRequested()
    signal duplicateRequested()
    signal undoRequested()
    signal configureRequested()
    signal moveRequested(string name)
    title: "macshell Widget Controls"
    width: 360; height: editorHeight
    minimumWidth: 360; maximumWidth: 360; minimumHeight: editorHeight; maximumHeight: editorHeight
    screen: Application.screens.find(item => item.name === outputName) || null
    transientParent: null
    flags: Qt.Dialog | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
    color: dark ? "#24252b" : "#fafafb"
    visible: false
    function activate() { show(); requestActivate(); Qt.callLater(() => done.forceActiveFocus()); }
    onClosing: close => { close.accepted = false; finished(); }
    onActiveChanged: if (active) done.forceActiveFocus()
    Rectangle { anchors.fill: parent; color: root.color }
    Item {
        anchors.fill: parent; focus: true
        Keys.onEscapePressed: root.finished()
        ControlMenu {
            id: controls
            anchors.fill: parent; anchors.margins: 16
            foreground: root.foreground; font.family: root.family; palette.highlight: root.accent
            contentItem: Column {
                spacing: 12
                Text { text: root.definition ? root.definition.label : "Arrange widgets"; color: root.foreground; font.family: root.family; font.pixelSize: 17; font.weight: Font.DemiBold }
                Text { width: parent.width; text: root.definition ? "Drag this card on the desktop, or choose a size." : "Drag cards on the desktop. Click or right-click a card to select it. Escape finishes editing."; color: controls.secondary; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap }
                Row {
                    spacing: 6; visible: !!root.definition
                    Repeater {
                        model: Catalog.sizes
                        delegate: ControlButton {
                            required property var modelData
                            objectName: "widgetEditSize_" + modelData.key
                            text: modelData.label; primary: root.selectedSize === modelData.key
                            enabled: !root.busy
                            onClicked: root.resizeRequested(modelData.key)
                        }
                    }
                }
                Column {
                    width: parent.width; spacing: 6
                    visible: !!root.definition && root.displayChoices.length > 1
                    Text { text: "Move to display"; color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    ControlComboBox {
                        objectName: "widgetEditOutput"; width: parent.width
                        enabled: !root.busy
                        model: root.displayChoices; textRole: "label"
                        currentIndex: Math.max(0, root.displayChoices.findIndex(item => item.name === root.selectedOutput))
                        Accessible.name: "Move widget to display"
                        onActivated: index => { if (model[index].name !== root.selectedOutput) root.moveRequested(model[index].name); }
                    }
                }
                Text { width: parent.width; visible: root.error !== ""; text: root.error; color: controls.secondary; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap }
                Row {
                    spacing: 8
                    ControlButton { objectName: "widgetEditConfigure"; visible: !!root.definition && root.canConfigure; text: "Configure…"; enabled: !root.busy; onClicked: root.configureRequested() }
                    ControlButton { objectName: "widgetEditDuplicate"; visible: !!root.definition; text: "Duplicate"; enabled: !root.busy; onClicked: root.duplicateRequested() }
                    ControlButton { objectName: "widgetEditRemove"; visible: !!root.definition; text: "Remove"; enabled: !root.busy; onClicked: root.removeRequested() }
                }
                Row {
                    spacing: 8
                    ControlButton { objectName: "widgetEditUndo"; text: "Undo removal"; enabled: root.canUndo && !root.busy; onClicked: root.undoRequested() }
                    ControlButton { id: done; objectName: "widgetEditDone"; text: "Done"; primary: true; onClicked: root.finished() }
                }
            }
        }
    }
}
