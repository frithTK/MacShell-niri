import QtQuick
import "Locale" as Language
import Quickshell.Services.UPower
import "BatteryState.js" as BatteryState

QtObject {
    readonly property var device: UPower.displayDevice
    readonly property bool present: !!(device && device.isPresent && device.isLaptopBattery)
    readonly property int percentage: BatteryState.chargePercentage(present, !!device && device.ready, device ? device.percentage : -1)
    readonly property int healthPercentage: BatteryState.healthPercentage(UPower.devices.values)
    readonly property bool charging: present && device.state === UPowerDeviceState.Charging
    readonly property bool full: present && device.state === UPowerDeviceState.FullyCharged
    readonly property bool onBattery: UPower.onBattery
    readonly property string remaining: BatteryState.remaining(present, device ? device.state : 0,
                                                               device ? device.timeToEmpty : 0,
                                                               device ? device.timeToFull : 0, onBattery, (key, args) => Language.I18n.text(key, args))
    readonly property string source: Language.I18n.text(onBattery ? "battery.source_battery" : "battery.source_adapter")
    readonly property string modelName: present && device && device.model ? String(device.model) : ""
    readonly property string energyLabel: BatteryState.formatEnergy(device ? device.energy : -1,
                                                                    device ? device.energyCapacity : -1,
                                                                    (key, args) => Language.I18n.text(key, args))
    readonly property string rateLabel: onBattery ? BatteryState.formatWatts(device ? device.changeRate : -1,
                                                                             (key, args) => Language.I18n.text(key, args)) : ""
    readonly property var extras: BatteryState.extras(UPower.devices.values)
    readonly property var widgetData: ({present: present, ready: !!device && device.ready,
        percentage: percentage, charging: charging, full: full, remaining: remaining})
}
