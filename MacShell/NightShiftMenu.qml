import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    signal temperaturePicked(int value)
    signal enabledPicked(bool value)
    contentItem: Column {
        spacing: 10
        ControlHeader { width: parent.width; title: Language.I18n.text("ui.t_d9a2bf53437c"); foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; text: root.controller.label; color: root.foreground; opacity: .65 }
        ControlSwitch { objectName: "nightShiftSwitch"; width: parent.width; text: Language.I18n.text("ui.t_f9ce13b7d8e3"); checked: root.controller.desired; enabled: root.controller.available; onClicked: root.enabledPicked(checked) }
        ControlSlider { objectName: "nightShiftTemperature"; enabled: root.controller.available; Accessible.name: Language.I18n.text("ui.t_fc9c054b0d7e"); width: parent.width; from: 2500; to: 6000; stepSize: 50; value: root.controller.temperature; onMoved: root.temperaturePicked(Math.round(value)) }
        Text { font.family: root.font.family; text: Language.I18n.text("ui.t_068e5ff387f4") + root.controller.temperature + Language.I18n.text("ui.t_dc89d2771914"); color: root.foreground; font.pixelSize: 12 }
        Text { font.family: root.font.family; visible: root.controller.error !== ""; text: Language.I18n.legacy(root.controller.error); color: root.warning; width: parent.width; wrapMode: Text.Wrap }
        ControlButton { objectName: "nightShiftRetry"; visible: root.controller.error !== "" || !root.controller.available; text: root.controller.available ? Language.I18n.text("ui.t_d8b8392e2c54") : Language.I18n.text("ui.t_2071664a583f"); onClicked: root.controller.retry() }
    }
}
