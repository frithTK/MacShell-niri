.pragma library

function identity(output) {
    return {connector: output.name, make: output.make || "", model: output.model || "", serial: output.serial || ""};
}
function compatible(a, b) {
    return ["make", "model", "serial"].every(key => !a[key] || !b[key] || a[key] === b[key]);
}
function sameDevice(a, b) {
    return !!a.serial && a.serial === b.serial && compatible(a, b);
}
function resolve(profiles, output, liveOutputs, bindings) {
    var target = identity(output), keys = Object.keys(profiles);
    var bound = (bindings || {})[output.name];
    if (bound && profiles[bound] && compatible(profiles[bound].identity, target))
        return {id: bound, candidates: [bound], ambiguous: false};
    var exact = keys.filter(key => profiles[key].identity.connector === target.connector && compatible(profiles[key].identity, target));
    if (exact.length === 1) return {id: exact[0], candidates: exact, ambiguous: false};
    if (exact.length > 1) return {id: "", candidates: exact, ambiguous: true};
    var devices = keys.filter(key => sameDevice(profiles[key].identity, target));
    var live = liveOutputs.filter(item => sameDevice(identity(item), target));
    return {id: devices.length === 1 && live.length === 1 ? devices[0] : "", candidates: devices, ambiguous: devices.length > 1 || devices.length > 0 && live.length > 1};
}
function effective(values, output, liveOutputs) {
    var match = resolve(values.outputs || {}, output, liveOutputs, values.bindings);
    var profile = match.id ? values.outputs[match.id] : null;
    return profile && profile.layout !== undefined ? profile.layout : values.common || [];
}
