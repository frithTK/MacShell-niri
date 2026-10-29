import QtQuick
import "Locale" as Language
import "BarLayout.js" as Layout

Item {
    id: root
    property var layout: []
    property var catalog: []
    property real logicalWidth: 1366
    property real widgetScale: 1
    property color foreground: "white"
    property color accent: "#0a84ff"
    property var measurements: ({})
    readonly property real budgetWidth: Math.max(1, logicalWidth / Math.max(.1, widgetScale))
    readonly property var plan: Layout.solve(layout, catalog, measurements, budgetWidth)
    implicitHeight: 70
    Rectangle { anchors.fill: parent; radius: 9; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06) }
    Item {
        x: 8; y: 10; width: parent.width - 16; height: 32; clip: true
        Repeater {
            model: Object.keys(root.plan.items).map(key => root.plan.items[key]).filter(item => item.width > 0)
            delegate: Rectangle {
                required property var modelData
                x: modelData.x / root.budgetWidth * parent.width
                width: Math.max(0, modelData.width / root.budgetWidth * parent.width - 1)
                height: 32; radius: 4
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, .25)
                Text { anchors.fill: parent; anchors.margins: 3; text: Layout.label(root.catalog, parent.modelData.type); elide: Text.ElideRight; color: root.foreground; font.pixelSize: 9; verticalAlignment: Text.AlignVCenter }
            }
        }
        Text { visible: root.plan.overflow.length > 0; x: root.plan.overflowX / root.budgetWidth * parent.width; text: "•••"; color: root.foreground; font.pixelSize: 9; y: 10 }
    }
    Text { x: 10; y: 48; text: Math.round(root.logicalWidth) + Language.I18n.text("ui.t_8014082a43bd") + Math.round(root.widgetScale * 100) + Language.I18n.text("ui.t_85c808050c68") + root.plan.overflow.length + Language.I18n.text("ui.t_87ded0210136"); color: root.foreground; opacity: .55; font.pixelSize: 10 }
}
