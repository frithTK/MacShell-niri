.pragma library

function chargePercentage(present, ready, fraction) {
    return present && ready && typeof fraction === "number" && isFinite(fraction) && fraction >= 0 && fraction <= 1
        ? Math.round(fraction * 100) : -1;
}

function duration(seconds, translate) {
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
