.pragma library

var metrics = ["cpu", "memory", "network", "disk"];
var labels = {cpu: "CPU", memory: "Memory", network: "Network", disk: "Disk"};
function validSettings(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    var selected = value.metrics === undefined ? metrics : value.metrics;
    return Array.isArray(selected) && selected.length > 0 && selected.length <= 4
        && selected.every((key, index) => metrics.indexOf(key) >= 0 && selected.indexOf(key) === index)
        && ["rings", "graphs"].indexOf(value.view === undefined ? "rings" : value.view) >= 0;
}
function selected(settings) { return validSettings(settings) ? (settings.metrics || metrics) : metrics; }
function valid(value) { return typeof value === "number" && isFinite(value) && value >= 0; }
function percent(sample, metric) {
    if (metric === "cpu") return valid(sample.cpu) ? Math.min(100, sample.cpu) : -1;
    return sample.memory && valid(sample.memory.used) && valid(sample.memory.total) && sample.memory.total > 0
        ? Math.min(100, sample.memory.used / sample.memory.total * 100) : -1;
}
function rate(value, binary) {
    if (!valid(value)) return "—";
    var units = binary ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B", "kB", "MB", "GB", "TB"];
    var base = binary ? 1024 : 1000, index = 0;
    while (value >= base && index < units.length - 1) { value /= base; index++; }
    return (index === 0 || value >= 100 ? value.toFixed(0) : value.toFixed(1)) + " " + units[index] + "/s";
}
function values(sample, metric, stale, binary) {
    if (stale) return ["—", ""];
    var amount = percent(sample, metric);
    if (metric === "cpu") return [amount < 0 ? "—" : amount.toFixed(1) + "%", ""];
    if (metric === "memory") return [amount < 0 ? "—" : amount.toFixed(1) + "%",
        amount < 0 ? "" : (sample.memory.used / 1073741824).toFixed(1) + " / " + (sample.memory.total / 1073741824).toFixed(1) + " GiB"];
    var rates = (metric === "network" ? sample.network : sample.disk) || [];
    return [(metric === "network" ? "↓ " : "R ") + rate(rates[0], binary),
            (metric === "network" ? "↑ " : "W ") + rate(rates[1], binary)];
}
function hint(sample, metric, stale) {
    if (stale) return "Waiting for data";
    if (metric === "cpu") return percent(sample, metric) < 0 ? "Measuring…" : "Processor";
    if (metric === "memory") return percent(sample, metric) < 0 ? "Unavailable" : "Used / total";
    var source = metric === "network" ? sample.interface : sample.device;
    if (!source) return metric === "network" ? "No interface" : "Select a disk";
    var rates = metric === "network" ? sample.network : sample.disk;
    return !rates || !valid(rates[0]) || !valid(rates[1]) ? "Measuring…" : source;
}
function color(metric, sample, stale, appearance, dark) {
    if (appearance.palette === "monochrome" || stale) return dark ? "#d3d3db" : "#555562";
    if (metric === "network") return dark ? "#73bfff" : "#286ab0";
    if (metric === "disk") return dark ? "#b5a0f4" : "#7854b3";
    var amount = percent(sample, metric);
    var warning = appearance[metric + "Warning"] === undefined ? 65 : appearance[metric + "Warning"];
    var critical = appearance[metric + "Critical"] === undefined ? 90 : appearance[metric + "Critical"];
    return amount >= critical ? (dark ? "#ff786f" : "#c23532")
        : amount >= warning ? (dark ? "#f2c46d" : "#a56c13") : (dark ? "#5dd9a3" : "#157a55");
}
function demoSample(time, index) {
    return {time: time, gap: false, cpu: 31.4 + Math.sin(index * .35) * 12,
        memory: {used: (6.4 + Math.sin(index * .1) * .3) * 1073741824, total: 16 * 1073741824},
        interface: "eth0", device: "nvme0n1", network: [1200000 + Math.sin(index * .4) * 900000, 84000], disk: [8400000, 2300000]};
}
function demoHistory() {
    var result = [];
    for (var index = 0; index <= 60; index++) result.push(demoSample(1000 + index, index));
    return result;
}
