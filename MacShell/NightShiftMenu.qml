import QtQuick
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    signal temperaturePicked(int value)
    signal enabledPicked(bool value)
    contentItem: Column {
        spacing: 10
        ControlHeader { width: parent.width; title: "Night Shift"; foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; text: root.controller.label; color: root.foreground; opacity: .65 }
        ControlSwitch { objectName: "nightShiftSwitch"; width: parent.width; text: "Warm display colors"; checked: root.controller.desired; enabled: root.controller.available; onClicked: root.enabledPicked(checked) }
        ControlSlider { objectName: "nightShiftTemperature"; enabled: root.controller.available; Accessible.name: "Color temperature"; width: parent.width; from: 2500; to: 6000; stepSize: 50; value: root.controller.temperature; onMoved: root.temperaturePicked(Math.round(value)) }
        Text { font.family: root.font.family; text: "Warmer     " + root.controller.temperature + " K     Cooler"; color: root.foreground; font.pixelSize: 12 }
        Text { font.family: root.font.family; visible: root.controller.error !== ""; text: root.controller.error; color: root.warning; width: parent.width; wrapMode: Text.Wrap }
        ControlButton { objectName: "nightShiftRetry"; visible: root.controller.error !== "" || !root.controller.available; text: root.controller.available ? "Try again" : "Check availability"; onClicked: root.controller.retry() }
    }
}
