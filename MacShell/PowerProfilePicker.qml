import QtQuick

Column {
    id: root
    required property var controller
    spacing: 2
    Repeater {
        model: ["power-saver", "balanced", "performance"]
        delegate: ControlChoice {
            required property string modelData
            objectName: "power_" + modelData
            width: root.width
            text: root.controller.label(modelData)
            selected: root.controller.profile === modelData
            enabled: !root.controller.busy && root.controller.supported(modelData)
            onClicked: root.controller.select(modelData)
        }
    }
}
