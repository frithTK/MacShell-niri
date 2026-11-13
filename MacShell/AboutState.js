.pragma library

function trim(value) {
    return String(value || "").replace(/^\s+|\s+$/g, "");
}

function parsePairs(text) {
    var map = {};
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        var key = line.substring(0, eq);
        var value = line.substring(eq + 1);
        if (value.charAt(0) === "\"" && value.charAt(value.length - 1) === "\"")
            value = value.substring(1, value.length - 1);
        map[key] = value;
    }
    return map;
}

function osName(text) {
    var map = parsePairs(text);
    return trim(map.PRETTY_NAME || map.NAME || "");
}

function tidyCpu(name) {
    return trim(String(name || "")
        .replace(/\(R\)/g, "")
        .replace(/\(TM\)/g, "")
        .replace(/CPU @.*$/i, "")
        .replace(/\s+/g, " "));
}

function parseCpu(text) {
    var model = "";
    var cores = 0;
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.indexOf("model name") === 0 && !model) {
            var idx = line.indexOf(":");
            model = idx >= 0 ? trim(line.substring(idx + 1)) : "";
        }
        if (line.indexOf("processor") === 0)
            cores += 1;
    }
    return { model: tidyCpu(model), cores: cores };
}

function parseMemoryBytes(text) {
    var match = String(text || "").match(/MemTotal:\s*(\d+)/);
    if (!match)
        return 0;
    return Number(match[1]) * 1024;
}

function memoryLabel(bytes) {
    var gib = bytes / (1024 * 1024 * 1024);
    if (!(gib > 0))
        return "";
    var sizes = [2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256];
    for (var i = 0; i < sizes.length; i++) {
        if (gib > sizes[i] * 0.9 && gib <= sizes[i] * 1.05)
            return String(sizes[i]) + " GB";
    }
    return (gib >= 10 ? String(Math.round(gib)) : (Math.round(gib * 10) / 10).toFixed(1)) + " GB";
}

function usableDmi(value) {
    var text = trim(value);
    if (!text)
        return "";
    var lower = text.toLowerCase();
    if (lower.indexOf("to be filled") >= 0 || lower === "none" || lower === "default string"
        || lower === "system product name" || lower === "system manufacturer")
        return "";
    return text;
}

function computerName(vendor, product, hostname) {
    var v = usableDmi(vendor), p = usableDmi(product);
    if (v && p && p.toLowerCase().indexOf(v.toLowerCase()) !== 0)
        return v + " " + p;
    if (p)
        return p;
    if (v)
        return v;
    return trim(hostname);
}

function pciVendor(id) {
    var vendor = String(id || "").split(":")[0].toLowerCase();
    if (vendor === "8086") return "Intel";
    if (vendor === "10de") return "NVIDIA";
    if (vendor === "1002") return "AMD";
    if (vendor === "14c3") return "MediaTek";
    if (vendor === "1af4") return "Virtio";
    return "";
}

function parseGpu(text) {
    var blocks = String(text || "").split("---");
    var seen = {};
    var labels = [];
    for (var i = 0; i < blocks.length; i++) {
        var block = blocks[i];
        if (block.indexOf("DEVTYPE=drm_minor") >= 0)
            continue;
        var driverMatch = block.match(/DRIVER=([^\s]+)/);
        var pciMatch = block.match(/PCI_ID=([0-9A-Fa-f:]+)/);
        if (!driverMatch && !pciMatch)
            continue;
        var driver = driverMatch ? driverMatch[1] : "";
        var vendor = pciMatch ? pciVendor(pciMatch[1]) : "";
        var label = vendor && driver ? vendor + " (" + driver + ")" : (vendor || driver);
        if (label && !seen[label]) {
            seen[label] = true;
            labels.push(label);
        }
    }
    return labels.join(" · ");
}

function niriLabel(text) {
    var line = trim(String(text || "").split("\n")[0]);
    var match = line.match(/^niri\s+(\S+)/i);
    if (match)
        return "niri " + match[1];
    return line;
}

function displayLine(monitors) {
    var rows = [];
    if (monitors && typeof monitors.length === "number") {
        for (var i = 0; i < monitors.length; i++)
            rows.push(monitors[i]);
    }
    if (!rows.length)
        return "";
    var parts = [];
    for (var m = 0; m < rows.length; m++) {
        var mon = rows[m];
        if (!mon)
            continue;
        var w = Number(mon.modeWidth || mon.width || 0);
        var h = Number(mon.modeHeight || mon.height || 0);
        if (!(w > 0 && h > 0))
            continue;
        var hz = Number(mon.refreshRate || 0);
        var piece = w + "×" + h;
        if (hz > 0)
            piece += " @ " + String(Math.round(hz * 10) / 10).replace(/\.0$/, "") + " Hz";
        if (mon.name)
            piece = String(mon.name) + " · " + piece;
        parts.push(piece);
    }
    return parts.join("  ·  ");
}

function snapshot(fields) {
    fields = fields || {};
    var cpu = parseCpu(fields.cpuinfo);
    var bytes = parseMemoryBytes(fields.meminfo);
    var host = trim(fields.hostname);
    var product = computerName(fields.dmiVendor, fields.dmiProduct, host);
    return {
        hostname: host,
        computer: product || host || "Linux",
        os: osName(fields.osRelease),
        kernel: trim(fields.kernel),
        chip: cpu.model,
        cores: cpu.cores,
        memoryBytes: bytes,
        memory: memoryLabel(bytes),
        gpu: parseGpu(fields.drm),
        niri: niriLabel(fields.niriVersion),
        version: trim(fields.version),
        display: displayLine(fields.monitors)
    };
}
