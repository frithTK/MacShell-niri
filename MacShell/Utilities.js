.pragma library
.import "RemindersText.js" as RemindersText
.import "StickiesText.js" as StickiesText

var apps = [
    {key: "clock", id: "macshell-clock", name: "Clock", title: "Clock", icon: "assets/app-icons/macshell-clock.svg", genericName: "Alarms, timers, stopwatch and world clock", comment: "MacShell Clock", categories: ["Utility"], keywords: ["clock", "alarm", "timer", "stopwatch", "world", "часы", "будильник", "таймер", "секундомер", "мировое время"]},
    {key: "calculator", id: "macshell-calculator", name: "Calculator", title: "Calculator", icon: "assets/app-icons/macshell-calculator.svg", genericName: "Basic and scientific calculations and unit conversions", comment: "MacShell Calculator", categories: ["Utility"], keywords: ["calculator", "calc", "scientific", "convert", "калькулятор", "посчитать", "вычисления", "конвертер", "единицы"]},
    {key: "notes", id: "macshell-notes", name: "Notes", title: "Notes", icon: "assets/app-icons/macshell-notes.svg", genericName: "Local notes and drafts", comment: "MacShell Notes", categories: ["Utility"], keywords: ["notes", "note", "draft", "text", "заметки", "заметка", "запись", "черновик"]},
    {key: "reminders", id: "macshell-reminders", name: "Reminders", title: "Reminders", icon: "assets/app-icons/macshell-reminders.svg", genericName: "Local task lists", comment: "MacShell Reminders", categories: ["Utility"], keywords: ["reminders", "tasks", "todo", "списки", "задачи", "напоминания"]},
    {key: "stickies", id: "macshell-stickies", name: "Stickies", title: "Stickies", icon: "assets/app-icons/macshell-stickies.svg", genericName: "Quick notes on your desktop", comment: "MacShell Stickies", categories: ["Utility"], keywords: ["stickies", "sticky", "notes", "note", "записки", "записка", "стикеры", "стикер"]}
];
function find(id) {
    var key = String(id || "").replace(/\.desktop$/i, "").toLowerCase();
    return apps.find(app => app.key === key || app.id === key) || null;
}
function entry(id, open, translate, language) {
    var definition = find(id);
    var tr = translate || function(value) { return value; };
    var localized = definition && definition.key === "reminders" ? RemindersText : definition && definition.key === "stickies" ? StickiesText : null;
    return definition ? Object.assign({}, definition, {icon: Qt.resolvedUrl(definition.icon).toString(), name: localized ? localized.text(language, "title") : tr(definition.name), genericName: localized ? localized.text(language, "description") : tr(definition.genericName),
        comment: localized ? localized.text(language, "comment") : tr(definition.comment), noDisplay: false, execute: function() { open(definition.key); }}) : null;
}
function entries(open, translate, language) { return apps.map(app => entry(app.key, open, translate, language)); }
function windowId(title) { var app = apps.find(app => app.title === title); return app ? app.id : ""; }
function ownWindow(appId, title) { return ["org.quickshell", "dev.noctalia.noctalia-qs"].indexOf(appId) >= 0 ? windowId(title) || appId : appId; }
function displayTitle(appId, title, translate, language) {
    var app = find(ownWindow(appId, title));
    return app && app.title === title ? (app.key === "reminders" ? RemindersText.text(language, "title") : app.key === "stickies" ? StickiesText.text(language, "title") : (translate || function(value) { return value; })(app.name)) : title;
}
