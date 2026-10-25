.pragma library
.import "WidgetCatalog.js" as Catalog
.import "OutputProfiles.js" as Outputs

function clone(value) { return JSON.parse(JSON.stringify(value)); }
function outputFor(screen, outputs) {
    return outputs.find(item => item.name === screen.name) || {name: screen.name, make: "", model: "", serial: ""};
}
function screenFor(values, screens, outputs) {
    if (!values.desktopOutput) return screens.length ? screens[0] : null;
    return screens.find(screen => Outputs.resolve(values.outputs, outputFor(screen, outputs), outputs.length ? outputs : screens.map(item => outputFor(item, outputs)), values.bindings).id === values.desktopOutput) || null;
}
// Resolve all screens together: one saved profile must never render twice.
function displays(values, screens, outputs, reservations) {
    var live = screens.map(screen => outputFor(screen, outputs));
    var plans = screens.map(screen => {
        var match = Outputs.resolve(values.outputs, outputFor(screen, outputs), live, values.bindings);
        return {screen: screen, name: screen.name, profileId: match.id, ambiguous: match.ambiguous,
                area: availableRect(screen, (reservations || {})[screen.name] || {})};
    });
    plans.forEach(plan => {
        if (plan.profileId && plans.filter(other => other.profileId === plan.profileId).length > 1) plan.ambiguous = true;
    });
    plans.forEach(plan => { if (plan.ambiguous) plan.profileId = ""; });
    return plans;
}
function withOutput(values, screen, outputs, screens) {
    if (!screen) return null;
    var plan = displays(values, screens || [screen], outputs, {}).find(item => item.name === screen.name);
    if (!plan || plan.ambiguous) return null;
    var next = clone(values), id = plan.profileId
        || "display-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 9);
    if (!next.outputs[id]) next.outputs[id] = {identity: Outputs.identity(outputFor(screen, outputs))};
    next.bindings[screen.name] = id;
    if (!next.desktopOutput) next.desktopOutput = id;
    return {values: next, profileId: id};
}
function withDesktop(values, screen, outputs) {
    var result = withOutput(values, screen, outputs);
    return result ? result.values : null;
}
function reservedFor(name, bar, dock) {
    return {top: bar && bar.settingsReady && bar.barEnabled ? bar.barHeight : 0,
            bottom: dock && dock.settingsReady && dock.dockEnabled && (!dock.monitor || dock.monitor === name)
                    && dock.hideMode === "never" ? dock.bgHeight + dock.margin : 0};
}
function availableRect(screen, reserved) {
    var width = Math.max(0, Math.floor(screen.width)), height = Math.max(0, Math.floor(screen.height));
    var top = Math.min(height, Math.max(0, Math.ceil(reserved.top || 0)));
    var bottom = Math.min(height - top, Math.max(0, Math.ceil(reserved.bottom || 0)));
    return {x: 0, y: top, width: width, height: height - top - bottom};
}
function grid(width, height, area) {
    var a = area || {x: 0, y: 0, width: width, height: height};
    var cols = Math.max(0, Math.floor((a.width - 42 + 28) / 207));
    var top = Math.max(56, a.y + 24), bottom = a.y + a.height - 24;
    return {cols: cols, rows: Math.max(0, Math.floor((bottom - top - 185) / 202) + 1),
            left: a.x + 21 + Math.floor(Math.max(0, a.width - 42 - cols * 179 - (cols - 1) * 28) / 2),
            top: top, right: a.x + a.width - 21, bottom: bottom, pitchX: 207, pitchY: 202};
}
function settings(record, common) {
    var saved = record.settings || {};
    return {style: saved.style !== undefined ? saved.style : common.styles[record.type],
            size: saved.size !== undefined ? saved.size : "small", mode: saved.mode !== undefined ? saved.mode : common.mode,
            appearance: saved.appearance || {}};
}
function supported(record) { return record.version === 1 && !!Catalog.find(record.type); }
function overlap(x, y, dims, placed, skipId) {
    return placed.some(item => {
        if (item.wid === skipId) return false;
        var other = Catalog.dimensions(item.wsize);
        return x < item.wx + other[0] && x + dims[0] > item.wx && y < item.wy + other[1] && y + dims[1] > item.wy;
    });
}
function cell(screen, size, column, row, placed, skipId) {
    var g = grid(screen.width, screen.height, screen.area), dims = Catalog.dimensions(size);
    var x = g.left + column * g.pitchX, y = g.top + row * g.pitchY;
    if (column < 0 || row < 0 || x + dims[0] > g.right || y + dims[1] > g.bottom || overlap(x, y, dims, placed, skipId)) return null;
    return {column: column, row: row, x: x, y: y};
}
function free(screen, size, placed, skipId, x, y) {
    if (!screen) return null;
    var g = grid(screen.width, screen.height, screen.area), best = null, distance = Infinity;
    for (var row = 0; row < g.rows; row++) for (var column = g.cols - 1; column >= 0; column--) {
        var candidate = cell(screen, size, column, row, placed, skipId);
        if (!candidate) continue;
        if (x === undefined) return candidate;
        var delta = Math.pow(candidate.x - x, 2) + Math.pow(candidate.y - y, 2);
        if (delta < distance) { best = candidate; distance = delta; }
    }
    return best;
}
function placements(values, screen, profileId) {
    var placed = [], unplaced = [], pending = [], resolved = {};
    var profile = profileId === undefined ? values.desktopOutput : profileId;
    var records = values.widgets.filter(record => supported(record) && record.output === profile);
    function place(record, position) {
        var appearance = settings(record, values.defaults);
        placed.push({wid: record.id, wtype: record.type, wstyle: appearance.style, wsize: appearance.size, wmode: appearance.mode,
                     wappearance: JSON.stringify(appearance.appearance),
                     wx: position.x, wy: position.y, woutput: screen.name || "", wprofile: profile});
        resolved[record.id] = placed[placed.length - 1];
    }
    // Reserve valid desired cells first, then reflow only the remaining cards.
    records.forEach(record => {
        var position = screen ? cell(screen, settings(record, values.defaults).size, record.position.column, record.position.row, placed, "") : null;
        if (position) place(record, position); else pending.push(record);
    });
    pending.forEach(record => {
        var position = null;
        if (screen) {
            var g = grid(screen.width, screen.height, screen.area);
            position = free(screen, settings(record, values.defaults).size, placed, "", g.left + record.position.column * g.pitchX, g.top + record.position.row * g.pitchY);
        }
        if (position) place(record, position);
        else unplaced.push({id: record.id, type: record.type, output: profile,
                           reason: screen ? "No room on this display" : "Display disconnected or ambiguous"});
    });
    return {placed: records.filter(record => resolved[record.id]).map(record => resolved[record.id]), unplaced: unplaced};
}
function layout(values, plans) {
    var result = {placed: [], unplaced: []}, connected = {};
    plans.forEach(plan => {
        if (!plan.profileId) return;
        connected[plan.profileId] = true;
        var screen = {name: plan.name, width: plan.screen.width, height: plan.screen.height, area: plan.area};
        var items = placements(values, screen, plan.profileId);
        result.placed = result.placed.concat(items.placed); result.unplaced = result.unplaced.concat(items.unplaced);
    });
    values.widgets.forEach(record => {
        if (supported(record) && !connected[record.output])
            result.unplaced.push({id: record.id, type: record.type, output: record.output, reason: "Display disconnected or ambiguous"});
    });
    result.unplaced.forEach(item => {
        var profile = values.outputs[item.output];
        item.display = profile ? profile.identity.connector : item.output;
    });
    return result;
}
// Settings lists every saved instance, including disconnected and future cards.
function instances(values, plans, placed, unplaced) {
    return values.widgets.map(record => {
        var definition = Catalog.find(record.type), appearance = settings(record, values.defaults);
        var row = placed.find(item => item.wid === record.id);
        var missing = unplaced.find(item => item.id === record.id);
        var plan = plans.find(item => item.profileId === record.output && !item.ambiguous);
        var profile = values.outputs[record.output];
        return {id: record.id, type: record.type, label: definition ? definition.label : String(record.type || "Unknown widget"),
                supported: supported(record), size: appearance.size, style: appearance.style, mode: appearance.mode,
                appearance: clone(appearance.appearance), styleInherited: (record.settings || {}).style === undefined,
                defaultStyle: values.defaults.styles[record.type] || "liquid",
                savedSettings: clone(record.settings || {}),
                outputName: plan ? plan.name : "", display: plan ? plan.name : profile ? profile.identity.connector : "",
                placed: !!row, reason: !supported(record) ? "Unavailable. Saved settings are retained." : missing ? missing.reason : "",
                canPlace: !!plan};
    });
}
