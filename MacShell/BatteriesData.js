.pragma library

function percentage(value) { return typeof value === "number" && isFinite(value) && value >= 0 && value <= 100 ? Math.round(value) : -1; }
function validId(value) {
    return typeof value === "string" && (value === "laptop" || /^bluetooth:(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(value)
        || /^bluetooth-path:\/org\/bluez\/[A-Za-z0-9_\/]+$/.test(value)) && value.length <= 200;
}
function validSettings(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    var devices = value.devices === undefined ? [] : value.devices;
    return ["auto", "selected"].indexOf(value.mode === undefined ? "auto" : value.mode) >= 0
        && Array.isArray(devices) && devices.length <= 16 && devices.every((id, index) => validId(id) && devices.indexOf(id) === index);
}
function deviceId(device) {
    var address = typeof device.address === "string" ? device.address.toUpperCase() : "";
    if (!/^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(address)) {
        var match = String(device.path || "").match(/\/dev_((?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2})$/);
        address = match ? match[1].replace(/_/g, ":").toUpperCase() : "";
    }
    if (address) return "bluetooth:" + address;
    var fallback = "bluetooth-path:" + String(device.path || "");
    return validId(fallback) ? fallback : "";
}
function kind(icon) {
    if (/headset|headphone/.test(icon || "")) return "headphones";
    if (/keyboard/.test(icon || "")) return "keyboard";
    if (/mouse/.test(icon || "")) return "mouse";
    if (/gaming|gamepad/.test(icon || "")) return "gamepad";
    if (/audio/.test(icon || "")) return "speaker";
    return "bluetooth";
}
function missing(id, previous) {
    return {id: id, name: previous ? previous.name : id === "laptop" ? "Laptop" : "Unavailable device",
        label: previous ? previous.label : id === "laptop" ? "Laptop" : "Unavailable device · " + id.slice(-8),
        kind: previous ? previous.kind : id === "laptop" ? "laptop" : "bluetooth",
        percentage: -1, connected: false, present: false, status: "unavailable", charging: false, full: false, detail: ""};
}
function normalize(laptop, devices, bluetooth, previous) {
    var result = [], byId = {};
    if (laptop && laptop.present) {
        result.push({id: "laptop", name: "Laptop", label: "Laptop", kind: "laptop", present: true,
            connected: laptop.ready === true, percentage: laptop.ready ? percentage(laptop.percentage) : -1,
            status: laptop.ready ? "connected" : "unavailable", charging: !!laptop.ready && !!laptop.charging,
            full: !!laptop.ready && !!laptop.full, detail: laptop.ready ? laptop.remaining || "" : ""});
    }
    (Array.isArray(devices) ? devices : []).forEach(device => {
        if (!device || typeof device !== "object") return;
        var id = deviceId(device);
        if (!id) return;
        var ready = !!bluetooth.ready && !!bluetooth.available;
        var powered = !!bluetooth.enabled && device.adapterEnabled === true;
        var connected = ready && powered && device.connected === true && !device.blocked;
        var charge = connected ? percentage(device.battery) : -1;
        var status = !ready ? "unavailable" : !powered ? "off" : device.blocked ? "blocked" : connected ? "connected" : "disconnected";
        var score = (connected ? 100 : 0) + (powered ? 10 : 0) + (charge >= 0 ? 1 : 0);
        var candidate = {score: score, path: String(device.path || ""), row: {
            id: id, name: String(device.name || "Bluetooth device").slice(0, 200), label: "", kind: kind(device.icon),
            percentage: charge, connected: connected, present: true, status: status, charging: false, full: false, detail: ""}};
        var old = byId[id];
        if (!old || score > old.score || score === old.score && candidate.path < old.path) byId[id] = candidate;
    });
    Object.keys(byId).sort().forEach(id => result.push(byId[id].row));
    result.forEach(row => {
        row.label = row.name + (row.id !== "laptop" && result.filter(other => other.name === row.name).length > 1 ? " · " + row.id.slice(-8) : "");
    });
    result.sort((a, b) => (a.id === "laptop" ? -1 : b.id === "laptop" ? 1 : 0) || Number(b.connected) - Number(a.connected)
        || a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
    // Remember labels for vanished devices, bounded to 64 records. Cached charge
    // is never presented as a live value, including after adapter/service loss.
    (previous || []).forEach(row => { if (result.length < 64 && !result.some(item => item.id === row.id)) result.push(missing(row.id, row)); });
    return result.slice(0, 64);
}
function rows(entries, settings) {
    if (settings.mode === "selected") return (settings.devices || []).map(id => entries.find(item => item.id === id) || missing(id));
    return entries.filter(item => item.present && (item.id === "laptop" || item.connected));
}
function choices(entries, devices) {
    var result = entries.slice();
    (devices || []).forEach(id => { if (!result.some(item => item.id === id)) result.push(missing(id)); });
    return result;
}
function status(row) {
    if (row.status === "off") return "Bluetooth off";
    if (row.status === "disconnected") return "Disconnected";
    if (row.status === "blocked") return "Blocked";
    if (!row.connected) return "Unavailable";
    if (row.charging) return "Charging";
    if (row.full) return "Fully charged";
    return row.percentage < 0 ? "Battery unknown" : "";
}
function value(row) { return row.connected && row.percentage >= 0 ? row.percentage + "%" : "—"; }
function demoEntries() {
    return normalize({present: true, ready: true, percentage: 84, charging: true, remaining: "About 25 min until full"}, [
        {address: "AA:00:00:00:00:01", name: "Headphones", icon: "audio-headphones", connected: true, adapterEnabled: true, battery: 67},
        {address: "AA:00:00:00:00:02", name: "Mouse", icon: "input-mouse", connected: true, adapterEnabled: true, battery: 0},
        {address: "AA:00:00:00:00:03", name: "Keyboard", icon: "input-keyboard", connected: true, adapterEnabled: true, battery: 100},
        {address: "AA:00:00:00:00:04", name: "Speaker", icon: "audio-card", connected: true, adapterEnabled: true, battery: -1},
        {address: "AA:00:00:00:00:05", name: "Controller", icon: "input-gaming", connected: true, adapterEnabled: true, battery: 42}
    ], {ready: true, available: true, enabled: true}, []);
}
function demoFor(settings) {
    var demo = demoEntries();
    return settings.mode === "selected" ? (settings.devices || []).map((id, index) => Object.assign({}, id === "laptop" ? demo[0] : demo[1 + index % (demo.length - 1)], {id: id})) : demo;
}
