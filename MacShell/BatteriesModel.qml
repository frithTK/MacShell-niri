import QtQuick
import "BatteriesData.js" as Data

QtObject {
    id: root
    property var battery: null
    property var bluetooth: null
    property bool active: false
    property var entries: []
    readonly property var sourceData: active ? {
        laptop: battery ? battery.widgetData : null,
        devices: bluetooth ? bluetooth.devices : [],
        bluetooth: {ready: !!bluetooth && bluetooth.stateReady === true,
            available: !!bluetooth && bluetooth.available === true, enabled: !!bluetooth && bluetooth.enabled === true}
    } : null
    onSourceDataChanged: {
        if (!sourceData) return;
        var next = Data.normalize(sourceData.laptop, sourceData.devices, sourceData.bluetooth, entries);
        if (JSON.stringify(next) !== JSON.stringify(entries)) entries = next;
    }
}
