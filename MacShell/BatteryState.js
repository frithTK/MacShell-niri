.pragma library

function duration(seconds) {
    if (!isFinite(seconds) || seconds <= 0) return "";
    var minutes = Math.max(1, Math.ceil(seconds / 60));
    var hours = Math.floor(minutes / 60);
    return hours ? hours + " h" + (minutes % 60 ? " " + minutes % 60 + " min" : "") : minutes + " min";
}

function remaining(present, state, empty, full, onBattery) {
    if (!present) return "No battery";
    // UPower DeviceState values: Charging=1, Discharging=2, FullyCharged=4.
    if (state === 4) return "Fully Charged";
    if (state === 1) return duration(full) ? "About " + duration(full) + " until full" : "Charging · Calculating time…";
    if (state === 2) return duration(empty) ? "About " + duration(empty) + " remaining" : "On Battery · Calculating time…";
    return onBattery ? "On Battery · Time unavailable" : "Power Adapter · Not Charging";
}
