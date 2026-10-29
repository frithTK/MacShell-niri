.pragma library

function parse(source) {
    var defaults = {ui: "system", session: "system", region: "system"};
    var lines = source.trim().split(/\r?\n/);
    if (!source.trim()) return defaults;
    if (lines[0] !== "# MacShell locale preferences v1") return defaults;
    var values = {}, pattern = /^# (ui|session|region)=([a-zA-Z0-9_.@:\-]+)$/;
    for (var line of lines.slice(1)) {
        var match = pattern.exec(line);
        if (match) {
            if (values[match[1]] !== undefined) return defaults;
            values[match[1]] = match[2];
        }
    }
    if (["system", "en", "ru"].indexOf(values.ui) < 0 || !values.session || !values.region) return defaults;
    return values;
}
