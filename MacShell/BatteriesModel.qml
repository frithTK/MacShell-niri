import QtQuick
import "BatteriesData.js" as Data

QtObject {
    id: root
    property var battery: null
    property var bluetooth: null
    property bool active: false
    property var entries: []
    property bool watchingBatteries: false
    readonly property var sourceData: active ? {
        laptop: battery ? battery.widgetData : null,
        devices: bluetooth ? bluetooth.devices : [],
        bluetooth: {ready: !!bluetooth && bluetooth.stateReady === true,
            available: !!bluetooth && bluetooth.available === true, enabled: !!bluetooth && bluetooth.enabled === true}
    } : null
    function syncBatteryWatch() {
        var want = !!active && !!bluetooth;
        if (!bluetooth || typeof bluetooth.watchBatteries !== "function") return;
        if (want === watchingBatteries) return;
        watchingBatteries = want;
        bluetooth.watchBatteries(want);
    }
    onActiveChanged: syncBatteryWatch()
    onBluetoothChanged: syncBatteryWatch()
    Component.onCompleted: syncBatteryWatch()
    Component.onDestruction: {
        if (watchingBatteries && bluetooth && typeof bluetooth.watchBatteries === "function")
            bluetooth.watchBatteries(false);
        watchingBatteries = false;
    }
    onSourceDataChanged: {
        if (!sourceData) return;
        var next = Data.normalize(sourceData.laptop, sourceData.devices, sourceData.bluetooth, entries);
        if (JSON.stringify(next) !== JSON.stringify(entries)) entries = next;
    }
}
