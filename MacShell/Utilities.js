.pragma library

var apps = [
    {key: "clock", id: "macshell-clock", name: "Clock", title: "Clock", icon: "preferences-system-time", genericName: "Alarms, timers, stopwatch and world clock", comment: "MacShell Clock", categories: ["Utility"], keywords: ["clock", "alarm", "timer", "stopwatch", "world", "часы", "будильник", "таймер", "секундомер", "мировое время"]},
    {key: "calculator", id: "macshell-calculator", name: "Calculator", title: "Calculator", icon: "accessories-calculator", genericName: "Basic and scientific calculations and unit conversions", comment: "MacShell Calculator", categories: ["Utility"], keywords: ["calculator", "calc", "scientific", "convert", "калькулятор", "посчитать", "вычисления", "конвертер", "единицы"]}
];
function find(id) {
    var key = String(id || "").replace(/\.desktop$/i, "").toLowerCase();
    return apps.find(app => app.key === key || app.id === key) || null;
}
function entry(id, open, translate) {
    var definition = find(id);
    var tr = translate || function(value) { return value; };
    return definition ? Object.assign({}, definition, {name: tr(definition.name), genericName: tr(definition.genericName),
        comment: tr(definition.comment), noDisplay: false, execute: function() { open(definition.key); }}) : null;
}
function entries(open, translate) { return apps.map(app => entry(app.key, open, translate)); }
function windowId(title) { var app = apps.find(app => app.title === title); return app ? app.id : ""; }
function ownWindow(appId, title) { return ["org.quickshell", "dev.noctalia.noctalia-qs"].indexOf(appId) >= 0 ? windowId(title) || appId : appId; }
function displayTitle(appId, title, translate) {
    var app = find(ownWindow(appId, title));
    return app && app.title === title ? (translate || function(value) { return value; })(app.name) : title;
}
