import QtQuick
import "Locale" as Language

ControlMenu {
    id: root
    required property var battery
    required property var power
    signal settingsRequested()
    property bool showHeader: true
    property bool showSettings: true
    contentItem: Column {
        spacing: 10
        ControlHeader { visible: root.showHeader; width: parent.width; title: Language.I18n.text("ui.t_dfcb7c1619d5"); foreground: root.foreground; family: root.font.family; backVisible: false }
        Row {
            width: parent.width; spacing: 10
            Text { text: root.battery.present && root.battery.percentage >= 0 ? root.battery.percentage + "%" : "—"; color: root.foreground; font { family: root.font.family; pixelSize: 28; weight: Font.DemiBold } }
            Text { anchors.verticalCenter: parent.verticalCenter; text: root.battery.charging ? Language.I18n.text("ui.t_22b693223fcb") : root.battery.full ? Language.I18n.text("ui.t_92f27ddd75fa") : root.battery.onBattery ? Language.I18n.text("ui.t_fe594ed90f81") : Language.I18n.text("ui.t_26a4d134061c"); color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
        }
        Text { objectName: "batteryRemaining"; width: parent.width; text: root.battery.remaining; color: root.foreground; font.family: root.font.family; font.pixelSize: 13; wrapMode: Text.Wrap }
        Text { objectName: "batteryRate"; visible: !!(root.battery.rateLabel); width: parent.width; text: root.battery.rateLabel; color: root.secondary; font.family: root.font.family; font.pixelSize: 12; wrapMode: Text.Wrap }
        Text { width: parent.width; text: root.battery.source; color: root.secondary; font.family: root.font.family; font.pixelSize: 11; wrapMode: Text.Wrap }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Text { text: Language.I18n.text("ui.t_53a109f8e157"); color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
        PowerProfilePicker { width: parent.width; controller: root.power }
        Text {
            width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font.family: root.font.family; font.pixelSize: 11
            text: root.power.busy ? Language.I18n.text("ui.t_3329a9bb48b9") : !root.power.available ? Language.I18n.text("ui.t_852258313277")
                : root.power.gameHold ? Language.I18n.text("ui.t_70cbbd8f41bb")
                : root.power.inhibited ? Language.I18n.text("ui.t_256849ba5491") + root.power.inhibited
                : root.power.profiles.indexOf("performance") < 0 ? Language.I18n.text("ui.t_d644f27de51f")
                : root.power.degraded ? Language.I18n.text("ui.t_0b050cf3b99b") + root.power.degraded : Language.I18n.text("ui.t_421d37a23ee9")
        }
        Text { visible: text !== ""; width: parent.width; text: Language.I18n.legacy(root.power.error); wrapMode: Text.Wrap; color: root.warning; font.family: root.font.family; font.pixelSize: 12 }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        ControlButton { visible: root.showSettings; width: parent.width; text: Language.I18n.text("ui.t_5da8e7bb9e11"); onClicked: root.settingsRequested() }
    }
}
