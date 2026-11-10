.pragma library

// Type metadata is independent of placed instances and their data providers.
var sizes = [
    {key: "small", label: "Small", width: 185, height: 185},
    {key: "medium", label: "Medium", width: 395, height: 185},
    {key: "large", label: "Large", width: 375, height: 385}
];
var styles = {
    liquid: "Liquid Glass", normal: "Normal", light: "Light", dark: "Dark"
};
var types = [
    {type: "weather", label: "Weather", component: "WeatherWidget", description: "Current conditions and the forecast", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: [], appearance: ["theme", "fontFamily", "textScale"], interactive: false, data: ["weather"], shared: "Weather location and units apply to all Weather widgets."},
    {type: "calendar", label: "Calendar", component: "CalendarWidget", description: "Today's date and the month at a glance", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: ["mode"], appearance: ["theme", "fontFamily", "textScale"], interactive: false, data: ["date"], shared: "Shows the local date. Calendar accounts are not connected."},
    {type: "clock", label: "Clock", component: "ClockWidget", description: "A live analog clock for your desktop", styles: ["liquid", "light", "dark"], sizes: ["small", "medium", "large"], settings: [], appearance: ["theme", "fontFamily", "textScale", "secondsMode"], interactive: false, data: ["time"], shared: "Uses this computer's local time."},
    {type: "player", label: "Player", component: "PlayerWidget", description: "Now Playing, playback controls and lyrics", styles: ["liquid", "light", "dark"], sizes: ["small", "medium", "large"], settings: [], appearance: ["theme", "fontFamily", "textScale", "density", "tint"], interactive: true, data: ["player", "lyrics"], shared: "All Player widgets control the same active player."},
    {type: "activity", label: "Activity", component: "ActivityWidget", description: "CPU, memory, network and disk activity", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: ["activity"], appearance: ["theme", "fontFamily", "textScale"], interactive: true, data: ["stats"], shared: "All Activity views use the same interface, disk, update interval and speed units. Click the card for details."},
    {type: "batteries", label: "Batteries", component: "BatteriesWidget", description: "Laptop and Bluetooth device charge at a glance", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: ["batteries"], appearance: ["theme", "fontFamily", "textScale"], interactive: false, data: ["batteries"], shared: "Uses the laptop battery and known Bluetooth devices. Automatic shows connected devices. No device scan is started."},
    {type: "timer", label: "Timer", component: "TimerWidget", description: "Control the shared Clock timer", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: ["timer"], appearance: ["theme", "fontFamily", "textScale"], interactive: true, data: ["timer"], shared: "All Timer widgets control the same timer in Clock."},
    {type: "notes", label: "Notes", component: "NotesWidget", description: "The selected note from Notes", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: [], appearance: ["theme", "fontFamily", "textScale"], interactive: true, data: ["notes"], shared: "All Notes widgets show the Notes store. Click the card to open Notes."},
    {type: "reminders", label: "Reminders", component: "RemindersWidget", description: "Tasks from Reminders", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: [], appearance: ["theme", "fontFamily", "textScale"], interactive: true, data: ["reminders"], shared: "All Reminders widgets use the same local task lists. Click a circle to complete a task, or open Reminders."},
    {type: "image", label: "Image", component: "ImageWidget", description: "A local picture on the desktop", styles: ["liquid", "normal"], sizes: ["small", "medium", "large"], settings: ["image"], appearance: ["theme", "fontFamily", "textScale"], interactive: false, data: [], shared: "Choose a local image file. Network addresses are not loaded."}
];
function find(type) { return types.find(item => item.type === type) || null; }
function dimensions(size) {
    var found = sizes.find(item => item.key === size) || sizes[0];
    return [found.width, found.height];
}
function names() {
    var result = {};
    types.forEach(item => result[item.type] = item.label);
    return result;
}
function legacyStyle(type, style) {
    var definition = find(type);
    return definition && definition.styles.indexOf(style) >= 0 ? style : "liquid";
}
