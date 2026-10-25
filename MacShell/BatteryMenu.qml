import QtQuick

ControlMenu {
    id: root
    required property var battery
    required property var power
    signal settingsRequested()
    property bool showHeader: true
    property bool showSettings: true
    contentItem: Column {
        spacing: 10
        ControlHeader { visible: root.showHeader; width: parent.width; title: "Battery"; foreground: root.foreground; family: root.font.family; backVisible: false }
        Row {
            width: parent.width; spacing: 10
            Text { text: root.battery.present ? root.battery.percentage + "%" : "—"; color: root.foreground; font { family: root.font.family; pixelSize: 28; weight: Font.DemiBold } }
            Text { anchors.verticalCenter: parent.verticalCenter; text: root.battery.charging ? "Charging" : root.battery.full ? "Fully Charged" : root.battery.onBattery ? "On Battery" : "Power Adapter"; color: root.secondary; font.family: root.font.family; font.pixelSize: 12 }
        }
        Text { objectName: "batteryRemaining"; width: parent.width; text: root.battery.remaining; color: root.foreground; font.family: root.font.family; font.pixelSize: 13; wrapMode: Text.Wrap }
        Text { width: parent.width; text: root.battery.source; color: root.secondary; font.family: root.font.family; font.pixelSize: 11; wrapMode: Text.Wrap }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Text { text: "ENERGY MODE"; color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
        PowerProfilePicker { width: parent.width; controller: root.power }
        Text {
            width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font.family: root.font.family; font.pixelSize: 11
            text: root.power.busy ? "Applying…" : !root.power.available ? "Power profiles service unavailable."
                : root.power.gameHold ? "Game Mode is temporarily requesting Performance. Choosing a mode overrides that request."
                : root.power.inhibited ? "Performance unavailable: " + root.power.inhibited
                : root.power.profiles.indexOf("performance") < 0 ? "Performance is not supported by this device."
                : root.power.degraded ? "Performance limited: " + root.power.degraded : "Changes apply to the system immediately."
        }
        Text { visible: text !== ""; width: parent.width; text: root.power.error; wrapMode: Text.Wrap; color: root.warning; font.family: root.font.family; font.pixelSize: 12 }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        ControlButton { visible: root.showSettings; width: parent.width; text: "Battery Settings…"; onClicked: root.settingsRequested() }
    }
}
