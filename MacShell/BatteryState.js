.pragma library

function healthPercentage(devices) {
    var battery = null;
    for (var i = 0; devices && i < devices.length; ++i) {
        var device = devices[i];
        if (!device || !device.isLaptopBattery || !device.isPresent) continue;
        if (battery) return -1;
        battery = device;
    }
    if (!battery || !battery.ready || !battery.healthSupported ||
            typeof battery.healthPercentage !== "number" || !isFinite(battery.healthPercentage) ||
            battery.healthPercentage <= 0 || battery.healthPercentage > 100) return -1;
    return Math.round(battery.healthPercentage);
}

function chargePercentage(present, ready, fraction) {
    return present && ready && typeof fraction === "number" && isFinite(fraction) && fraction >= 0 && fraction <= 1
        ? Math.round(fraction * 100) : -1;
}

function trustedTime(seconds) {
    if (!isFinite(seconds) || seconds <= 0 || seconds > 36 * 3600) return 0;
    return seconds;
}

function watts(rate) {
    return typeof rate === "number" && isFinite(rate) && rate >= 0.05 ? rate : -1;
}

function wattHours(value) {
    return typeof value === "number" && isFinite(value) && value > 0 ? value : -1;
}

function formatWatts(rate, translate) {
    var value = watts(rate);
    if (value < 0) return "";
    var shown = value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
    return translate ? translate("battery.rate_value", {watts: shown}) : shown + " W";
}

function formatEnergy(current, full, translate) {
    var now = wattHours(current), cap = wattHours(full);
    if (now < 0 && cap < 0) return "";
    function one(value) { return (Math.round(value * 10) / 10).toFixed(1); }
    if (now >= 0 && cap >= 0)
        return translate ? translate("battery.capacity_value", {current: one(now), full: one(cap)})
                         : one(now) + " / " + one(cap) + " Wh";
    var only = now >= 0 ? now : cap;
    return translate ? translate("battery.capacity_only", {energy: one(only)}) : one(only) + " Wh";
}

function extras(devices) {
    var result = [];
    if (!devices) return result;
    for (var i = 0; i < devices.length; ++i) {
        var device = devices[i];
        if (!device || !device.isPresent || !device.ready || device.isLaptopBattery) continue;
        if (device.type === 1) continue;
        var percentage = chargePercentage(true, true, device.percentage);
        if (percentage < 0) continue;
        result.push({
            id: String(device.nativePath || device.model || i).slice(0, 80),
            name: String(device.model || device.nativePath || "Battery").slice(0, 80),
            percentage: percentage
        });
    }
    return result;
}

function duration(seconds, translate) {
    seconds = trustedTime(seconds);
    if (!isFinite(seconds) || seconds <= 0) return "";
    var minutes = Math.max(1, Math.ceil(seconds / 60));
    var hours = Math.floor(minutes / 60);
    var hour = translate ? translate("time.hour_unit") : "h", minute = translate ? translate("time.minute_unit") : "min";
    return hours ? hours + " " + hour + (minutes % 60 ? " " + minutes % 60 + " " + minute : "") : minutes + " " + minute;
}

function remaining(present, state, empty, full, onBattery, translate) {
    if (translate) {
        if (!present) return translate("battery.absent");
        if (state === 4) return translate("battery.full");
        if (state === 1) return duration(full, translate) ? translate("battery.until_full", {duration: duration(full, translate)}) : translate("battery.charging_calculating");
        if (state === 2) return duration(empty, translate) ? translate("battery.remaining", {duration: duration(empty, translate)}) : translate("battery.discharging_calculating");
        return translate(onBattery ? "battery.time_unavailable" : "battery.not_charging");
    }
    if (!present) return "No battery";
    // UPower DeviceState values: Charging=1, Discharging=2, FullyCharged=4.
    if (state === 4) return "Fully Charged";
    if (state === 1) return duration(full) ? "About " + duration(full) + " until full" : "Charging · Calculating time…";
    if (state === 2) return duration(empty) ? "About " + duration(empty) + " remaining" : "On Battery · Calculating time…";
    return onBattery ? "On Battery · Time unavailable" : "Power Adapter · Not Charging";
}
