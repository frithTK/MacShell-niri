.pragma library

function valid(value) { return typeof value === "number" && isFinite(value) && value >= 0; }
function series(history, metric) {
    var count = metric === "network" || metric === "disk" ? 2 : 1, result = [];
    for (var index = 0; index < count; index++) {
        result.push(history.map(sample => {
            if (metric === "cpu") return valid(sample.cpu) ? Math.min(100, sample.cpu) : null;
            if (metric === "memory") return sample.memory && valid(sample.memory.used) && valid(sample.memory.total) && sample.memory.total > 0
                ? Math.min(100, sample.memory.used / sample.memory.total * 100) : null;
            var values = metric === "network" ? sample.network : sample.disk;
            return values && valid(values[index]) ? values[index] : null;
        }));
    }
    return result;
}
function ceiling(lines, metric) {
    if (metric === "cpu" || metric === "memory") return 100;
    return Math.max(1, ...[].concat(...lines).filter(value => valid(value)));
}
