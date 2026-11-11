.pragma library

function migrate(source) {
    var value = {};
    if (source && typeof source === "object" && !Array.isArray(source))
        for (var key in source) value[key] = source[key];
    var widgets = ["appleMenu", "appMenus", "workspaces", "volume", "keyboard", "notifications", "wifi", "bluetooth", "privacy", "controlCenter", "clock"];
    if (!Array.isArray(value.barWidgets)) value.barWidgets = widgets;
    if (!value.statsMigrated) {
        value.barWidgets = value.barWidgets.slice();
        if (value.barWidgets.indexOf("monitoring") < 0) value.barWidgets.unshift("monitoring");
    }
    value.statsMigrated = true;
    if (!value.ccMirroringMigrated && Array.isArray(value.ccControls)) {
        value.ccControls = value.ccControls.slice();
        if (value.ccControls.indexOf("mirroring") < 0) {
            var afterRecord = value.ccControls.indexOf("record");
            value.ccControls.splice(afterRecord >= 0 ? afterRecord + 1 : value.ccControls.length, 0, "mirroring");
        }
    }
    value.ccMirroringMigrated = true;
    if (!value.ccAirDropMigrated && Array.isArray(value.ccControls) && value.ccControls.length > 0) {
        value.ccControls = value.ccControls.slice();
        if (value.ccControls.indexOf("airdrop") < 0) {
            var afterMirroring = value.ccControls.indexOf("mirroring");
            value.ccControls.splice(afterMirroring >= 0 ? afterMirroring + 1 : value.ccControls.length, 0, "airdrop");
        }
    }
    value.ccAirDropMigrated = true;
    if (!Array.isArray(value.statsMetrics)) value.statsMetrics = ["cpu", "memory", "network", "disk"];
    value.statsMetrics = value.statsMetrics.filter(k => ["cpu", "memory", "network", "disk"].indexOf(k) >= 0);
    if ([1, 2, 5].indexOf(value.statsInterval) < 0) value.statsInterval = 1;
    value.nightTemp = Math.max(2500, Math.min(6000, Number(value.nightTemp) || 4000));
    value.airplayFps = Math.max(15, Math.min(60, Number(value.airplayFps) || 60));
    value.airplayVolumePercent = Math.max(1, Math.min(100, Number(value.airplayVolumePercent) || 20));
    value.airplayLayout = "mirror";
    if (!value.modesMigrated) {
        value.modeState = {focus: {mode: (value.dnd !== undefined ? value.dnd : value.notifDnd) ? "manual" : "off"}, awake: {mode: "off"}};
        value.nightDesired = !!value.nightOn;
    }
    if (!value.modeState || typeof value.modeState !== "object" || Array.isArray(value.modeState))
        value.modeState = {focus: {mode: "off"}, awake: {mode: "off"}};
    value.modesMigrated = true;
    value.keepAwake = false;
    value.nightOn = false;
    if (["none", "system", "mic", "both"].indexOf(value.recordAudio) < 0) value.recordAudio = "none";
    return value;
}
